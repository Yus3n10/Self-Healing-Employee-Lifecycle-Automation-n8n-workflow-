# Stage 4 · Rollback, error workflow, and the safety net

**Goal:** a run that fails halfway undoes what it already did, in reverse order,
and tells a human. After this stage there is no such thing as a half-provisioned
account that nobody knows about.

**Time:** about 2 hours.

---

## 4.0 Why compensation and not a transaction

You cannot `BEGIN … ROLLBACK` across an external API. Once the IdP has created
an account, that fact exists in a system you do not control. The only way back
is to issue the **inverse call**, and the only way to know which inverse calls
to issue is the ledger you have been writing since Stage 2.

That pattern is a saga with compensating transactions. Three rules make it work:

1. **Compensate in reverse order.** You added groups after creating the account,
   so you remove groups before deleting the account.
2. **Only compensate steps recorded as `succeeded`.** A step that failed did
   nothing to undo. A step still `pending` never ran.
3. **Compensation must itself be idempotent and must never throw.** It runs when
   things are already broken. If rollback can fail loudly and stop, you are back
   to a half-provisioned account plus a confusing execution log.

---

## 4.1 WF4 — `JML — Rollback`

New workflow named exactly `JML — Rollback`.

### Node 1 — `When Executed by Another Workflow`

| Parameter | Value |
|---|---|
| Input data mode | `Define using fields below` |
| Workflow Input Fields | Name `run_id`, Type `String` |

### Node 2 — `Load Succeeded Steps` (Postgres, Execute Query)

```sql
SELECT s.id            AS step_id,
       s.step_order,
       s.action_type,
       s.resource,
       s.idempotency_key,
       e.work_email
FROM provisioning_steps s
JOIN provisioning_runs  r ON r.id = s.run_id
JOIN employees          e ON e.id = r.employee_id
WHERE s.run_id = $1
  AND s.status = 'succeeded'
ORDER BY s.step_order DESC;
```

**Options** → **Query Parameters**:
`{{ $('When Executed by Another Workflow').first().json.run_id }}`

Settings → **Always Output Data**: **on**. A run that failed on its very first
step has nothing to compensate, and that must not be an error.

`ORDER BY s.step_order DESC` is rule 1, expressed in one clause.

### Node 3 — `Build Compensations` (Code)

| Mode | `Run Once for All Items` |

```javascript
// Maps each successful action to its inverse. Static, exhaustive, boring.
// If an action has no inverse it is reported, never silently skipped.

const IDP_BASE = 'http://127.0.0.1:8100';
const runId = $('When Executed by Another Workflow').first().json.run_id;

const INVERSE = {
  create_account:  'delete_account',
  add_group:       'remove_group',
  assign_license:  'revoke_license',
  // Offboarding actions are not compensated. Re-granting access that was
  // deliberately revoked is never the safe default; a human re-runs onboarding.
  revoke_sessions: null,
  remove_group:    null,
  revoke_license:  null,
  suspend_account: null,
  delete_account:  null,
};

const out = [];
for (const item of $input.all()) {
  const s = item.json;
  if (!s || !s.step_id) continue;                 // empty item from Always Output Data

  const inverse = INVERSE[s.action_type];
  if (!inverse) {
    out.push({ json: { ...s, compensable: false, reason: `no inverse for ${s.action_type}` } });
    continue;
  }

  const email = encodeURIComponent(s.work_email);
  const res = encodeURIComponent(s.resource || '');
  let method, path;

  switch (inverse) {
    case 'delete_account':
      method = 'DELETE'; path = `/v1/users/${email}`; break;
    case 'remove_group':
      method = 'DELETE'; path = `/v1/users/${email}/groups/${res}`; break;
    case 'revoke_license':
      method = 'DELETE'; path = `/v1/users/${email}/licenses/${res}`; break;
  }

  out.push({
    json: {
      ...s,
      compensable: true,
      run_id: runId,
      inverse_action: inverse,
      method,
      url: IDP_BASE + path,
      // Distinct key: compensating is a different logical operation from the
      // original, so it must not collide with the original's stored response.
      compensation_key: `undo:${s.idempotency_key}`,
    },
  });
}

return out;
```

### Node 4 — `Loop Compensations` (Loop Over Items)

| Parameter | Value |
|---|---|
| Batch Size | `1` |

Options → Reset: off.

### Node 5 — from the `loop` output — `Compensable?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $json.compensable }}` |
| Operator | `Boolean` → `is true` |

**false** output → `Mark Not Compensable` (Postgres, Execute Query), then back
into `Loop Compensations`:

```sql
UPDATE provisioning_steps
SET status = 'compensation_failed',
    last_error = $2
WHERE id = $1;
```
**Query Parameters**: `{{ [ $json.step_id, $json.reason ] }}`

### Node 6 — true output — `Undo Step` (HTTP Request)

| Parameter | Value |
|---|---|
| Method | `{{ $json.method }}` |
| URL | `{{ $json.url }}` |
| Authentication | `Generic Credential Type` → `Header Auth` → `Mock IdP Key` |
| Send Query Parameters | off |
| Send Headers | **on**, `Using Fields Below` |
| Header Name | `Idempotency-Key` |
| Header Value | `{{ $json.compensation_key }}` |
| Send Body | off |

**Options** → Response → Include Response Headers and Status **on**;
Response → **Never Error** **on**; Timeout `15000`.

**Settings** tab:

| Setting | Value |
|---|---|
| Retry On Fail | **on** |
| Max Tries | `5` |
| Wait Between Tries (ms) | `3000` |
| On Error | `Continue (using error output)` |

Five tries here versus three in `Call IdP`. Rollback is the last line of
defence; it is worth more patience than the forward path.

### Node 7 — `Record Compensation` (Postgres, Execute Query)

Connect **both** the main and the error output of `Undo Step` into it.

```sql
UPDATE provisioning_steps
SET status = CASE WHEN $2::int BETWEEN 200 AND 299
                  THEN 'compensated' ELSE 'compensation_failed' END,
    last_error = CASE WHEN $2::int BETWEEN 200 AND 299
                      THEN NULL ELSE $3 END,
    finished_at = now()
WHERE id = $1;
```

**Query Parameters**:

```
{{ [ $('Compensable?').item.json.step_id, ($json.statusCode ?? 0), ('undo failed: ' + JSON.stringify($json.error ?? $json.body ?? {})).slice(0, 900) ] }}
```

### Node 8 — `Audit: step_compensated` (Postgres Insert into `audit_events`)

| Column | Value |
|---|---|
| run_id | `{{ $('Compensable?').item.json.run_id }}` |
| step_id | `{{ $('Compensable?').item.json.step_id }}` |
| actor | `system` |
| event_type | `step_compensated` |
| detail | `{{ JSON.stringify({ inverse_action: $('Compensable?').item.json.inverse_action, resource: $('Compensable?').item.json.resource, status_code: $json.statusCode ?? null }) }}` |

Connect this node's output back into **`Loop Compensations`**.

### Node 9 — from the `done` output — `Summarise Rollback` (Postgres, Execute Query)

```sql
SELECT count(*) FILTER (WHERE status = 'compensated')          AS compensated,
       count(*) FILTER (WHERE status = 'compensation_failed')  AS compensation_failed,
       count(*) FILTER (WHERE status = 'succeeded')            AS still_succeeded,
       count(*) FILTER (WHERE status = 'failed')               AS failed
FROM provisioning_steps
WHERE run_id = $1;
```
**Query Parameters**: `{{ $('When Executed by Another Workflow').first().json.run_id }}`

### Node 10 — `Close Run` (Postgres, Execute Query)

```sql
UPDATE provisioning_runs
SET status = CASE WHEN $2::int > 0 THEN 'failed' ELSE 'rolled_back' END,
    finished_at = now()
WHERE id = $1
RETURNING id, status;
```
**Query Parameters**:
`{{ [ $('When Executed by Another Workflow').first().json.run_id, $json.compensation_failed ] }}`

`rolled_back` means the system is clean. `failed` means something could not be
undone and a human must look. Two different words for two different situations
is the whole reason this node has a CASE in it.

### Node 11 — `Alert Incomplete Rollback` (If → Send Email)

**If** node `Rollback Clean?`:

| Setting | Value |
|---|---|
| Left Value | `{{ $('Summarise Rollback').first().json.compensation_failed }}` |
| Operator | `Number` → `is equal to` |
| Right Value | `0` |

**false** output → **Send Email**:

| Parameter | Value |
|---|---|
| Credential | `JML SMTP` |
| From / To | your Gmail address |
| Subject | `{{ '[ACTION REQUIRED] Rollback incomplete for run ' + $('When Executed by Another Workflow').first().json.run_id }}` |
| Email Format | `HTML` |
| HTML | see below |

```html
<div style="font-family:system-ui,sans-serif;max-width:640px">
  <h2 style="color:#991b1b">Manual cleanup required</h2>
  <p>Run <code>{{ $('When Executed by Another Workflow').first().json.run_id }}</code>
     failed and could not be fully rolled back.</p>
  <p>Compensated: {{ $('Summarise Rollback').first().json.compensated }} ·
     Could not compensate: <b>{{ $('Summarise Rollback').first().json.compensation_failed }}</b></p>
  <p>Run this to see exactly what is still granted:</p>
  <pre style="background:#f4f4f5;padding:12px;border-radius:6px;font-size:12px">SELECT step_order, action_type, resource, status, last_error
FROM provisioning_steps
WHERE run_id = '{{ $('When Executed by Another Workflow').first().json.run_id }}'
ORDER BY step_order;</pre>
</div>
```

### Node 12 — `Return Result` (Code)

Connect both branches of `Rollback Clean?` into it.

```javascript
const s = $('Summarise Rollback').first().json;
return [{ json: { rolled_back: Number(s.compensation_failed) === 0, ...s } }];
```

Save.

---

## 4.2 Wire rollback into WF2

Open `JML — Execute Plan`. Replace the placeholder `Trigger Rollback` NoOp node
(§2.19 node 7) with an **Execute Sub-workflow** node named `Trigger Rollback`:

| Parameter | Value |
|---|---|
| Source | `Database` |
| Workflow | `JML — Rollback` |
| Workflow Inputs → run_id | `{{ $('When Executed by Another Workflow').first().json.run_id }}` |
| Mode | `Run once with all items` |

**Options** → Wait For Sub-Workflow Completion: **on**.

After it, add `Audit: run_rolled_back` (Postgres Insert into `audit_events`):

| Column | Value |
|---|---|
| run_id | `{{ $('When Executed by Another Workflow').first().json.run_id }}` |
| actor | `system` |
| event_type | `run_rolled_back` |
| detail | `{{ JSON.stringify({ clean: $json.rolled_back, compensated: $json.compensated, compensation_failed: $json.compensation_failed, failed_step: $('Step OK?').first().json.action_type + ':' + $('Step OK?').first().json.resource, error: $('Step OK?').first().json.error }) }}` |

---

## 4.3 WF7 — `JML — Error Handler`

Everything above handles *expected* failure. This handles the rest: a Postgres
outage, a bad expression, an n8n restart mid-execution.

New workflow named exactly `JML — Error Handler`.

### Node 1 — `Error Trigger`

No parameters. It fires when any workflow that names this one as its Error
Workflow fails.

Its output looks like:

```json
{
  "execution": { "id": "…", "url": "…", "error": { "message": "…", "stack": "…" }, "lastNodeExecuted": "Call IdP", "mode": "trigger" },
  "workflow": { "id": "…", "name": "JML — Execute Step" }
}
```

### Node 2 — `Shape Error` (Code)

```javascript
const e = $input.first().json;
const ex = e.execution || {};
const wf = e.workflow || {};
return [{
  json: {
    workflow_name: wf.name || 'unknown',
    workflow_id: wf.id || null,
    execution_id: ex.id || null,
    execution_url: ex.url || null,
    last_node: ex.lastNodeExecuted || null,
    message: String((ex.error && ex.error.message) || 'unknown error').slice(0, 900),
    stack: String((ex.error && ex.error.stack) || '').slice(0, 2000),
    at: new Date().toISOString(),
  },
}];
```

### Node 3 — `Audit: workflow_error` (Postgres Insert into `audit_events`)

| Column | Value |
|---|---|
| actor | `system` |
| event_type | `workflow_error` |
| detail | `{{ JSON.stringify($json) }}` |

Settings → **On Error**: `Continue (using error output)`.
If the database is what failed, this insert also fails, and the error handler
must still send the email. An error handler that can itself die silently is
worse than none.

### Node 4 — `Email Error` (Send Email)

Connect **both** outputs of the audit node into it.

| Parameter | Value |
|---|---|
| Credential | `JML SMTP` |
| From / To | your Gmail address |
| Subject | `{{ '[JML failure] ' + $('Shape Error').first().json.workflow_name + ' at ' + $('Shape Error').first().json.last_node }}` |
| Email Format | `HTML` |
| HTML | see below |

```html
<div style="font-family:system-ui,sans-serif;max-width:680px">
  <h2 style="color:#991b1b;margin:0 0 8px">Workflow failed</h2>
  <table cellpadding="6" style="border-collapse:collapse;font-size:14px">
    <tr><td><b>Workflow</b></td><td>{{ $('Shape Error').first().json.workflow_name }}</td></tr>
    <tr><td><b>Failed at node</b></td><td><code>{{ $('Shape Error').first().json.last_node }}</code></td></tr>
    <tr><td><b>Execution</b></td><td><a href="{{ $('Shape Error').first().json.execution_url }}">{{ $('Shape Error').first().json.execution_id }}</a></td></tr>
    <tr><td><b>When</b></td><td>{{ $('Shape Error').first().json.at }}</td></tr>
  </table>
  <pre style="background:#f4f4f5;padding:12px;border-radius:6px;font-size:12px;white-space:pre-wrap">{{ $('Shape Error').first().json.message }}</pre>
</div>
```

Save. Do **not** set an Error Workflow on this workflow itself; that is a loop.

### Now set it everywhere else

For each of `JML — Intake & Plan`, `JML — Execute Plan`, `JML — Execute Step`,
`JML — Rollback`, `JML — Approval Callback`, `JML — AI Intake`:

three-dot menu → **Settings** → **Error Workflow** → `JML — Error Handler` →
**Save**.

---

## 4.4 Test Stage 4

Reset the IdP and truncate the tables first (commands in `03-stage2.md` §2.21).

### Test A — rollback on a mid-plan failure

Arm the fault so that licence assignment fails permanently:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"fail_action\",\"target_action\":\"assign_license\",\"remaining\":50}" http://127.0.0.1:8100/admin/chaos
```

Submit an onboard for `E-301`, `Katherine Johnson`, `Sales`, `SALES_REP`.

**Expected sequence:** steps 10, 20, 21 succeed. Step 50 retries 3 times and
fails. The loop breaks. Rollback runs in reverse: `revoke_license` is not needed
(that step never succeeded), `remove_group sales`, `remove_group all-staff`,
`delete_account`.

```sql
SELECT step_order, action_type, resource, status FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```
→ 10 `compensated`, 20 `compensated`, 21 `compensated`, 50 `failed`, 51 `pending`.

```sql
SELECT status FROM provisioning_runs ORDER BY created_at DESC LIMIT 1;
```
→ `rolled_back`

```bash
curl.exe -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/v1/users/katherine.johnson@demo-corp.test
```
→ `status: "deleted"`, `groups: []`, `licenses: []`

**This is the money test.** Record your screen for it. The account exists in a
clean state, the ledger explains every transition, and nobody had to know.

Clear the fault:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"off\"}" http://127.0.0.1:8100/admin/chaos
```

### Test B — rollback that cannot finish alerts a human

Arm a fault on the inverse action instead:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"fail_action\",\"target_action\":\"remove_group\",\"remaining\":50}" http://127.0.0.1:8100/admin/chaos
```

Then arm the forward failure too by submitting `E-302`, `SALES_REP`, and while
it runs, switch the chaos target. Easier: run Test A again for `E-302` with
`target_action` set to `assign_license`, wait for the failure, then immediately
re-arm on `remove_group` before rollback starts. If the timing is awkward,
instead set `mode: flaky, remaining: 50`, which fails everything including
compensations.

**Expected:** run status `failed` (not `rolled_back`), some steps
`compensation_failed`, and an `[ACTION REQUIRED] Rollback incomplete` email in
your inbox containing a copy-pasteable SQL query.

### Test C — the error workflow catches what nothing else does

Temporarily break a credential: edit `JML Postgres`, change the password to
`wrong`, save. Submit any request.

**Expected:** the execution goes red, and within seconds a
`[JML failure] JML — Intake & Plan at …` email arrives naming the exact node.
Fix the password afterwards.

### Test D — replay safety after rollback

With chaos off, resubmit the **same** `E-301` request (same ref, same date).

**Expected:** blocked by `Stop (Duplicate)`. The rolled-back run still occupies
`idempotency_root`. To genuinely retry, a human changes the effective date or
an operator resets the run status. That is correct: silent auto-retry of a run
that already caused and undid side effects is not something a workflow should
decide on its own.

---

## Stage 4 checklist

- [ ] A mid-plan failure leaves the IdP in the state it was in before the run.
- [ ] The ledger distinguishes `failed`, `compensated`, and `compensation_failed`.
- [ ] `rolled_back` and `failed` mean different things and you can say which is which.
- [ ] An unrecoverable rollback emails a human with a query to run.
- [ ] A credential outage produces an alert, not silence.
- [ ] Every workflow except the error handler names the error handler.

### Common Stage 4 errors

| Symptom | Cause | Fix |
|---|---|---|
| Rollback compensates in the wrong order | `ORDER BY` is ASC | It must be `ORDER BY s.step_order DESC` |
| `delete_account` runs before `remove_group` | Same as above | Same fix |
| Rollback loops forever | `Record Compensation` or the audit node not connected back into `Loop Compensations` | Connect exactly one path back into the loop node |
| `Undo Step` throws and aborts | Never Error off, or On Error not set to continue | Set both as specified in §4.1 node 6 |
| Error Handler never fires | Workflow Settings → Error Workflow not set, or set only on the parent | Set it on every workflow individually; it is per-workflow |
| Error emails arrive in a loop | The Error Handler names itself as its own error workflow | Leave the Error Handler's own Error Workflow empty |

Next: `06-stage5-6.md`.
