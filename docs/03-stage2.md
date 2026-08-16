# Stage 2 · Policy, plan, ledger, approval, ordered execution

**Goal:** the request stops being "create one account" and becomes a *plan* of
N ordered steps derived from a policy table, written to a ledger, gated by a
human approval when any step is privileged, and executed one step at a time
with per-step verification.

By the end you will have four workflows instead of one.

**Time:** about 4 hours. Do it in the sub-stage order given; test after each.

---

## 2.1 Rewire `JML — Intake & Plan`

Open the workflow from Stage 1. You are keeping `On form submission`,
`Normalize Request`, `Is Valid?`, `Reject Invalid Request` and
`Upsert Employee`. You are **deleting** `IdP: Create Account` and
`Audit: account_created` (select each and press Delete). Those move into WF3.

The new shape is:

```
On form submission → Normalize Request → Is Valid? ─true→ Upsert Employee → Check Duplicate Run → Is New Run?
                                                  └false→ Reject Invalid Request      │
                                                                                       ├─false→ Log Duplicate → Stop (Duplicate)
                                                                                       └─true→ Route By Type ─onboard→ Load Entitlements ──┐
                                                                                                            └offboard→ Read Current State ─┤
                                                                                                                                            ▼
                                                                                                                                      Build Plan
                                                                                                                                            ▼
                                                                                                                                      Create Run
                                                                                                                                            ▼
                                                                                                                                      Insert Steps
                                                                                                                                            ▼
                                                                                                                                   Needs Approval? ─true→ Send Approval Email → Wait For Approval → Load Decision → Decision? ─approved→ ┐
                                                                                                                                            │                                                                        └other→ Close Rejected │
                                                                                                                                            └false──────────────────────────────────────────────────────────────────────────────────────────┤
                                                                                                                                                                                                                                             ▼
                                                                                                                                                                                                                                    Execute Plan (sub-workflow)
```

---

## 2.2 Node — `Check Duplicate Run` (Postgres)

Add after `Upsert Employee`.

| Parameter | Value |
|---|---|
| Credential | `JML Postgres` |
| Operation | `Select` |
| Schema | `public` |
| Table | `provisioning_runs` |
| Return All | **on** |
| Select Rows | (open this section) |

Under **Select Rows**, click **Add Condition**:

| Column | Operation | Value |
|---|---|---|
| `idempotency_root` | `equals` | `{{ $('Normalize Request').item.json.idempotency_root }}` |

Now open the node's **Settings** tab and set:

| Setting | Value |
|---|---|
| Always Output Data | **on** |

That toggle is the whole point of this node. Without it, a query returning zero
rows emits nothing and the branch below never runs. With it, zero rows emits a
single empty item `{}`, which the If node can test.

---

## 2.3 Node — `Is New Run?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $json.id }}` |
| Data type / Operator | `String` → `is empty` |

**true** = no existing run, continue. **false** = duplicate.

### False branch: `Log Duplicate` (Postgres) then `Stop (Duplicate)` (Stop and Error)

`Log Duplicate` — Postgres node:

| Parameter | Value |
|---|---|
| Operation | `Insert` |
| Table | `audit_events` |
| Mapping Column Mode | `Map Each Column Manually` |
| run_id | `{{ $json.id }}` |
| actor | `system` |
| event_type | `duplicate_request_blocked` |
| detail | `{{ JSON.stringify({ idempotency_root: $('Normalize Request').item.json.idempotency_root, existing_run_status: $json.status, requested_by: $('Normalize Request').item.json.requested_by }) }}` |

`Stop (Duplicate)` — Stop and Error node:

| Parameter | Value |
|---|---|
| Error Type | `Error Message` |
| Error Message | `{{ 'Duplicate request blocked. Run ' + $('Check Duplicate Run').item.json.id + ' already exists with status ' + $('Check Duplicate Run').item.json.status }}` |

> **Why the database enforces this, not the workflow.** `idempotency_root` is a
> UNIQUE column. Even if two form submissions raced past this check at the same
> millisecond, the second `INSERT` into `provisioning_runs` would fail. The If
> node gives a readable message; the constraint gives the guarantee. Check
> *and* constrain, because a check alone is a race condition.

---

## 2.4 Node — `Route By Type` (Switch)

From the **true** output of `Is New Run?`, add a **Switch** node.

| Parameter | Value |
|---|---|
| Mode | `Rules` |
| Number of Outputs | (automatic, from your rules) |

Add two routing rules:

| # | Left Value | Operator | Right Value | Rename Output |
|---|---|---|---|---|
| 1 | `{{ $('Normalize Request').item.json.request_type }}` | String → `is equal to` | `onboard` | `onboard` |
| 2 | `{{ $('Normalize Request').item.json.request_type }}` | String → `is equal to` | `offboard` | `offboard` |

Open **Options** and add **Fallback Output** = `None`. An unroutable request
should die loudly, not fall through.

---

## 2.5 Onboard branch — `Load Entitlements` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Select` |
| Table | `role_entitlements` |
| Return All | **on** |

**Select Rows** → two conditions, combined with `AND`:

| Column | Operation | Value |
|---|---|---|
| `role_code` | `equals` | `{{ $('Normalize Request').item.json.role_code }}` |
| `department` | `equals` | `{{ $('Normalize Request').item.json.department }}` |

**Data out:** one item per entitlement row (5 to 7 of them).

Settings tab → **Always Output Data**: **on**. A role with no entitlements must
produce a visible empty plan, not a vanished execution.

---

## 2.6 Offboard branch — `Read Current State` (HTTP Request)

Offboarding does **not** read the policy table. It reads what the account
*actually has right now*, because that is the only thing that tells you what
must be taken away. If somebody was granted a group by hand outside this
system, policy would miss it and the leaver would keep access.

| Parameter | Value |
|---|---|
| Method | `GET` |
| URL | `{{ 'http://127.0.0.1:8100/v1/users/' + encodeURIComponent($('Normalize Request').item.json.work_email) }}` |
| Authentication | `Generic Credential Type` |
| Generic Auth Type | `Header Auth` |
| Credential | `Mock IdP Key` |
| Send Query Parameters | off |
| Send Headers | off |
| Send Body | off |

**Options** → add:

| Option | Sub-setting | Value |
|---|---|---|
| Response | Include Response Headers and Status | **on** |
| Response | Never Error | **on** |
| Timeout | | `15000` |

`Never Error` is on here because a 404 (no such account) is a legitimate
answer, not a crash. The Build Plan node handles it.

**Settings** tab → Retry On Fail **on**, Max Tries `3`, Wait Between Tries
`2000`.

---

## 2.7 Node — `Build Plan` (Code)

Connect **both** the `Load Entitlements` output **and** the
`Read Current State` output into this single node. n8n allows two connections
into one input; only the branch that ran will deliver items.

| Parameter | Value |
|---|---|
| Mode | `Run Once for All Items` |
| Language | `JavaScript` |

```javascript
// Produces the ordered list of side effects this run will perform, plus the
// run-level metadata. This node is the only place that decides WHAT happens.
// It is deterministic on purpose: same request + same policy => same plan.

const req = $('Normalize Request').first().json;
const employee = $('Upsert Employee').first().json;
const items = $input.all().map(i => i.json);

const steps = [];

if (req.request_type === 'onboard') {
  // Source of truth: the policy table.
  const ents = items
    .filter(r => r && r.action_type)
    .sort((a, b) => a.step_order - b.step_order);

  if (ents.length === 0) {
    throw new Error(
      `No entitlements defined for role ${req.role_code} in ${req.department}. ` +
      `Add rows to role_entitlements before provisioning this role.`
    );
  }
  for (const e of ents) {
    steps.push({
      step_order:    e.step_order,
      action_type:   e.action_type,
      target_system: e.target_system,
      resource:      e.resource || '',
      is_privileged: e.is_privileged === true,
    });
  }
} else {
  // Source of truth: the account's ACTUAL current state, not the policy.
  // Anything granted outside this system still gets revoked.
  const res = items[0] || {};
  const status = res.statusCode;
  const user = res.body || {};

  if (status !== 200) {
    throw new Error(
      `Cannot plan offboarding: IdP returned ${status} for ${req.work_email}. ` +
      `Nothing to revoke, or the account does not exist.`
    );
  }

  steps.push({ step_order: 10, action_type: 'revoke_sessions',
               target_system: 'mockidp', resource: '', is_privileged: false });

  let order = 20;
  for (const g of (user.groups || [])) {
    steps.push({ step_order: order++, action_type: 'remove_group',
                 target_system: 'mockidp', resource: g, is_privileged: false });
  }
  order = 50;
  for (const sku of (user.licenses || [])) {
    steps.push({ step_order: order++, action_type: 'revoke_license',
                 target_system: 'mockidp', resource: sku, is_privileged: false });
  }
  steps.push({ step_order: 90, action_type: 'suspend_account',
               target_system: 'mockidp', resource: '', is_privileged: false });
  // Deliberately no delete_account. Suspend preserves the record for the
  // retention window; a separate purge job would handle deletion later.
}

// Approval policy. Two independent triggers, both deterministic.
const hasPrivileged  = steps.some(s => s.is_privileged);
const isAdminRole    = req.role_code === 'IT_ADMIN';
const requiresApproval = hasPrivileged || isAdminRole;

const rnd = () =>
  (globalThis.crypto && globalThis.crypto.randomUUID)
    ? globalThis.crypto.randomUUID().replace(/-/g, '')
    : Array.from({ length: 32 },
        () => Math.floor(Math.random() * 16).toString(16)).join('');

// SLA: onboarding should be done by 09:00 on the start date; offboarding by
// 17:00 on the last day. Both in Asia/Manila, which is why the workflow
// timezone setting matters.
const dueHour = req.request_type === 'onboard' ? 9 : 17;
const due = DateTime
  .fromISO(req.effective_date, { zone: 'Asia/Manila' })
  .set({ hour: dueHour, minute: 0, second: 0 });

const plan = {
  employee_id:       employee.id,
  work_email:        req.work_email,
  run_type:          req.request_type,
  requires_approval: requiresApproval,
  approval_reason:   hasPrivileged
                       ? steps.filter(s => s.is_privileged)
                              .map(s => `${s.action_type}:${s.resource}`).join(', ')
                       : (isAdminRole ? 'role IT_ADMIN' : ''),
  approval_token:      requiresApproval ? rnd() : null,
  approval_expires_at: requiresApproval ? DateTime.now().plus({ hours: 24 }).toISO() : null,
  resume_url:          requiresApproval ? $execution.resumeUrl : null,
  status:              requiresApproval ? 'awaiting_approval' : 'planned',
  requested_by:        req.requested_by,
  idempotency_root:    req.idempotency_root,
  due_at:              due.toISO(),
  step_count:          steps.length,
  steps:               steps.map(s => ({
    ...s,
    idempotency_key: `${req.idempotency_root}:${s.step_order}:${s.action_type}:${s.resource}`,
  })),
};

return [{ json: plan }];
```

**Data out:** exactly one item, containing a `steps` array.

> `DateTime` is Luxon and is available inside n8n Code nodes with no import.
> `$execution.resumeUrl` is the URL that will release this execution's Wait
> node. It is readable *before* the Wait node runs, which is the only reason
> the approval email can contain a working link.

---

## 2.8 Node — `Create Run` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Insert` |
| Table | `provisioning_runs` |
| Mapping Column Mode | `Map Each Column Manually` |

| Column | Value |
|---|---|
| employee_id | `{{ $json.employee_id }}` |
| run_type | `{{ $json.run_type }}` |
| status | `{{ $json.status }}` |
| requires_approval | `{{ $json.requires_approval }}` |
| approval_token | `{{ $json.approval_token }}` |
| approval_expires_at | `{{ $json.approval_expires_at }}` |
| resume_url | `{{ $json.resume_url }}` |
| requested_by | `{{ $json.requested_by }}` |
| idempotency_root | `{{ $json.idempotency_root }}` |
| due_at | `{{ $json.due_at }}` |

Leave `id`, `created_at`, `approved_by`, `approved_at`, `decision`,
`approval_sent_at`, `started_at`, `finished_at` blank.

**Data out:** the inserted row, including the generated `id`.

---

## 2.9 Node — `Expand Steps` (Code)

The plan is one item with an array inside it. The Postgres node inserts one row
per item, so the array has to become N items first.

| Parameter | Value |
|---|---|
| Mode | `Run Once for All Items` |
| Language | `JavaScript` |

```javascript
const run = $('Create Run').first().json;
const plan = $('Build Plan').first().json;

return plan.steps.map(s => ({
  json: {
    run_id:          run.id,
    step_order:      s.step_order,
    action_type:     s.action_type,
    target_system:   s.target_system,
    resource:        s.resource,
    is_privileged:   s.is_privileged,
    idempotency_key: s.idempotency_key,
    status:          'pending',
  },
}));
```

---

## 2.10 Node — `Insert Steps` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Insert` |
| Table | `provisioning_steps` |
| Mapping Column Mode | `Map Automatically` |

`Map Automatically` works here because the Code node above emits keys whose
names already match the column names exactly. That is why it was written that
way.

---

## 2.11 Node — `Audit: run_planned` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Insert` |
| Table | `audit_events` |
| Mapping Column Mode | `Map Each Column Manually` |
| run_id | `{{ $('Create Run').first().json.id }}` |
| actor | `{{ $('Normalize Request').first().json.requested_by }}` |
| event_type | `run_planned` |
| detail | `{{ JSON.stringify({ run_type: $('Build Plan').first().json.run_type, step_count: $('Build Plan').first().json.step_count, requires_approval: $('Build Plan').first().json.requires_approval, approval_reason: $('Build Plan').first().json.approval_reason, steps: $('Build Plan').first().json.steps.map(s => s.step_order + ':' + s.action_type + ':' + s.resource), due_at: $('Build Plan').first().json.due_at }) }}` |

Settings tab → **Execute Once**: **on**. Without it this node fires once per
step item coming out of `Insert Steps` and you get 7 identical audit rows.

---

## 2.12 Node — `Needs Approval?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $('Build Plan').first().json.requires_approval }}` |
| Data type / Operator | `Boolean` → `is true` |

Settings tab → **Execute Once**: **on**.

---

## 2.13 True branch — `Send Approval Email` (Send Email)

Add a **Send Email** node (search `Send Email`, the SMTP one, not Gmail).

| Parameter | Value |
|---|---|
| Credential | `JML SMTP` |
| From Email | your Gmail address, e.g. `ops@example.com` |
| To Email | your Gmail address (see note) |
| Subject | `{{ '[Approval needed] ' + $('Build Plan').first().json.run_type + ' — ' + $('Normalize Request').first().json.full_name + ' (' + $('Normalize Request').first().json.role_code + ')' }}` |
| Email Format | `HTML` |
| HTML | paste the block below |

> **To Email.** In the demo the manager address is `@demo-corp.test`, which
> does not exist, so mail to it bounces. Send to yourself and print the real
> intended approver in the body. In production this field would be
> `{{ $('Normalize Request').first().json.manager_email }}`. Say this in the
> README rather than pretending the demo delivers to a real manager.

```html
<div style="font-family:system-ui,-apple-system,Segoe UI,sans-serif;max-width:640px">
  <h2 style="margin:0 0 4px">Approval required</h2>
  <p style="color:#555;margin:0 0 16px">
    Intended approver: <b>{{ $('Normalize Request').first().json.manager_email }}</b><br>
    Requested by: {{ $('Normalize Request').first().json.requested_by }}
  </p>

  <table cellpadding="6" style="border-collapse:collapse;font-size:14px">
    <tr><td><b>Request</b></td><td>{{ $('Build Plan').first().json.run_type }}</td></tr>
    <tr><td><b>Person</b></td><td>{{ $('Normalize Request').first().json.full_name }} ({{ $('Normalize Request').first().json.employee_ref }})</td></tr>
    <tr><td><b>Role</b></td><td>{{ $('Normalize Request').first().json.role_code }} / {{ $('Normalize Request').first().json.department }}</td></tr>
    <tr><td><b>Work email</b></td><td>{{ $('Build Plan').first().json.work_email }}</td></tr>
    <tr><td><b>Effective</b></td><td>{{ $('Normalize Request').first().json.effective_date }}</td></tr>
    <tr><td><b>Why approval</b></td><td style="color:#b00">{{ $('Build Plan').first().json.approval_reason }}</td></tr>
    <tr><td><b>Run ID</b></td><td><code>{{ $('Create Run').first().json.id }}</code></td></tr>
  </table>

  <h3 style="margin:20px 0 6px">Plan ({{ $('Build Plan').first().json.step_count }} steps)</h3>
  <pre style="background:#f4f4f5;padding:12px;border-radius:6px;font-size:13px">{{ $('Build Plan').first().json.steps.map(s => (s.is_privileged ? '[PRIVILEGED] ' : '              ') + s.step_order + '  ' + s.action_type + '  ' + s.resource).join('\n') }}</pre>

  <p style="margin:24px 0">
    <a href="http://localhost:5678/webhook/jml-approval?token={{ $('Build Plan').first().json.approval_token }}&decision=approve"
       style="background:#166534;color:#fff;padding:10px 18px;border-radius:6px;text-decoration:none;margin-right:8px">Approve</a>
    <a href="http://localhost:5678/webhook/jml-approval?token={{ $('Build Plan').first().json.approval_token }}&decision=reject"
       style="background:#991b1b;color:#fff;padding:10px 18px;border-radius:6px;text-decoration:none">Reject</a>
  </p>

  <p style="color:#777;font-size:12px">
    This link expires {{ $('Build Plan').first().json.approval_expires_at }}.
    If nobody acts before then the run is marked expired and nothing is provisioned.
    Demo system, synthetic data.
  </p>
</div>
```

Then add a small Postgres node after it, `Mark Approval Sent`:

| Parameter | Value |
|---|---|
| Operation | `Update` |
| Table | `provisioning_runs` |
| Column to match on | `id` |
| id | `{{ $('Create Run').first().json.id }}` |
| approval_sent_at | `{{ $now.toISO() }}` |

---

## 2.14 Node — `Wait For Approval` (Wait)

| Parameter | Value |
|---|---|
| Resume | `On Webhook Call` |
| HTTP Method | `GET` |
| Respond | `Immediately` |
| Limit Wait Time | **on** |
| Limit Type | `After Time Interval` |
| Resume Amount | `24` |
| Resume Unit | `Hours` |

When the time limit expires the workflow **continues** rather than failing.
That is why the next node re-reads the decision from the database instead of
trusting the resumed payload.

---

## 2.15 Node — `Load Decision` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Select` |
| Table | `provisioning_runs` |
| Return All | off |
| Limit | `1` |

**Select Rows** → one condition:

| Column | Operation | Value |
|---|---|---|
| `id` | `equals` | `{{ $('Create Run').first().json.id }}` |

Settings tab → **Always Output Data**: **on**.

> **Why not read the Wait node's output.** The shape of a resumed webhook
> payload has changed between n8n versions, and a timeout produces no payload at
> all. The decision is a fact about the business process, so it belongs in the
> database. Reading it back makes this node correct on every version, correct on
> timeout, and correct after an n8n restart mid-wait. It also means the decision
> is already persisted for the audit trail without a second write.

---

## 2.16 Node — `Decision?` (Switch)

| Parameter | Value |
|---|---|
| Mode | `Rules` |

| # | Left Value | Operator | Right Value | Output name |
|---|---|---|---|---|
| 1 | `{{ $json.decision }}` | String → `is equal to` | `approved` | `approved` |
| 2 | `{{ $json.decision }}` | String → `is equal to` | `rejected` | `rejected` |

**Options** → **Fallback Output** → `Extra Output` and rename it `expired`.
No decision after 24 hours means expired.

### `rejected` output → `Close Rejected` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Update` |
| Table | `provisioning_runs` |
| Column to match on | `id` |
| id | `{{ $('Create Run').first().json.id }}` |
| status | `rejected` |
| finished_at | `{{ $now.toISO() }}` |

### `expired` output → `Close Expired` (Postgres)

Same as above with `status` = `expired`.

Add an `Audit: approval_outcome` Postgres Insert after each, with
`event_type` = `approval_rejected` and `approval_expired` respectively,
`run_id` = `{{ $('Create Run').first().json.id }}`, `actor` = `system`,
`detail` = `{{ JSON.stringify({ decided_at: $now.toISO() }) }}`.

---

## 2.17 Both paths converge — `Execute Plan` (Execute Sub-workflow)

Connect the `approved` output of `Decision?` **and** the `false` output of
`Needs Approval?` into this node.

You cannot configure it until WF2 exists, so build WF2 first (§2.19), then come
back. Its settings are:

| Parameter | Value |
|---|---|
| Source | `Database` |
| Workflow | `JML — Execute Plan` (pick from list) |
| Workflow Inputs → run_id | `{{ $('Create Run').first().json.id }}` |
| Mode | `Run once with all items` |

**Options** → **Wait For Sub-Workflow Completion**: **on**.

---

## 2.18 WF5 — `JML — Approval Callback`

Create a **new workflow** named exactly `JML — Approval Callback`.

### Node 1 — `Approval Webhook` (Webhook)

| Parameter | Value |
|---|---|
| Authentication | `None` |
| HTTP Method | `GET` |
| Path | `jml-approval` |
| Respond | `Using 'Respond to Webhook' Node` |

**Options** → add **Raw Body**: off.

### Node 2 — `Read Token` (Code)

```javascript
const q = ($input.first().json.query) || {};
const token = String(q.token || '').trim();
const decision = String(q.decision || '').trim().toLowerCase();
const clientIp = String(
  ($input.first().json.headers || {})['x-forwarded-for'] || 'local'
);

return [{
  json: {
    token,
    decision: decision === 'approve' ? 'approved'
            : decision === 'reject'  ? 'rejected'
            : '',
    client_ip: clientIp,
    input_ok: token.length === 32 && ['approve', 'reject'].includes(decision),
  },
}];
```

### Node 3 — `Find Run` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Select` |
| Table | `provisioning_runs` |
| Return All | off, Limit `1` |

**Select Rows**:

| Column | Operation | Value |
|---|---|---|
| `approval_token` | `equals` | `{{ $json.token }}` |

Settings → **Always Output Data**: **on**.

### Node 4 — `Is Actionable?` (If)

Conditions combined with `AND`:

| # | Left Value | Operator | Right Value |
|---|---|---|---|
| 1 | `{{ $('Read Token').first().json.input_ok }}` | Boolean → `is true` | |
| 2 | `{{ $json.id }}` | String → `is not empty` | |
| 3 | `{{ $json.status }}` | String → `is equal to` | `awaiting_approval` |
| 4 | `{{ $json.approval_expires_at }}` | DateTime → `is after` | `{{ $now.toISO() }}` |

Every one of those four is a real attack or bug you are closing: malformed
input, unknown token, replayed decision on an already-decided run, and an
expired link.

### True branch

**Node 5 — `Record Decision`** (Postgres):

| Parameter | Value |
|---|---|
| Operation | `Update` |
| Table | `provisioning_runs` |
| Column to match on | `id` |
| id | `{{ $json.id }}` |
| decision | `{{ $('Read Token').first().json.decision }}` |
| status | `{{ $('Read Token').first().json.decision === 'approved' ? 'approved' : 'rejected' }}` |
| approved_by | `{{ $json.requested_by ? $('Find Run').first().json.approval_token.slice(0,8) : '' }}` — **replace with** `{{ 'link-holder@' + $('Read Token').first().json.client_ip }}` |
| approved_at | `{{ $now.toISO() }}` |
| approval_token | `{{ null }}` |

Setting `approval_token` to null makes the link single-use. A second click
fails condition 2 of `Is Actionable?`.

> **`approved_by` is honest, not impressive.** The demo cannot prove who
> clicked. Recording `link-holder@<ip>` states exactly what is known. A
> production version puts SSO in front of this endpoint and records the
> authenticated subject. Put that sentence in the README.

**Node 6 — `Audit: decision`** (Postgres Insert into `audit_events`):

| Column | Value |
|---|---|
| run_id | `{{ $('Find Run').first().json.id }}` |
| actor | `{{ 'link-holder@' + $('Read Token').first().json.client_ip }}` |
| event_type | `{{ 'approval_' + $('Read Token').first().json.decision }}` |
| detail | `{{ JSON.stringify({ intended_approver: null, decided_at: $now.toISO(), client_ip: $('Read Token').first().json.client_ip }) }}` |

**Node 7 — `Release Wait`** (HTTP Request):

| Parameter | Value |
|---|---|
| Method | `GET` |
| URL | `{{ $('Find Run').first().json.resume_url }}` |
| Authentication | `None` |
| Send Query Parameters | off |
| Send Headers | off |
| Send Body | off |

**Options** → Response → Never Error **on**; Timeout `10000`.
**Settings** → Retry On Fail **on**, Max Tries `3`, Wait Between Tries `2000`.

**Node 8 — `Respond OK`** (Respond to Webhook):

| Parameter | Value |
|---|---|
| Respond With | `Text` |
| Response Body | `{{ 'Decision recorded: ' + $('Read Token').first().json.decision + '. You can close this tab.' }}` |
| Response Code | `200` |

**Options** → **Response Headers** → Add: Name `Content-Type`, Value
`text/plain; charset=utf-8`.

### False branch — `Respond Rejected` (Respond to Webhook)

| Parameter | Value |
|---|---|
| Respond With | `Text` |
| Response Body | `This approval link is invalid, already used, or expired.` |
| Response Code | `410` |

Save, then **Activate** the workflow with the toggle at the top right.
A Webhook trigger only serves its production URL while the workflow is active.

---

## 2.19 WF2 — `JML — Execute Plan`

New workflow named exactly `JML — Execute Plan`.

### Node 1 — `When Executed by Another Workflow` (Execute Sub-workflow Trigger)

| Parameter | Value |
|---|---|
| Input data mode | `Define using fields below` |

**Workflow Input Fields** → Add field:

| Name | Type |
|---|---|
| `run_id` | `String` |

### Node 2 — `Mark Running` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Update` |
| Table | `provisioning_runs` |
| Column to match on | `id` |
| id | `{{ $json.run_id }}` |
| status | `running` |
| started_at | `{{ $now.toISO() }}` |

### Node 3 — `Load Pending Steps` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Execute Query` |
| Query | see below |

```sql
SELECT id AS step_id, step_order, action_type, resource, idempotency_key
FROM provisioning_steps
WHERE run_id = $1
  AND status IN ('pending', 'failed')
ORDER BY step_order ASC;
```

**Options** → **Add option** → **Query Parameters**, set it to the expression:

```
{{ $('When Executed by Another Workflow').first().json.run_id }}
```

> **Why `$1` and Query Parameters instead of pasting the value into the SQL.**
> String-concatenated SQL is injectable. Here the value is a UUID from your own
> database so the risk is low, but the habit is the point, and an interviewer
> will ask. If your n8n version labels this field "comma-separated list", the
> same expression still works: it is evaluated before being handed to the
> driver. For multiple parameters use an array expression such as
> `{{ [$json.a, $json.b] }}`, which maps to `$1` and `$2` in order.

### Node 4 — `Loop Steps` (Loop Over Items)

Search `Loop Over Items` (its internal name is Split In Batches).

| Parameter | Value |
|---|---|
| Batch Size | `1` |

**Options** → **Reset**: off. Leave it off. Turning it on restarts the loop
forever.

This node has two outputs: **done** (index 0, top) and **loop** (index 1,
bottom).

### Node 5 — from `loop` output — `Run Step` (Execute Sub-workflow)

Configure this after WF3 exists (§2.20).

| Parameter | Value |
|---|---|
| Source | `Database` |
| Workflow | `JML — Execute Step` |
| Workflow Inputs → step_id | `{{ $json.step_id }}` |
| Mode | `Run once with all items` |

**Options** → Wait For Sub-Workflow Completion: **on**.

### Node 6 — `Step OK?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $json.ok }}` |
| Operator | `Boolean` → `is true` |

- **true** output → connect back into **`Loop Steps`** (this continues the loop).
- **false** output → connect to `Trigger Rollback` (below). This is your break:
  the loop stops because nothing feeds it another batch.

### Node 7 — from `Step OK?` false — `Trigger Rollback` (Execute Sub-workflow)

Configure after WF4 exists (Stage 4). For now, leave a **NoOp** node here named
`Trigger Rollback` and replace it in Stage 4.

### Node 8 — from `Loop Steps` `done` output — `Mark Completed` (Postgres)

| Parameter | Value |
|---|---|
| Operation | `Update` |
| Table | `provisioning_runs` |
| Column to match on | `id` |
| id | `{{ $('When Executed by Another Workflow').first().json.run_id }}` |
| status | `completed` |
| finished_at | `{{ $now.toISO() }}` |

### Node 9 — `Audit: run_completed` (Postgres Insert into `audit_events`)

| Column | Value |
|---|---|
| run_id | `{{ $('When Executed by Another Workflow').first().json.run_id }}` |
| actor | `system` |
| event_type | `run_completed` |
| detail | `{{ JSON.stringify({ finished_at: $now.toISO() }) }}` |

---

## 2.20 WF3 — `JML — Execute Step`

New workflow named exactly `JML — Execute Step`. This is the workflow that
actually touches the outside world, and it is the only one that does.

### Node 1 — `When Executed by Another Workflow`

| Parameter | Value |
|---|---|
| Input data mode | `Define using fields below` |
| Workflow Input Fields | Name `step_id`, Type `String` |

### Node 2 — `Load Step Context` (Postgres, Execute Query)

```sql
SELECT s.id            AS step_id,
       s.run_id,
       s.step_order,
       s.action_type,
       s.resource,
       s.idempotency_key,
       s.attempts,
       e.work_email,
       e.employee_ref,
       e.full_name,
       e.department,
       e.role_code
FROM provisioning_steps s
JOIN provisioning_runs  r ON r.id = s.run_id
JOIN employees          e ON e.id = r.employee_id
WHERE s.id = $1;
```

**Options** → **Query Parameters**:
`{{ $('When Executed by Another Workflow').first().json.step_id }}`

### Node 3 — `Mark In Progress` (Postgres, Execute Query)

```sql
UPDATE provisioning_steps
SET status = 'in_progress',
    attempts = attempts + 1,
    started_at = COALESCE(started_at, now()),
    last_error = NULL
WHERE id = $1
RETURNING attempts;
```

**Query Parameters**: `{{ $('Load Step Context').first().json.step_id }}`

Arithmetic on an existing column (`attempts + 1`) is why this one is raw SQL
rather than the Update operation. Doing it as read-then-write in two nodes
would be a lost-update race.

### Node 4 — `Build Request` (Code)

| Mode | `Run Once for All Items` |

```javascript
// Turns one ledger row into one HTTP call plus the assertion that proves it
// worked. One node, one switch, instead of eight parallel HTTP branches.

const IDP_BASE = 'http://127.0.0.1:8100';

const s = $('Load Step Context').first().json;
const email = encodeURIComponent(s.work_email);
const res = encodeURIComponent(s.resource || '');

let method, path, body = {}, verify_kind, verify_value = s.resource || '';

switch (s.action_type) {
  case 'create_account':
    method = 'POST'; path = '/v1/users';
    body = {
      employee_ref: s.employee_ref, full_name: s.full_name,
      work_email: s.work_email, department: s.department, role_code: s.role_code,
    };
    verify_kind = 'account_exists'; verify_value = '';
    break;
  case 'add_group':
    method = 'POST'; path = `/v1/users/${email}/groups`;
    body = { group: s.resource };
    verify_kind = 'group_present';
    break;
  case 'assign_license':
    method = 'POST'; path = `/v1/users/${email}/licenses`;
    body = { sku: s.resource };
    verify_kind = 'license_present';
    break;
  case 'remove_group':
    method = 'DELETE'; path = `/v1/users/${email}/groups/${res}`;
    verify_kind = 'group_absent';
    break;
  case 'revoke_license':
    method = 'DELETE'; path = `/v1/users/${email}/licenses/${res}`;
    verify_kind = 'license_absent';
    break;
  case 'revoke_sessions':
    method = 'POST'; path = `/v1/users/${email}/sessions/revoke`;
    verify_kind = 'sessions_revoked'; verify_value = '';
    break;
  case 'suspend_account':
    method = 'POST'; path = `/v1/users/${email}/suspend`;
    verify_kind = 'status_equals'; verify_value = 'suspended';
    break;
  case 'delete_account':
    method = 'DELETE'; path = `/v1/users/${email}`;
    verify_kind = 'status_equals'; verify_value = 'deleted';
    break;
  default:
    throw new Error(`unknown action_type: ${s.action_type}`);
}

return [{
  json: {
    ...s,
    method,
    url: IDP_BASE + path,
    request_body: body,
    verify_url: `${IDP_BASE}/v1/users/${email}`,
    verify_kind,
    verify_value,
  },
}];
```

### Node 5 — `Call IdP` (HTTP Request)

| Parameter | Value |
|---|---|
| Method | `{{ $json.method }}` (click the gears on Method → Add Expression) |
| URL | `{{ $json.url }}` |
| Authentication | `Generic Credential Type` |
| Generic Auth Type | `Header Auth` |
| Credential | `Mock IdP Key` |
| Send Query Parameters | off |
| Send Headers | **on** |
| Specify Headers | `Using Fields Below` |
| Header: Name | `Idempotency-Key` |
| Header: Value | `{{ $json.idempotency_key }}` |
| Send Body | **on** |
| Body Content Type | `JSON` |
| Specify Body | `Using JSON` |
| JSON | `{{ JSON.stringify($json.request_body) }}` |

**Options** → add:

| Option | Sub-setting | Value |
|---|---|---|
| Response | Include Response Headers and Status | **on** |
| Response | Never Error | off |
| Timeout | | `15000` |

**Settings** tab:

| Setting | Value |
|---|---|
| Retry On Fail | **on** |
| Max Tries | `3` |
| Wait Between Tries (ms) | `2000` |
| On Error | `Continue (using error output)` |

`On Error: Continue (using error output)` gives this node a second, red output.
That is the failure path. The node no longer kills the workflow; it routes.

### Node 6 — from the **main** output — `Verify Effect` (HTTP Request)

| Parameter | Value |
|---|---|
| Method | `GET` |
| URL | `{{ $('Build Request').first().json.verify_url }}` |
| Authentication | `Generic Credential Type` → `Header Auth` → `Mock IdP Key` |
| Send Query Parameters / Headers / Body | all off |

**Options** → Response → Include Response Headers and Status **on**;
Response → **Never Error** **on**; Timeout `15000`.
**Settings** → Retry On Fail **on**, Max Tries `3`, Wait `2000`.

Never Error is on because a 404 here is information, not a crash.

### Node 7 — `Check Verification` (Code)

```javascript
// The write said it worked. This asks the IdP whether it actually did.
// A 2xx from a write endpoint is a claim; the read-back is the evidence.

const ctx  = $('Build Request').first().json;
const call = $('Call IdP').first().json;
const vr   = $input.first().json;

const httpOk = vr.statusCode === 200;
const user = vr.body || {};

let verified = false;
let reason = '';

if (!httpOk) {
  reason = `verification GET returned ${vr.statusCode}`;
} else {
  switch (ctx.verify_kind) {
    case 'account_exists':
      verified = Boolean(user.user_id);
      reason = verified ? '' : 'account not present after create';
      break;
    case 'group_present':
      verified = (user.groups || []).includes(ctx.verify_value);
      reason = verified ? '' : `group ${ctx.verify_value} not in ${JSON.stringify(user.groups)}`;
      break;
    case 'group_absent':
      verified = !(user.groups || []).includes(ctx.verify_value);
      reason = verified ? '' : `group ${ctx.verify_value} still present`;
      break;
    case 'license_present':
      verified = (user.licenses || []).includes(ctx.verify_value);
      reason = verified ? '' : `license ${ctx.verify_value} not in ${JSON.stringify(user.licenses)}`;
      break;
    case 'license_absent':
      verified = !(user.licenses || []).includes(ctx.verify_value);
      reason = verified ? '' : `license ${ctx.verify_value} still present`;
      break;
    case 'sessions_revoked':
      verified = Boolean(user.sessions_revoked_at);
      reason = verified ? '' : 'sessions_revoked_at is still null';
      break;
    case 'status_equals':
      verified = user.status === ctx.verify_value;
      reason = verified ? '' : `status is ${user.status}, expected ${ctx.verify_value}`;
      break;
    default:
      reason = `unknown verify_kind ${ctx.verify_kind}`;
  }
}

return [{
  json: {
    step_id: ctx.step_id,
    run_id: ctx.run_id,
    action_type: ctx.action_type,
    resource: ctx.resource,
    verified,
    reason,
    idempotent_replay: (call.headers || {})['x-idempotent-replay'] === 'true',
    idp_status_code: call.statusCode,
    response_payload: JSON.stringify(call.body ?? {}),
    request_payload: JSON.stringify(ctx.request_body ?? {}),
  },
}];
```

### Node 8 — `Verified?` (If)

| Setting | Value |
|---|---|
| Left Value | `{{ $json.verified }}` |
| Operator | `Boolean` → `is true` |

### Node 9 — true → `Mark Succeeded` (Postgres, Execute Query)

```sql
UPDATE provisioning_steps
SET status = 'succeeded',
    verified = true,
    finished_at = now(),
    request_payload = $2::jsonb,
    response_payload = $3::jsonb,
    last_error = NULL
WHERE id = $1;
```

**Query Parameters** (expression producing three values in order):

```
{{ [ $json.step_id, $json.request_payload, $json.response_payload ] }}
```

### Node 10 — `Audit: step_succeeded` (Postgres Insert into `audit_events`)

| Column | Value |
|---|---|
| run_id | `{{ $('Check Verification').first().json.run_id }}` |
| step_id | `{{ $('Check Verification').first().json.step_id }}` |
| actor | `system` |
| event_type | `step_succeeded` |
| detail | `{{ JSON.stringify({ action: $('Check Verification').first().json.action_type, resource: $('Check Verification').first().json.resource, idp_status_code: $('Check Verification').first().json.idp_status_code, idempotent_replay: $('Check Verification').first().json.idempotent_replay }) }}` |

### Node 11 — `Return OK` (Code)

```javascript
const c = $('Check Verification').first().json;
return [{ json: { ok: true, step_id: c.step_id, action_type: c.action_type,
                  resource: c.resource, error: null } }];
```

### The failure path

Two sources feed it: the **error output** of `Call IdP`, and the **false**
output of `Verified?`.

### Node 12 — `Collect Failure` (Code)

```javascript
// Reached from two places: the HTTP call errored, or it returned 2xx but the
// read-back proved nothing changed. Both are failures; the message says which.

const ctx = $('Build Request').first().json;
const raw = $input.first().json;

const message = raw.error
  ? `IdP call failed: ${raw.error.message || JSON.stringify(raw.error)}`
  : `verification failed: ${raw.reason || 'unknown'}`;

return [{
  json: {
    step_id: ctx.step_id,
    run_id: ctx.run_id,
    action_type: ctx.action_type,
    resource: ctx.resource,
    error: message.slice(0, 900),
  },
}];
```

### Node 13 — `Mark Failed` (Postgres, Execute Query)

```sql
UPDATE provisioning_steps
SET status = 'failed',
    verified = false,
    finished_at = now(),
    last_error = $2
WHERE id = $1;
```

**Query Parameters**: `{{ [ $json.step_id, $json.error ] }}`

### Node 14 — `Audit: step_failed` (Postgres Insert into `audit_events`)

| Column | Value |
|---|---|
| run_id | `{{ $('Collect Failure').first().json.run_id }}` |
| step_id | `{{ $('Collect Failure').first().json.step_id }}` |
| actor | `system` |
| event_type | `step_failed` |
| detail | `{{ JSON.stringify({ action: $('Collect Failure').first().json.action_type, resource: $('Collect Failure').first().json.resource, error: $('Collect Failure').first().json.error }) }}` |

### Node 15 — `Return Failed` (Code)

```javascript
const c = $('Collect Failure').first().json;
return [{ json: { ok: false, step_id: c.step_id, action_type: c.action_type,
                  resource: c.resource, error: c.error } }];
```

> **WF3 never throws.** Both paths end in a Code node returning `{ ok: … }`.
> A sub-workflow that throws aborts the caller's loop with no chance to run
> compensations. Failure is data here, not an exception.

Save. Now go back and finish §2.17 (`Execute Plan`) and §2.19 node 5
(`Run Step`), which can now select these workflows from the list.

---

## 2.21 Test Stage 2

Reset first, every time:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/admin/reset
```

```sql
TRUNCATE audit_events, provisioning_steps, provisioning_runs, employees RESTART IDENTITY CASCADE;
```

### Test A — routine onboarding, no approval

Activate `JML — Intake & Plan` (toggle top right), open its **Production URL**
from the form trigger node, and submit:

| Field | Value |
|---|---|
| Request Type | `onboard` |
| Employee Reference | `E-101` |
| Full Name | `Grace Hopper` |
| Department | `Support` |
| Role Code | `SUPPORT_AGENT` |
| Manager Email | `boss@demo-corp.test` |
| Effective Date | next Monday |
| Requested By | `hr@demo-corp.test` |

`SUPPORT_AGENT` has no privileged entitlements, so no approval.

**Expected:**

```sql
SELECT run_status, steps_total, steps_succeeded, steps_failed, steps_unverified
FROM v_run_summary;
```
→ `completed | 5 | 5 | 0 | 0`

```bash
curl.exe -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/v1/users/grace.hopper@demo-corp.test
```
→ groups `["all-staff","support"]`, licenses `["HELPDESK_SEAT","OFFICE_BASIC"]`.

### Test B — privileged onboarding, approval required

Submit with `E-102`, `Ada Lovelace`, `Engineering`, `ENG_SENIOR`.

**Expected:**
- The run stops at `Wait For Approval`. In n8n, **Executions** shows it as
  *Waiting*.
- `SELECT status, approval_reason FROM provisioning_runs;` → `awaiting_approval`.
- An email arrives with `[PRIVILEGED]` marked next to `repo-write` and
  `prod-readonly`.
- **No account exists in the IdP yet.** Check it. Nothing may be provisioned
  before approval.

Click **Approve**. The browser shows `Decision recorded: approved`.

**Expected within a few seconds:**
- The waiting execution resumes and finishes green.
- `v_run_summary` → `completed | 7 | 7 | 0 | 0`.
- The IdP user has `repo-write` and `prod-readonly`.

### Test C — rejection blocks everything

Submit `E-103`, `Alan Turing`, `Finance`, `FIN_ANALYST`. Click **Reject**.

**Expected:** run status `rejected`, `steps_succeeded` = 0, no IdP user at all.

### Test D — the approval link is single use

Click **Approve** again on the Test B email.

**Expected:** HTTP 410, `This approval link is invalid, already used, or
expired.` No second execution appears.

### Test E — duplicate submission is blocked

Resubmit Test A's form exactly.

**Expected:** the execution goes red on `Stop (Duplicate)` with
`Duplicate request blocked. Run … already exists with status completed`.
`SELECT count(*) FROM provisioning_runs;` is unchanged.

### Test F — offboarding revokes what actually exists

First, grant Grace something outside the system, simulating manual drift:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -H "Idempotency-Key: manual-1" -d "{\"group\":\"prod-admin\"}" http://127.0.0.1:8100/v1/users/grace.hopper@demo-corp.test/groups
```

Now submit an `offboard` request for `E-101`, `Grace Hopper`, `Support`,
`SUPPORT_AGENT`, effective date today.

**Expected:** the plan contains a `remove_group` for **`prod-admin`** even
though it was never in the policy table. Final IdP state: `groups: []`,
`licenses: []`, `status: "suspended"`, `sessions_revoked_at` set.

This test is the argument for reading current state instead of policy when
offboarding. It is worth its own paragraph in the README.

### Test G — verification catches a lying API

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"fail_action\",\"target_action\":\"assign_license\",\"remaining\":5}" http://127.0.0.1:8100/admin/chaos
```

Submit an onboard for `E-104`, `Katherine Johnson`, `Sales`, `SALES_REP`.

**Expected:** steps 10, 20, 21 succeed. Step 50 (`assign_license CRM_SEAT`)
retries 3 times, fails, is written to the ledger with `last_error`, and the
loop stops. Run status is still `running` because rollback does not exist yet.
That is Stage 4.

```sql
SELECT step_order, action_type, resource, status, attempts, last_error
FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

---

## Stage 2 checklist

- [ ] A routine role provisions 5 steps with no human involvement.
- [ ] A privileged role provisions **nothing** until the link is clicked.
- [ ] Rejecting leaves the IdP completely untouched.
- [ ] The approval link works exactly once.
- [ ] Resubmitting the same request is blocked by the ledger, not by luck.
- [ ] Offboarding revokes a group that policy never knew about.
- [ ] A failing step is recorded with its error and stops the loop.
- [ ] You can point at the four things that make this idempotent: the derived
      key, the UNIQUE constraint, the `Idempotency-Key` header, and the
      read-back verification.

### Common Stage 2 errors

| Symptom | Cause | Fix |
|---|---|---|
| `Build Plan` throws "No entitlements defined" | Department and role do not match a seeded pair | The seed pairs each role with one department; use the pairs in `seed_entitlements.sql` |
| `Insert Steps` writes 1 row, not N | `Expand Steps` returned one item containing an array | It must `return plan.steps.map(...)`, one item per step |
| Audit rows duplicated N times | Node runs once per incoming item | Settings tab → **Execute Once** → on |
| Approve link 404s | `JML — Approval Callback` is not activated | Toggle it Active; webhook production URLs only exist while active |
| Approve link works but the run never resumes | `resume_url` is null in the DB | `Build Plan` only sets it when `requires_approval` is true. Confirm the run needed approval. |
| `Run Step` sub-workflow errors kill the parent | WF3 threw instead of returning | Check `On Error: Continue (using error output)` is set on `Call IdP` |
| Loop runs forever | `Loop Over Items` → Options → Reset is on | Turn Reset off |
| `column "verified" is of type boolean but expression is of type text` | Expression wrapped in quotes | Use `{{ $json.verified }}`, not `"{{ $json.verified }}"` |

Next: `04-stage3-ai.md`.
