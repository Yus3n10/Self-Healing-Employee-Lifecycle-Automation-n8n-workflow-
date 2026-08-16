# Stage 5 · Audit, offboarding automation, SLA · Stage 6 · Production safeguards

Two stages in one document because they share the same workflows.

---

# Stage 5

**Goal:** nothing waits on somebody remembering. Offboardings fire on their due
date, stale approvals are chased, SLA breaches are visible, entitlement drift is
detected weekly, and any run can be reconstructed from the audit log alone.

---

## 5.1 WF6 — `JML — Sweeper`

New workflow named exactly `JML — Sweeper`. Settings → Timezone `Asia/Manila`,
Error Workflow `JML — Error Handler`.

### Node 1 — `Every Hour` (Schedule Trigger)

| Parameter | Value |
|---|---|
| Trigger Rules → Trigger Interval | `Hours` |
| Hours Between Triggers | `1` |
| Trigger at Minute | `5` |

Minute 5 rather than 0 so it is not competing with every other cron on the
machine at the top of the hour.

Add three independent branches from this trigger. They do not depend on each
other, so they run in parallel.

---

### Branch A — due offboardings

#### `Find Due Offboardings` (Postgres, Execute Query)

```sql
SELECT e.id            AS employee_id,
       e.employee_ref,
       e.full_name,
       e.work_email,
       e.role_code,
       e.department,
       e.manager_email,
       e.end_date
FROM employees e
WHERE e.end_date IS NOT NULL
  AND e.end_date <= (now() AT TIME ZONE 'Asia/Manila')::date
  AND e.status <> 'offboarded'
  AND NOT EXISTS (
        SELECT 1 FROM provisioning_runs r
        WHERE r.employee_id = e.id
          AND r.run_type = 'offboard'
          AND r.status IN ('planned','awaiting_approval','approved','running','completed')
      )
ORDER BY e.end_date ASC
LIMIT 25;
```

No parameters needed. Settings → **Always Output Data**: **on**.

The `NOT EXISTS` clause is the idempotency guard for the scheduler: an hourly
job that ran 24 times must create one offboarding, not 24. `LIMIT 25` is a blast
radius cap. If 400 people appear to be leaving today, something upstream is
wrong and you want to find out at 25, not at 400.

#### `Any Due?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $json.employee_id }}` |
| Operator | `String` → `is not empty` |

#### true → `Create Offboard Run` (Postgres, Execute Query)

Runs once per item.

```sql
INSERT INTO provisioning_runs
  (employee_id, run_type, status, requires_approval, requested_by,
   idempotency_root, due_at)
VALUES
  ($1, 'offboard', 'planned', false, 'system:sweeper',
   $2, ((now() AT TIME ZONE 'Asia/Manila')::date + time '17:00') AT TIME ZONE 'Asia/Manila')
ON CONFLICT (idempotency_root) DO NOTHING
RETURNING id, employee_id;
```

**Query Parameters**:
`{{ [ $json.employee_id, 'offboard:' + $json.employee_ref + ':' + $json.end_date ] }}`

`ON CONFLICT DO NOTHING` is the second guard, at the database level, behind the
`NOT EXISTS`. Belt and braces, because a scheduler that double-fires during a
restart is a normal event, not an exotic one.

Settings → **Always Output Data**: **on** (a conflict returns zero rows).

#### `Run Created?` (If)

Left Value `{{ $json.id }}`, Operator `String` → `is not empty`.

#### true → `Plan Offboard Steps` (HTTP Request → then reuse)

The offboarding plan comes from the account's live state, exactly as in Stage 2.
Rather than duplicate that logic, call the IdP and build the steps here.

**`Read Live State`** (HTTP Request):

| Parameter | Value |
|---|---|
| Method | `GET` |
| URL | `{{ 'http://127.0.0.1:8100/v1/users/' + encodeURIComponent($('Find Due Offboardings').item.json.work_email) }}` |
| Authentication | `Generic Credential Type` → `Header Auth` → `Mock IdP Key` |

Options → Response → Include Response Headers and Status **on**, Never Error
**on**, Timeout `15000`. Settings → Retry On Fail on, 3 tries, 2000 ms.

**`Build Offboard Steps`** (Code, Run Once for All Items):

```javascript
const run  = $('Create Offboard Run').first().json;
const emp  = $('Find Due Offboardings').first().json;
const res  = $input.first().json;

if (res.statusCode !== 200) {
  throw new Error(`IdP returned ${res.statusCode} for ${emp.work_email}; cannot plan offboarding`);
}
const user = res.body || {};
const root = `offboard:${emp.employee_ref}:${emp.end_date}`;
const steps = [];

steps.push({ step_order: 10, action_type: 'revoke_sessions', resource: '' });
let o = 20;
for (const g of (user.groups || []))   steps.push({ step_order: o++, action_type: 'remove_group',   resource: g });
o = 50;
for (const s of (user.licenses || [])) steps.push({ step_order: o++, action_type: 'revoke_license', resource: s });
steps.push({ step_order: 90, action_type: 'suspend_account', resource: '' });

return steps.map(s => ({
  json: {
    run_id: run.id,
    step_order: s.step_order,
    action_type: s.action_type,
    target_system: 'mockidp',
    resource: s.resource,
    is_privileged: false,
    idempotency_key: `${root}:${s.step_order}:${s.action_type}:${s.resource}`,
    status: 'pending',
  },
}));
```

**`Insert Offboard Steps`** (Postgres): Operation `Insert`, Table
`provisioning_steps`, Mapping Column Mode `Map Automatically`.

**`Dispatch Offboard`** (Execute Sub-workflow): Workflow `JML — Execute Plan`,
Workflow Inputs → run_id = `{{ $('Create Offboard Run').first().json.id }}`,
Options → Wait For Sub-Workflow Completion **on**.

**`Mark Offboarded`** (Postgres): Operation `Update`, Table `employees`,
Column to match on `id`, id = `{{ $('Find Due Offboardings').first().json.employee_id }}`,
status = `offboarded`, updated_at = `{{ $now.toISO() }}`.

---

### Branch B — stale approvals

#### `Find Stale Approvals` (Postgres, Execute Query)

```sql
SELECT r.id AS run_id, r.created_at, r.approval_sent_at, r.approval_expires_at,
       r.due_at, e.full_name, e.work_email, e.role_code, e.manager_email
FROM provisioning_runs r
JOIN employees e ON e.id = r.employee_id
WHERE r.status = 'awaiting_approval'
  AND r.approval_sent_at < now() - interval '4 hours'
  AND r.approval_expires_at > now()
ORDER BY r.created_at ASC
LIMIT 25;
```

Settings → Always Output Data **on**.

#### `Any Stale?` (If) → true → `Email Reminder` (Send Email)

| Parameter | Value |
|---|---|
| Credential | `JML SMTP` |
| From / To | your Gmail address |
| Subject | `{{ '[Reminder] approval pending for ' + $json.full_name + ' (' + $json.role_code + ')' }}` |
| Email Format | `HTML` |
| HTML | `<p>Run <code>{{ $json.run_id }}</code> for {{ $json.full_name }} has been waiting since {{ $json.approval_sent_at }}. It expires {{ $json.approval_expires_at }} and nothing will be provisioned if it lapses.</p><p>Intended approver: {{ $json.manager_email }}</p>` |

Then `Audit: approval_reminder_sent` (Postgres Insert into `audit_events`,
run_id `{{ $json.run_id }}`, actor `system:sweeper`,
event_type `approval_reminder_sent`, detail
`{{ JSON.stringify({ sent_at: $now.toISO() }) }}`).

---

### Branch C — SLA breaches

#### `Find SLA Breaches` (Postgres, Execute Query)

```sql
SELECT r.id AS run_id, r.run_type, r.status, r.due_at,
       e.full_name, e.work_email, e.role_code,
       round(EXTRACT(EPOCH FROM (now() - r.due_at)) / 3600.0, 1) AS hours_late
FROM provisioning_runs r
JOIN employees e ON e.id = r.employee_id
WHERE r.status IN ('planned','awaiting_approval','approved','running')
  AND r.due_at < now()
ORDER BY r.due_at ASC
LIMIT 25;
```

Settings → Always Output Data **on**.

#### `Any Breach?` (If) → true → `Email SLA Breach` + `Audit: sla_breached`

Subject: `{{ '[SLA BREACH] ' + $json.run_type + ' for ' + $json.full_name + ' is ' + $json.hours_late + 'h late' }}`

An offboarding past its due date is a security finding, not a chore. Say that
in the email body so the reader treats it that way.

---

## 5.2 WF9 — `JML — Access Review`

New workflow `JML — Access Review`. This closes the loop that most provisioning
systems leave open: proving that what is granted still matches what was intended.

### Node 1 — `Weekly` (Schedule Trigger)

| Parameter | Value |
|---|---|
| Trigger Interval | `Weeks` |
| Weeks Between Triggers | `1` |
| Trigger on Weekdays | `Monday` |
| Trigger at Hour | `8am` |
| Trigger at Minute | `0` |

### Node 2 — `Load Active Employees` (Postgres, Execute Query)

```sql
SELECT e.id, e.employee_ref, e.full_name, e.work_email, e.role_code, e.department
FROM employees e
WHERE e.status IN ('pending','active')
ORDER BY e.employee_ref;
```

### Node 3 — `Load Policy` (Postgres, Execute Query)

```sql
SELECT role_code, department, action_type, resource
FROM role_entitlements
WHERE action_type IN ('add_group','assign_license');
```

### Node 4 — `Loop Employees` (Loop Over Items, Batch Size `1`)

From the `loop` output:

**`Read Actual`** (HTTP Request): GET
`{{ 'http://127.0.0.1:8100/v1/users/' + encodeURIComponent($json.work_email) }}`,
Header Auth `Mock IdP Key`, Options → Include Response Headers and Status on,
Never Error on, Timeout `15000`.

**`Diff Entitlements`** (Code, Run Once for All Items):

```javascript
const emp    = $('Loop Employees').first().json;
const policy = $('Load Policy').all().map(i => i.json);
const res    = $input.first().json;

const intendedGroups = policy
  .filter(p => p.role_code === emp.role_code && p.department === emp.department && p.action_type === 'add_group')
  .map(p => p.resource);
const intendedLicenses = policy
  .filter(p => p.role_code === emp.role_code && p.department === emp.department && p.action_type === 'assign_license')
  .map(p => p.resource);

if (res.statusCode !== 200) {
  return [{ json: {
    employee_ref: emp.employee_ref, work_email: emp.work_email, role_code: emp.role_code,
    finding: 'no_account', extra_groups: [], missing_groups: intendedGroups,
    extra_licenses: [], missing_licenses: intendedLicenses, drift: true,
  }}];
}

const user = res.body || {};
const actualGroups   = user.groups   || [];
const actualLicenses = user.licenses || [];

const extraGroups     = actualGroups.filter(g => !intendedGroups.includes(g));
const missingGroups   = intendedGroups.filter(g => !actualGroups.includes(g));
const extraLicenses   = actualLicenses.filter(l => !intendedLicenses.includes(l));
const missingLicenses = intendedLicenses.filter(l => !actualLicenses.includes(l));

return [{ json: {
  employee_ref: emp.employee_ref, work_email: emp.work_email, role_code: emp.role_code,
  finding: extraGroups.length ? 'excess_access'
         : missingGroups.length ? 'incomplete_provisioning' : 'ok',
  extra_groups: extraGroups, missing_groups: missingGroups,
  extra_licenses: extraLicenses, missing_licenses: missingLicenses,
  drift: Boolean(extraGroups.length || missingGroups.length || extraLicenses.length || missingLicenses.length),
}}];
```

**`Audit: access_reviewed`** (Postgres Insert into `audit_events`): actor
`system:access-review`, event_type `access_reviewed`, detail
`{{ JSON.stringify($json) }}`. Connect its output back into `Loop Employees`.

From the `done` output: **`Summarise Drift`** (Code):

```javascript
const rows = $('Diff Entitlements').all().map(i => i.json);
const drifted = rows.filter(r => r.drift);
return [{ json: {
  reviewed: rows.length,
  drifted: drifted.length,
  excess_access: drifted.filter(r => r.finding === 'excess_access').length,
  no_account: drifted.filter(r => r.finding === 'no_account').length,
  detail: drifted,
}}];
```

Then a **Send Email** with the report. **The review reports; it does not
auto-remediate.** Auto-revoking on a drift signal would let a bug in this diff
lock people out of production on a Monday morning. A named human reads the
report and decides. Put that sentence in the README.

Activate both `JML — Sweeper` and `JML — Access Review`.

---

## 5.3 The audit queries that make this defensible

Save these in `db/audit_queries.sql`. They are what you screenshot for the
portfolio, and what you run when an auditor asks a question.

```sql
-- Complete story of one run, in order, from the audit log alone
SELECT created_at, actor, event_type, detail
FROM audit_events
WHERE run_id = '<run-uuid>'
ORDER BY id;

-- Who currently holds privileged entitlements, and under whose approval
SELECT e.work_email, e.role_code, s.resource, s.action_type,
       r.approved_by, r.approved_at, r.requested_by
FROM provisioning_steps s
JOIN provisioning_runs r ON r.id = s.run_id
JOIN employees e         ON e.id = r.employee_id
WHERE s.is_privileged AND s.status = 'succeeded'
ORDER BY r.approved_at DESC;

-- Anything provisioned WITHOUT an approval that should have had one
SELECT e.work_email, s.resource, r.id AS run_id, r.status
FROM provisioning_steps s
JOIN provisioning_runs r ON r.id = s.run_id
JOIN employees e         ON e.id = r.employee_id
WHERE s.is_privileged AND s.status = 'succeeded' AND r.approved_at IS NULL;
-- Expected: zero rows. If this ever returns anything, the gate has a hole.

-- Runs that ended dirty and still need a human
SELECT run_id, run_status, employee_ref, steps_failed, steps_compensated
FROM v_run_summary
WHERE run_status = 'failed';

-- Steps that reported success but could not be verified
SELECT run_id, employee_ref, steps_unverified FROM v_run_summary
WHERE steps_unverified > 0;

-- Median time from request to completion, by run type
SELECT run_type,
       count(*) AS runs,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds_to_complete)::numeric, 1) AS median_seconds
FROM v_run_summary
WHERE run_status = 'completed'
GROUP BY run_type;
```

The third query is the one to lead with in an interview. It is a control that
proves the control.

---

## 5.4 Test Stage 5

| # | Test | How | Expected |
|---|---|---|---|
| A | Due offboarding fires | Onboard `E-401` normally, then `UPDATE employees SET end_date = current_date WHERE employee_ref='E-401';` and run the Sweeper manually (Execute workflow) | An offboard run is created, executed, IdP shows `suspended` with empty groups and licences, `employees.status = 'offboarded'` |
| B | Sweeper is idempotent | Run the Sweeper 3 more times | Still exactly one offboard run for `E-401`. `SELECT count(*) FROM provisioning_runs WHERE run_type='offboard';` unchanged |
| C | Stale approval reminder | Submit an `ENG_SENIOR` request, do not click the link, then `UPDATE provisioning_runs SET approval_sent_at = now() - interval '5 hours' WHERE status='awaiting_approval';` and run the Sweeper | One reminder email, one `approval_reminder_sent` audit row |
| D | SLA breach | `UPDATE provisioning_runs SET due_at = now() - interval '3 hours' WHERE status='awaiting_approval';` run the Sweeper | `[SLA BREACH] … is 3h late` email |
| E | Drift detection | Grant a group by hand via curl, run `JML — Access Review` manually | The report lists that employee under `excess_access` with the extra group named |
| F | The control query holds | Run the third audit query above after every earlier test | Zero rows, always |

---

# Stage 6 · Production safeguards

None of this changes behaviour. All of it changes whether the project reads as
a demo or as something someone thought about running.

## 6.1 Secrets

| Rule | Where it applies |
|---|---|
| No key, password or token in any node field | Everything goes through n8n credentials |
| No secret in a Code node | The IdP base URL is config, not a secret; the API key is a credential |
| `.env` gitignored, `.env.example` committed | Already set up |
| n8n encryption key backed up outside `.n8n` | `%USERPROFILE%\.n8n\project-encryption-key.txt` |
| Rotate the mock IdP key before publishing | Change `MOCK_IDP_API_KEY` and the `Mock IdP Key` credential together |

Before you push, prove it:

```bash
cd "C:\path\to\jml-orchestrator"; git init; git add -A; git grep -nE "(npg_|AIza|AQ\.|sk-|password\s*=\s*[\"'][^\"']+)" -- . ':!*.example'
```

That must return nothing.

## 6.2 Timeouts and blast radius

| Guard | Value | Set where |
|---|---|---|
| HTTP timeout | 15000 ms | Every HTTP Request node → Options → Timeout |
| Forward retries | 3 tries, 2000 ms apart | `Call IdP` → Settings |
| Compensation retries | 5 tries, 3000 ms apart | `Undo Step` → Settings |
| Workflow timeout | 1 hour | Each workflow → Settings → Timeout Workflow |
| Approval expiry | 24 hours | `Build Plan`, `approval_expires_at` |
| Sweeper batch cap | `LIMIT 25` | Every sweeper query |
| Loop batch size | 1 | `Loop Steps`, `Loop Compensations` |

Batch size 1 is deliberate. Provisioning steps are ordered and dependent; a
batch of 10 running concurrently would try to add groups to an account that
does not exist yet.

## 6.3 Rate limits

The mock IdP returns `429` with `Retry-After: 2` when you arm `rate_limit`.
n8n's Retry On Fail already backs off by a fixed interval, which is enough
here. If you want to demonstrate that you know the difference, add this to the
top of `Build Request` as a comment rather than building it:

```
// Known limitation: fixed 2s backoff, 3 tries. A real IdP with a burst quota wants
// exponential backoff with jitter plus a token bucket in front of the loop.
// Add when a provider actually rate-limits us, not before.
```

## 6.4 Version control your workflows

Workflows that live only in n8n's SQLite are not a portfolio piece. Export them.

```bash
cd "C:\path\to\jml-orchestrator"; n8n export:workflow --all --separate --output=workflows/
```

Run that after any change. It writes one JSON file per workflow. Credentials
are **not** included, only credential *references* by name and id, which is why
the setup doc lists the four credential names exactly.

Then:

```bash
git add -A; git commit -m "Export workflows"
```

Add to the README that a reviewer restores them with:

```bash
n8n import:workflow --separate --input=workflows/
```

## 6.5 What a real deployment would need, and does not have here

Write these down honestly rather than implying they exist.

| Gap | What production needs |
|---|---|
| n8n runs in the default single-process mode | Queue mode: n8n main + Redis + one or more workers, `EXECUTIONS_MODE=queue`. Needed once concurrent runs exceed one process. |
| SQLite for n8n's own state | Postgres for n8n itself via `DB_TYPE=postgresdb` |
| Approval link is unauthenticated | SSO in front of `/webhook/jml-approval`, recording the authenticated subject in `approved_by` |
| Webhooks are on `localhost` | A public HTTPS URL, `WEBHOOK_URL` set to it, and HMAC signature verification on inbound webhooks |
| No secret rotation | Credentials rotated on a schedule; n8n supports external secret stores in its enterprise tier |
| Execution data retained forever | `EXECUTIONS_DATA_MAX_AGE` and pruning, because execution payloads contain employee data |
| One environment | Separate n8n instances for dev and prod, workflows promoted by import, not edited live |

## 6.6 Data retention

Add this to the schema when you are ready to claim it, and say in the README
that it is defined but not scheduled:

```sql
-- Purge execution-adjacent PII after 400 days, keep the audit skeleton forever.
UPDATE audit_events
SET detail = jsonb_build_object('redacted', true, 'event_type', event_type)
WHERE created_at < now() - interval '400 days'
  AND detail ? 'extracted';
```

---

## Stage 5 and 6 checklist

- [ ] The Sweeper creates exactly one offboard run no matter how often it runs.
- [ ] A stale approval produces a reminder, an overdue run produces a breach alert.
- [ ] The Access Review reports drift and does not act on it.
- [ ] The "privileged without approval" query returns zero rows.
- [ ] `git grep` for secrets returns nothing.
- [ ] `workflows/` contains one JSON file per workflow and is committed.
- [ ] The README lists the seven production gaps above without softening them.

Next: `07-stage7-8.md`.
