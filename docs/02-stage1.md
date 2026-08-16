# Stage 1 · The thin slice

**Goal:** a form submission creates an employee row in Postgres and a real
account in the mock IdP. No plan table, no approval, no AI, no rollback.

**Why start here:** every later stage adds risk. If the plumbing (form →
validation → database → authenticated HTTP call) is not already proven, you
will not be able to tell whether a Stage 4 failure is a rollback bug or a
credential typo.

**Time:** about 60 minutes.

---

## 1.1 Create the workflow

1. In n8n, click **Overview** in the left sidebar, then **Create Workflow**.
2. Click the workflow name at the top left (it says `My workflow`) and rename
   it to exactly: `JML — Intake & Plan`
3. Open **three-dot menu (top right) → Settings** and set:
   - Timezone: `Asia/Manila`
   - Save manual executions: **on**
   - Timeout Workflow: **on**, 1 hour
   - Leave Error Workflow empty for now; you create it in Stage 4.
4. Click **Save** (top right).

---

## 1.2 Node 1 — `On form submission`

Click the **+** on the canvas. Search `Form`. Choose **n8n Form Trigger**
(description: "Generate webforms in n8n and pass their responses to the
workflow").

Set these parameters:

| Parameter | Value |
|---|---|
| Authentication | `None` |
| Form Path | `jml-request` (replace the generated UUID with this exact text) |
| Form Title | `Employee Lifecycle Request` |
| Form Description | `Onboarding and offboarding requests. Demo system. Use synthetic data only.` |
| Respond When | `Form Is Submitted` |

Now add the form fields. Click **Add Form Field** ten times and fill each one
in. The **Field Label** strings must match exactly, including capitalisation,
because the Code node reads them by name.

| # | Field Label | Field Type | Required | Field Options / notes |
|---|---|---|---|---|
| 1 | `Request Type` | Dropdown | on | Options: `onboard`, `offboard` |
| 2 | `Employee Reference` | Text | on | Placeholder: `E-001` |
| 3 | `Full Name` | Text | on | Placeholder: `Ada Lovelace` |
| 4 | `Personal Email` | Email | off | Placeholder: `ada@example.test` |
| 5 | `Department` | Dropdown | on | Options: `Engineering`, `Sales`, `Finance`, `Support`, `IT` |
| 6 | `Role Code` | Dropdown | on | Options: `ENG_JUNIOR`, `ENG_SENIOR`, `SALES_REP`, `FIN_ANALYST`, `SUPPORT_AGENT`, `IT_ADMIN` |
| 7 | `Manager Email` | Email | on | Placeholder: `manager@demo-corp.test` |
| 8 | `Effective Date` | Date | on | Start date for onboard, last day for offboard |
| 9 | `Requested By` | Email | on | Placeholder: `hr@demo-corp.test` |
| 10 | `Notes` | Textarea | off | Free text, not used for any decision |

To add dropdown options: after setting Field Type to `Dropdown`, a **Field
Options** section appears. Click **Add Field Option** once per value and type
the option text into the **Option** box.

Finally, open **Options** at the bottom of the node and add:

| Option | Value |
|---|---|
| Form Submitted Text | `Request received. You will get an email if approval is needed.` |

Close the node.

> **Why `Respond When: Form Is Submitted`.** The form gets an HTTP 200 the
> instant it submits, before any work happens. Later this workflow will pause
> for hours waiting on a human approval. If the response waited for the workflow
> to finish, the browser would time out and the requester would resubmit,
> which is exactly how you get duplicate provisioning. Ack fast, process slow.

---

## 1.3 Node 2 — `Normalize Request` (Code)

Click the **+** to the right of the form trigger. Search `Code`. Choose
**Code**.

| Parameter | Value |
|---|---|
| Mode | `Run Once for All Items` |
| Language | `JavaScript` |

Rename the node (double-click its title) to exactly `Normalize Request`.

Paste this into the **JavaScript** box, replacing everything that is there:

```javascript
// Turns raw form output into the canonical shape every later node depends on,
// validates it, and computes the idempotency root: the value that makes a
// duplicate submission collide in the database instead of creating a second run.

const WORK_EMAIL_DOMAIN = 'demo-corp.test';

const VALID_ROLES = ['ENG_JUNIOR', 'ENG_SENIOR', 'SALES_REP',
                     'FIN_ANALYST', 'SUPPORT_AGENT', 'IT_ADMIN'];
const VALID_DEPTS = ['Engineering', 'Sales', 'Finance', 'Support', 'IT'];
const ROLE_DEPT = {
  ENG_JUNIOR: 'Engineering', ENG_SENIOR: 'Engineering',
  SALES_REP: 'Sales',        FIN_ANALYST: 'Finance',
  SUPPORT_AGENT: 'Support',  IT_ADMIN: 'IT',
};

const f = $input.first().json;
const s = (v) => String(v ?? '').trim();

const req = {
  request_type:   s(f['Request Type']).toLowerCase(),
  employee_ref:   s(f['Employee Reference']).toUpperCase(),
  full_name:      s(f['Full Name']),
  personal_email: s(f['Personal Email']).toLowerCase() || null,
  department:     s(f['Department']),
  role_code:      s(f['Role Code']).toUpperCase(),
  manager_email:  s(f['Manager Email']).toLowerCase(),
  effective_date: s(f['Effective Date']).slice(0, 10),
  requested_by:   s(f['Requested By']).toLowerCase(),
  notes:          s(f['Notes']),
};

// The work email is DERIVED here, never accepted from the form. A requester who
// could choose the target address could provision against someone else's account.
const parts = req.full_name
  .normalize('NFKD')
  .replace(/[^\w\s-]/g, '')
  .trim()
  .toLowerCase()
  .split(/\s+/)
  .filter(Boolean);
const local = parts.length >= 2 ? `${parts[0]}.${parts[parts.length - 1]}`
                                : (parts[0] || 'unknown');
req.work_email = `${local}@${WORK_EMAIL_DOMAIN}`;
// ponytail: no collision suffix. Two "Ada Lovelace"s would clash. Add a counter
// checked against the employees table if this ever meets real data.

const errors = [];
const emailRe = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const dateRe = /^\d{4}-\d{2}-\d{2}$/;

if (!['onboard', 'offboard'].includes(req.request_type)) {
  errors.push('request_type must be onboard or offboard');
}
if (!/^E-\d{3,}$/.test(req.employee_ref)) {
  errors.push('employee_ref must look like E-001');
}
if (req.full_name.length < 3) {
  errors.push('full_name is too short');
}
if (!VALID_ROLES.includes(req.role_code)) {
  errors.push(`role_code must be one of ${VALID_ROLES.join(', ')}`);
}
if (!VALID_DEPTS.includes(req.department)) {
  errors.push(`department must be one of ${VALID_DEPTS.join(', ')}`);
}
if (ROLE_DEPT[req.role_code] && ROLE_DEPT[req.role_code] !== req.department) {
  errors.push(`role ${req.role_code} belongs to ${ROLE_DEPT[req.role_code]}, not ${req.department}`);
}
if (!emailRe.test(req.manager_email))  errors.push('manager_email is not a valid email');
if (!emailRe.test(req.requested_by))   errors.push('requested_by is not a valid email');
if (req.personal_email && !emailRe.test(req.personal_email)) {
  errors.push('personal_email is not a valid email');
}
if (!dateRe.test(req.effective_date))  errors.push('effective_date must be YYYY-MM-DD');

// Same person + same request type + same date == the same request, forever.
req.idempotency_root = `${req.request_type}:${req.employee_ref}:${req.effective_date}`;
req.start_date  = req.request_type === 'onboard'  ? req.effective_date : null;
req.end_date    = req.request_type === 'offboard' ? req.effective_date : null;
req.valid       = errors.length === 0;
req.errors      = errors;
req.received_at = new Date().toISOString();

return [{ json: req }];
```

**Data in:** one item with the ten form labels as keys.
**Data out:** one item with 17 keys including `valid`, `errors`,
`work_email`, `idempotency_root`.

---

## 1.4 Node 3 — `Is Valid?` (If)

Add an **If** node. Rename it to `Is Valid?`.

In **Conditions**:

| Setting | Value |
|---|---|
| Left Value | click the gears icon → **Add Expression** → type `{{ $json.valid }}` |
| Data type / Operator | `Boolean` → `is true` |
| Combine Conditions | `AND` |

Open **Options** and set **Ignore Case** off, **Less Strict Type Validation**
off. Strict validation is what you want: a string `"true"` should not silently
pass a boolean check.

The If node has two outputs: **true** (top) and **false** (bottom).

---

## 1.5 Node 4 (false branch) — `Reject Invalid Request` (Stop and Error)

From the **false** output of `Is Valid?`, add a **Stop and Error** node. Rename
it `Reject Invalid Request`.

| Parameter | Value |
|---|---|
| Error Type | `Error Message` |
| Error Message | `={{ 'Rejected: ' + $json.errors.join('; ') }}` |

To enter an expression, hover the field, click the gears icon, choose
**Add Expression**, then paste `{{ 'Rejected: ' + $json.errors.join('; ') }}`.

---

## 1.6 Node 5 (true branch) — `Upsert Employee` (Postgres)

From the **true** output of `Is Valid?`, add a **Postgres** node. Rename it
`Upsert Employee`.

| Parameter | Value |
|---|---|
| Credential to connect with | `JML Postgres` |
| Operation | `Insert or Update` |
| Schema | `public` (From list) |
| Table | `employees` (From list) |
| Mapping Column Mode | `Map Each Column Manually` |
| Column to match on | `employee_ref` |

Now the column fields appear. Fill in exactly these, leaving every other
column blank:

| Column | Value (paste as an expression) |
|---|---|
| employee_ref | `{{ $json.employee_ref }}` |
| full_name | `{{ $json.full_name }}` |
| personal_email | `{{ $json.personal_email }}` |
| work_email | `{{ $json.work_email }}` |
| role_code | `{{ $json.role_code }}` |
| department | `{{ $json.department }}` |
| manager_email | `{{ $json.manager_email }}` |
| start_date | `{{ $json.start_date }}` |
| end_date | `{{ $json.end_date }}` |
| status | `{{ $json.request_type === 'onboard' ? 'pending' : 'offboarding' }}` |
| updated_at | `{{ $now.toISO() }}` |

Open **Options** and add:

| Option | Value |
|---|---|
| Output Columns | leave as all (do not set) |

**Data out:** one item containing the full employee row, including the
generated `id` (a UUID). You need that `id` in Stage 2.

> If `start_date` or `end_date` is `null` the Postgres node writes SQL NULL,
> which is what the `date` column wants. Do not wrap the expression in quotes.

---

## 1.7 Node 6 — `IdP: Create Account` (HTTP Request)

Add an **HTTP Request** node after `Upsert Employee`. Rename it
`IdP: Create Account`.

| Parameter | Value |
|---|---|
| Method | `POST` |
| URL | `http://127.0.0.1:8100/v1/users` |
| Authentication | `Generic Credential Type` |
| Generic Auth Type | `Header Auth` |
| Header Auth credential | `Mock IdP Key` |
| Send Query Parameters | off |
| Send Headers | **on** |
| Specify Headers | `Using Fields Below` |
| Send Body | **on** |
| Body Content Type | `JSON` |
| Specify Body | `Using Fields Below` |

**Header Parameters** — click **Add Parameter** once:

| Name | Value |
|---|---|
| `Idempotency-Key` | `{{ $('Normalize Request').item.json.idempotency_root }}:10:create_account:` |

**Body Parameters** — click **Add Parameter** five times:

| Name | Value |
|---|---|
| `employee_ref` | `{{ $('Normalize Request').item.json.employee_ref }}` |
| `full_name` | `{{ $('Normalize Request').item.json.full_name }}` |
| `work_email` | `{{ $('Normalize Request').item.json.work_email }}` |
| `department` | `{{ $('Normalize Request').item.json.department }}` |
| `role_code` | `{{ $('Normalize Request').item.json.role_code }}` |

Open **Options** and add these three:

| Option | Sub-setting | Value |
|---|---|---|
| Response | Include Response Headers and Status | **on** |
| Response | Never Error | **off** |
| Timeout | | `15000` |

Now open the node's **Settings** tab (next to Parameters, at the top of the
node panel) and set:

| Setting | Value |
|---|---|
| Always Output Data | off |
| Execute Once | off |
| Retry On Fail | **on** |
| Max Tries | `3` |
| Wait Between Tries (ms) | `2000` |
| On Error | `Stop Workflow` (you change this in Stage 4) |

**Data out** (because Include Response Headers and Status is on):

```json
{
  "body": { "user_id": "…", "work_email": "ada.lovelace@demo-corp.test", "status": "active", "groups": [], "licenses": [] },
  "headers": { "x-idempotent-replay": "…" },
  "statusCode": 201
}
```

Remember that shape. Downstream you read `$json.body.status`, not
`$json.status`.

> **Why the reference is `$('Normalize Request').item.json` and not `$json`.**
> After the Postgres node, `$json` is the *employee row*, not the normalized
> request. Referencing the source node by name is unambiguous and survives you
> inserting nodes in between later. Use this style everywhere.

> **Why the idempotency key looks like that.** `root:step_order:action:resource`.
> It is deterministic, so a replay of the same logical step reuses it and the
> IdP returns the original response instead of acting twice. Stage 2 generates
> these programmatically; here you hardcode step 10 because there is only one.

---

## 1.8 Node 7 — `Audit: account_created` (Postgres)

Add a **Postgres** node after the HTTP node. Rename it
`Audit: account_created`.

| Parameter | Value |
|---|---|
| Credential | `JML Postgres` |
| Operation | `Insert` |
| Schema | `public` |
| Table | `audit_events` |
| Mapping Column Mode | `Map Each Column Manually` |

| Column | Value |
|---|---|
| actor | `system` (plain text, no expression) |
| event_type | `account_created` |
| detail | `{{ JSON.stringify({ work_email: $('Normalize Request').item.json.work_email, idp_status_code: $json.statusCode, idempotent_replay: $json.headers['x-idempotent-replay'] === 'true', user_id: $json.body.user_id }) }}` |

Leave `run_id` and `step_id` blank; there is no run table entry yet in Stage 1.

---

## 1.9 Connect and save

Your canvas should read, left to right:

```
On form submission → Normalize Request → Is Valid? ─true→ Upsert Employee → IdP: Create Account → Audit: account_created
                                                  └false→ Reject Invalid Request
```

Click **Save**.

---

## 1.10 Test Stage 1

### Test A — the happy path

1. Confirm the mock IdP window is running and n8n is running.
2. In the `On form submission` node, copy the **Test URL** (there are two tabs,
   Test and Production; use **Test** for now).
3. Click **Execute workflow** in n8n. It now says "Waiting for trigger event".
4. Open the Test URL in a browser. Fill in:

   | Field | Value |
   |---|---|
   | Request Type | `onboard` |
   | Employee Reference | `E-001` |
   | Full Name | `Ada Lovelace` |
   | Personal Email | `ada@example.test` |
   | Department | `Engineering` |
   | Role Code | `ENG_SENIOR` |
   | Manager Email | `grace.hopper@demo-corp.test` |
   | Effective Date | any date next week |
   | Requested By | `hr@demo-corp.test` |
   | Notes | leave blank |

5. Submit.

**Expected in n8n:** all six nodes green. Click `IdP: Create Account` and check
the output panel shows `"statusCode": 201` and a `user_id`.

**Expected in the mock IdP:**

```bash
curl.exe -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/v1/users
```

You should see one user, `ada.lovelace@demo-corp.test`, status `active`.

**Expected in Neon** (SQL Editor):

```sql
SELECT employee_ref, full_name, work_email, status FROM employees;
SELECT event_type, detail FROM audit_events ORDER BY id DESC LIMIT 5;
```

One employee row, one audit row.

### Test B — validation actually rejects

Run the workflow again with **Role Code** `FIN_ANALYST` and **Department**
`Engineering`.

**Expected:** `Is Valid?` takes the false branch and the execution fails red on
`Reject Invalid Request` with the message
`Rejected: role FIN_ANALYST belongs to Finance, not Engineering`.
No new user appears in the mock IdP.

### Test C — idempotency actually works

Submit the **exact same form as Test A again**, same employee ref, same date.

**Expected:**
- The workflow succeeds again (it is not deduped yet; that is Stage 2).
- The mock IdP still has exactly **one** user.
- `IdP: Create Account` output header `x-idempotent-replay` is `"true"`.
- `SELECT count(*) FROM employees;` still returns 1, because the upsert matched
  on `employee_ref`.

This is the single most important test in the project. It proves that repeating
the operation does not repeat the side effect.

### Test D — the IdP being down is visible, not silent

Stop the uvicorn window (Ctrl+C). Submit the form with a new employee ref
`E-002`.

**Expected:** `IdP: Create Account` retries 3 times about 2 seconds apart, then
the execution goes red with `ECONNREFUSED`. The employee row **is** in Postgres
but no account exists in the IdP. That inconsistency is the exact problem Stage
4's rollback and verification exist to solve. Note it now so the fix has a
reason.

Restart uvicorn before continuing.

---

## Stage 1 checklist

- [ ] Test A: six green nodes, one IdP user, one employee row, one audit row.
- [ ] Test B: invalid role/department combination is rejected with a readable message.
- [ ] Test C: resubmitting produces `x-idempotent-replay: true` and still one user.
- [ ] Test D: IdP down produces a red execution after 3 retries, not a silent pass.
- [ ] You can explain out loud why the form responds before the work is done.

### Common Stage 1 errors

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` from the HTTP node | Header Auth credential `Name` field holds a label instead of `X-API-Key` | Edit the `Mock IdP Key` credential, set Name to exactly `X-API-Key` |
| `ECONNREFUSED 127.0.0.1:8100` | uvicorn not running, or started on a different port | Restart it with the command in `01-setup.md` §0.4 |
| `Cannot read properties of undefined (reading 'json')` in the Code node | A form Field Label does not match the string in the code | Compare the label character by character; `Full Name` not `Full name` |
| Postgres node: `null value in column "manager_email"` | The expression references `$json.manager_email` after another node changed `$json` | Use `$('Normalize Request').item.json.manager_email` |
| `detail` column rejects the value | `JSON.stringify` was omitted, so an object was sent | The `detail` expression must produce a JSON **string** |
| Form shows "This webhook is not registered" | You used the Test URL without clicking Execute workflow first | Click **Execute workflow**, then open the URL. Or activate the workflow and use the Production URL. |

Next: `03-stage2.md`.
