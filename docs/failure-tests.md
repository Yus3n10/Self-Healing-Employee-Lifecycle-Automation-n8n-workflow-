# Failure test suite

Ten deliberate failure scenarios. Each one exists because a specific reliability
claim in the README needs evidence behind it.

The **Expected** column below is the *specified* behaviour, written from the
design before the suite was run. It is not a claim of blind prediction: six of
these scenarios were exercised during development, and their expected values are
documented from those runs. The four marked **cold** were specified from the
design and had never been executed when this table was written.

What the table demonstrates is that the system's behaviour under failure was
decided deliberately and then verified, rather than discovered afterwards and
described as intentional.

| Scenario | Status when specified |
|---|---|
| F1, F2, F6, F8, F9, F10 | Observed during development |
| F3, F4, F5, F7, F11 | **Cold** — specified from design, not yet run |

## Before every scenario

Load the helpers once per PowerShell session:

```bash
cd "D:\Claude Local\jml-orchestrator"; . .\scripts\idp.ps1
```

Reset both stores between scenarios:

```bash
Reset-Idp; Set-Chaos off
```

```sql
TRUNCATE audit_events, provisioning_steps, provisioning_runs, employees RESTART IDENTITY CASCADE;
```

Wake Neon with any query before starting n8n, or workflow activation fails
silently and every webhook returns 404. See the README's operational notes.

---

## Results

| # | Scenario | Claim it evidences | Expected | Actual | Pass |
|---|---|---|---|---|---|
| F1 | Mid-plan API failure | Partial failure leaves no orphan state | Steps 10, 20, 21 succeed then end `compensated`. Step 50 ends `failed` with `attempts` 3. Step 51 stays `pending`. Run status `rolled_back`. IdP account `status: deleted`, `groups: []`, `licenses: []`. | | |
| F2 | Duplicate form submission | Duplicate requests cannot double-provision | Execution ends red at `Stop (Duplicate)` with a message naming the existing run id and status. One `duplicate_request_blocked` audit row. `provisioning_runs` count unchanged. No IdP calls made. | | |
| F3 | Manual retry of a succeeded step | Retries cannot double-apply | Retry succeeds. `Call IdP` response header `x-idempotent-replay: true`. `all-staff` appears exactly once in the account's groups. Step stays `succeeded` with `verified` true. | | |
| F4 | Rate limiting (429 + Retry-After) | Transient failure is retried, not rolled back | **Cold.** First two calls return 429. n8n waits ~2s and retries. Run completes with status `completed`, all steps `succeeded`. Affected steps show `attempts` 2 or 3. Rollback never triggers: a transient status is not a failure. | | |
| F5 | IdP unreachable from the first call | Failure before any side effect needs no compensation | **Cold.** `create_account` fails after 3 attempts with `ECONNREFUSED`, step `failed`. No step ever succeeded, so rollback finds nothing to compensate and reports clean. Run status `rolled_back`, `compensation_failed` 0. **No escalation email.** An `employees` row exists with no IdP account, which is a real orphan and is discussed in the notes. | | |
| F6 | Approval link clicked three times | Approval is single-use | Click 1 returns 200 `Decision recorded: approved` and the paused execution resumes. Clicks 2 and 3 return 410. Exactly one resumed execution. Run stays `approved`, `approval_token` null, `approved_at` unchanged by later clicks. | | |
| F7 | Approval link used after expiry | Approval is time-bounded | **Cold.** Click returns 410. Nothing provisioned; `Get-IdpUsers` count unchanged. Run remains `awaiting_approval` until the 24h Wait limit elapses, then closes as `expired`. | | |
| F8 | Sweeper run four times | Scheduled jobs cannot repeat side effects | Exactly one `offboard` run exists after four executions. Account `status: suspended`, `groups: []`, `licenses: []`, `sessions_revoked_at` set. `employees.status` = `offboarded`. Runs 2 to 4 create nothing and error nothing. | | |
| F9 | Two due employees with no IdP account | One bad record cannot abort a batch | Single sweeper execution, green, no red node. Two `offboard_no_account` audit rows, one per employee. Both employees end `offboarded`. Neither aborts the other. | | |
| F10 | Offboard an unknown employee | Offboarding cannot invent an employee | Execution ends red at `Unknown Employee` with `Cannot offboard E-999: no such employee...`. Zero rows in `employees` for E-999. No run, no steps, no IdP calls. | | |
| F11 | IdP killed *during* rollback | Un-cleanable failure is never silent | **Cold.** Some steps succeed, one fails, rollback begins and its compensations fail. Run status `failed`, **not** `rolled_back`. Some steps end `compensation_failed`. An `[ACTION REQUIRED] Rollback incomplete` email arrives containing a runnable SQL query. Entitlements remain granted in the IdP. | | |

Deferred: prompt injection through the AI intake, once Stage 3 is built.

### Correction to an earlier assumption

I originally specified F5 as producing run status `failed` plus an escalation
email. Tracing the rollback path showed that is wrong. When the IdP is
unreachable from the very first call, no step ever reaches `succeeded`, so
`Load Succeeded Steps` returns nothing, there is nothing to compensate, and the
verdict is correctly `rolled_back` with zero compensation failures. The
escalation path requires compensations to *attempt and fail*, which is why F11
exists as a separate scenario.

---

## F1 · Mid-plan API failure

**Arm**

```bash
Set-Chaos fail_action assign_license 50
```

**Act** — submit an onboard for `E-501`, `Katherine Johnson`, `Sales`,
`SALES_REP`.

**Observe**

```sql
SELECT step_order, action_type, resource, status FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

```sql
SELECT status FROM provisioning_runs ORDER BY created_at DESC LIMIT 1;
```

```bash
Get-IdpUser katherine.johnson@demo-corp.test
```

**Clear**: `Set-Chaos off`

**Capture**: the execution graph showing three green steps, one red, then
rollback; the step ledger; the final IdP state.

---

## F2 · Duplicate form submission

**Act** — resubmit F1's form unchanged: same reference, same effective date.

**Observe**

```sql
SELECT event_type, detail FROM audit_events WHERE event_type = 'duplicate_request_blocked';
```

```sql
SELECT count(*) FROM provisioning_runs;
```

---

## F3 · Retry does not double-apply

**Act** — onboard `E-502`, `SUPPORT_AGENT`, let it complete. Open the
`JML — Execute Step` execution for the `add_group all-staff` step, and use
**Retry** → *Retry with currently saved workflow*.

**Observe** — the `Call IdP` response headers, and:

```bash
Get-IdpUser (the work email)
```

Look at whether `all-staff` appears once or twice, and whether the response
carried `x-idempotent-replay`.

---

## F4 · Rate limiting

**Arm**

```bash
Set-Chaos -Mode rate_limit -Remaining 2
```

**Act** — onboard `E-503`, `SUPPORT_AGENT`.

**Observe**

```sql
SELECT step_order, action_type, status, attempts FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

The question this answers: does a transient 429 trigger rollback, or is it
absorbed by the retry policy?

---

## F5 · IdP unreachable from the first call

**Act** — stop the uvicorn window (Ctrl+C). Onboard `E-504`.

**Observe** — the run's terminal status, the step statuses, and your inbox.

```sql
SELECT status FROM provisioning_runs ORDER BY created_at DESC LIMIT 1;
```

```sql
SELECT step_order, status, last_error FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

Restart uvicorn afterwards.

**Capture**: the escalation email, because it is the artefact that proves the
system distinguishes "cleaned up" from "could not clean up".

---

## F6 · Approval replay

**Act** — onboard `E-505`, `ENG_SENIOR`. Click **Approve**. Then click
**Approve** again, then **Reject**.

**Observe** — the HTTP status of clicks two and three, the number of resumed
executions, and:

```sql
SELECT status, decision, approved_at, approval_token FROM provisioning_runs
ORDER BY created_at DESC LIMIT 1;
```

---

## F7 · Approval expiry

**Act** — onboard `E-506`, `IT_ADMIN`. Do not click. Then:

```sql
UPDATE provisioning_runs SET approval_expires_at = now() - interval '1 minute'
WHERE status = 'awaiting_approval';
```

Now click **Approve**.

**Observe** — the response, and whether anything was provisioned.

```bash
Get-IdpUsers
```

---

## F8 · Scheduler idempotency

**Act** — onboard `E-601`, `SUPPORT_AGENT`, let it complete. Then:

```sql
UPDATE employees SET end_date = current_date WHERE employee_ref = 'E-601';
```

Execute `JML — Sweeper` **four times**.

**Observe**

```sql
SELECT count(*) FROM provisioning_runs WHERE run_type = 'offboard';
```

```bash
Get-IdpUser grace.hopper@demo-corp.test
```

---

## F9 · Batch isolation

**Act** — insert two employees who are due to leave and have no IdP account:

```sql
INSERT INTO employees
  (employee_ref, full_name, work_email, role_code, department, manager_email, end_date, status)
VALUES
  ('E-801','Ghost One','ghost.one@demo-corp.test','SUPPORT_AGENT','Support','boss@demo-corp.test', current_date,'active'),
  ('E-802','Ghost Two','ghost.two@demo-corp.test','SALES_REP','Sales','boss@demo-corp.test', current_date,'active');
```

Execute `JML — Sweeper` once.

**Observe**

```sql
SELECT event_type, detail FROM audit_events WHERE event_type = 'offboard_no_account';
```

```sql
SELECT employee_ref, status FROM employees WHERE employee_ref IN ('E-801','E-802');
```

The question: does one missing account abort the batch, or are both handled in
a single pass?

---

## F10 · Offboard an unknown employee

**Act** — submit an **offboard** for `E-999`, `Nobody Here`, `Support`,
`SUPPORT_AGENT`.

**Observe** — which node stops the run and what message it gives, and:

```sql
SELECT count(*) FROM employees WHERE employee_ref = 'E-999';
```

---

## F11 · IdP killed during rollback

The only scenario needing manual timing. It may take two attempts to land, which
is fine; note that in the results.

**Arm**

```bash
Set-Chaos fail_action assign_license 50
```

**Act**

1. Submit an onboard for `E-511`, `Katherine Johnson`, `Sales`, `SALES_REP`.
2. Watch the `JML — Execute Plan` execution. Steps 10, 20 and 21 go green.
3. The moment step 50 turns red and begins retrying, switch to the mock IdP
   window and press **Ctrl+C**.
4. Rollback starts and every compensation call fails against a dead server.

**Observe**

```sql
SELECT status FROM provisioning_runs ORDER BY created_at DESC LIMIT 1;
```

```sql
SELECT step_order, action_type, resource, status, last_error
FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

Check your inbox for `[ACTION REQUIRED] Rollback incomplete`.

**Restart the IdP afterwards**, then confirm the entitlements really are still
granted, which is the point:

```bash
Get-IdpUser katherine.johnson@demo-corp.test
```

They will not be, because the IdP holds state in memory and restarting clears
it. Note that limitation in the results: the *ledger* correctly records
`compensation_failed`, which is the durable evidence a human would act on.

**Capture**: the escalation email. It is the artefact proving the system knows
the difference between "cleaned up" and "could not clean up".

---

## When a result differs from the specification

Do not quietly edit the Expected column. Either the implementation diverged from
the specification, or the specification was wrong. Record which, in one line,
under the table:

> F4: specified `attempts` 2 or 3; observed 2. Specification was imprecise, not
> the implementation. Retry count depends on which call in the step sequence
> absorbs the 429.

A divergence recorded honestly is worth more to a reviewer than eleven green
ticks, because it shows the table reports rather than decorates.

---

## Evidence to keep

For each scenario, four artefacts in `docs/screenshots/`:

1. The arming command
2. The n8n execution graph, showing which nodes went red
3. The `provisioning_steps` result afterwards
4. The IdP state afterwards

You will use about six of the forty in the README and demo video. The rest
exist so the suite is reproducible by someone else.
