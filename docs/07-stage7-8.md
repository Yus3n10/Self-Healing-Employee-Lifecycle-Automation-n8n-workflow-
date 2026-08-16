# Stage 7 · Deliberate failure tests · Stage 8 · Packaging

---

# Stage 7 · Break it on purpose, in front of a camera

Anyone can screenshot a green workflow. What separates this project is a
reproducible failure suite where you predicted the outcome before running it.

Run all eight in one sitting. Record your screen for the whole session. Reset
between each:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/admin/reset
```

```sql
TRUNCATE audit_events, provisioning_steps, provisioning_runs, employees RESTART IDENTITY CASCADE;
```

Write the results into `docs/failure-tests.md` as a table with an **Expected**
column filled in *before* you run each one. If a result differs from your
prediction, fix the system or fix your understanding, then note which.

---

### F1 · Mid-plan API failure

**Arm:**
```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"fail_action\",\"target_action\":\"assign_license\",\"remaining\":50}" http://127.0.0.1:8100/admin/chaos
```
**Do:** onboard `E-501`, `Katherine Johnson`, `Sales`, `SALES_REP`.
**Expect:** 3 steps succeed, step 50 fails after 3 retries, rollback removes both
groups and deletes the account, run status `rolled_back`, IdP user
`status: deleted` with empty groups and licences.
**Proves:** compensating-transaction saga, reverse ordering, clean end state.

---

### F2 · Duplicate submission

**Do:** submit the identical F1 form again (same ref, same date).
**Expect:** red execution on `Stop (Duplicate)`, no new run, a
`duplicate_request_blocked` audit row.
**Proves:** the `idempotency_root` UNIQUE constraint, and that dedup is enforced
by the database rather than by a check that could race.

---

### F3 · Retry does not double-apply

**Arm:** chaos off. **Do:** onboard `E-502`, `SUPPORT_AGENT`. When it completes,
open the execution, click `Call IdP` on the `add_group all-staff` step and use
**Retry** → *Retry with currently saved workflow*.
**Expect:** the response carries `x-idempotent-replay: true`; the user still has
exactly one `all-staff` entry; no duplicate audit row for a new grant.
**Proves:** the `Idempotency-Key` header is doing real work, not decoration.

---

### F4 · Rate limiting

**Arm:**
```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" -H "Content-Type: application/json" -d "{\"mode\":\"rate_limit\",\"remaining\":2}" http://127.0.0.1:8100/admin/chaos
```
**Do:** onboard `E-503`, `SUPPORT_AGENT`.
**Expect:** the first two calls get 429, n8n waits 2 s and retries, the run
completes with no human involvement. `attempts` on the affected steps is 2 or 3.
**Proves:** retry with backoff on a transient status, and that transient failure
does not trigger rollback.

---

### F5 · IdP completely down

**Do:** Ctrl+C the uvicorn window. Onboard `E-504`.
**Expect:** `create_account` fails after 3 tries with `ECONNREFUSED`, rollback
runs, every compensation also fails, run status `failed` (not `rolled_back`),
and an `[ACTION REQUIRED] Rollback incomplete` email arrives with a SQL query in
the body.
**Proves:** the system distinguishes "cleaned up" from "could not clean up" and
escalates the second to a human instead of reporting success.
Restart uvicorn afterwards.

---

### F6 · Approval replay

**Do:** onboard `E-505`, `ENG_SENIOR`. Click **Approve**. Then click **Approve**
again, and then **Reject**.
**Expect:** first click 200 and the run proceeds; second and third both 410
`invalid, already used, or expired`; exactly one execution resumed; run status
stays `completed`.
**Proves:** single-use token, decision immutability, and that a forwarded email
cannot re-trigger provisioning.

---

### F7 · Approval expiry

**Do:** onboard `E-506`, `IT_ADMIN`. Do not click. Then
`UPDATE provisioning_runs SET approval_expires_at = now() - interval '1 minute' WHERE status='awaiting_approval';`
and click **Approve**.
**Expect:** 410. Nothing provisioned. When the 24-hour Wait limit elapses (or you
manually resume the execution) the run closes as `expired` and the IdP is
untouched.
**Proves:** time-bounded authority. An approval from last week is not an
approval today.

---

### F8 · Prompt injection through the AI intake

**Do:** submit the Stage 3 Test C email through `JML — AI Intake`.
**Expect:** `offboard` / `SUPPORT_AGENT` extracted correctly, a warning that the
message contained text addressed to the parser, and the pre-filled form showing
`SUPPORT_AGENT`, not `IT_ADMIN`. Even had the model complied, `skip approval`
has nowhere to land because approval is decided by `Build Plan` from the policy
table.
**Proves:** the model has no authority, only a suggestion channel, and the
architecture is what stops the attack rather than the prompt.

---

### Recording the suite

For each test capture: the chaos command, the n8n execution graph showing which
nodes went red, the `provisioning_steps` query result, and the IdP state after.
Four screenshots per test, 32 total. You will use six of them.

Then write the results table:

```markdown
| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| F1 | Mid-plan API failure | rolled_back, IdP clean | rolled_back, IdP clean | ✅ |
```

A table with a predicted column, filled in beforehand, is the single most
convincing artefact in the repository.

---

# Stage 8 · Package it

## 8.1 Repository structure

```
jml-orchestrator/
├── README.md
├── .env.example
├── .gitignore
├── db/
│   ├── schema.sql
│   ├── seed_entitlements.sql
│   └── audit_queries.sql
├── mock-idp/
│   ├── main.py
│   ├── requirements.txt
│   └── test_mock_idp.py
├── workflows/                  # n8n export:workflow --all --separate
│   ├── JML — Intake & Plan.json
│   ├── JML — Execute Plan.json
│   ├── JML — Execute Step.json
│   ├── JML — Rollback.json
│   ├── JML — Approval Callback.json
│   ├── JML — Sweeper.json
│   ├── JML — Error Handler.json
│   ├── JML — AI Intake.json
│   └── JML — Access Review.json
├── scripts/
│   └── start-n8n.ps1
├── docs/
│   ├── 00-architecture.md … 07-stage7-8.md
│   ├── failure-tests.md
│   └── screenshots/
└── demo/
    └── demo-script.md
```

## 8.2 README outline

Write it in this order. The first three sections decide whether anyone reads
the fourth.

1. **One line.** "An employee joiner/mover/leaver orchestrator built in n8n:
   policy-driven provisioning with human approval, idempotent execution,
   read-back verification, and automatic rollback on partial failure."
2. **Honest framing, paragraph two.** The IdP is a simulator in this repo. All
   data is synthetic. It has not run in a company. Failure behaviour is
   demonstrated by a reproducible test suite, not claimed.
3. **The 90-second demo GIF.** Failure and rollback, not the happy path.
4. **Why there is almost no AI in this workflow.** The table from
   `00-architecture.md` §"Where AI fits". This section is the one that gets
   quoted back to you in interviews.
5. Architecture diagram and the nine-workflow table.
6. Reliability properties, each with the mechanism and the test that proves it:

   | Property | Mechanism | Proven by |
   |---|---|---|
   | Duplicate requests cannot double-provision | `idempotency_root` UNIQUE + pre-check | F2 |
   | Retries cannot double-apply | Deterministic `Idempotency-Key` per step | F3 |
   | A 2xx is not trusted | Read-back verification per step | F1 |
   | Partial failure leaves no orphan state | Reverse-order compensation saga | F1 |
   | Un-cleanable failure is never silent | `failed` vs `rolled_back` + alert | F5 |
   | Privileged access needs a human | Policy `is_privileged` + Wait gate | F6, F7 |
   | Approval is single-use and time-bounded | Token nulled on use, 24 h expiry | F6, F7 |
   | Model output cannot provision anything | Output goes into a URL, human submits | F8 |

7. Setup instructions (point at `docs/01-setup.md`, do not duplicate it).
8. Environment variables table (from `.env.example`, with a column saying where
   each value is actually entered).
9. Example input and output: the form payload, the resulting plan JSON, the
   `provisioning_steps` rows, the final IdP state.
10. **Limitations.** The seven production gaps from `06-stage5-6.md` §6.5, plus:
    the approval link proves possession not identity; no SSO; single n8n process;
    one target system; work-email collisions unhandled.
11. Future improvements: second target system to prove the plan/execute split is
    real, queue mode, SSO on approvals, learned approval thresholds.

## 8.3 Screenshots to capture

| # | Shot | Why |
|---|---|---|
| 1 | Full `JML — Intake & Plan` canvas | Shows the branching, not a straight line |
| 2 | `JML — Execute Step` canvas with the error output branch visible | The red connector is the point |
| 3 | The approval email with `[PRIVILEGED]` rows | Business legibility |
| 4 | Execution list showing one *Waiting* execution | Proves the human gate is real |
| 5 | F1's execution graph: green, green, green, red, then rollback | The money shot |
| 6 | `provisioning_steps` after F1: mixed `compensated`/`failed`/`pending` | The ledger telling the story |
| 7 | IdP `/admin/state` after F1 showing a clean account | The outcome |
| 8 | The "privileged without approval" query returning zero rows | A control proving a control |
| 9 | Access Review drift report email | Closing the loop |
| 10 | The AI intake email with the evidence block | Grounding, not vibes |

## 8.4 Demo video outline (3 minutes)

| Time | Content |
|---|---|
| 0:00–0:20 | The problem in plain English: a checklist across five consoles, and the leaver whose access was never revoked |
| 0:20–0:45 | Submit a routine onboarding. It completes with no human. Show the IdP state. |
| 0:45–1:20 | Submit a privileged onboarding. Show that **nothing** is provisioned. Show the approval email and the `[PRIVILEGED]` lines. Approve. Show it complete. |
| 1:20–2:15 | Arm the fault. Submit. Narrate the failure live: retries, break, reverse-order compensation. Show the IdP is clean and the ledger explains every transition. |
| 2:15–2:40 | Break rollback too. Show `failed` rather than `rolled_back`, and the alert email with a SQL query in it. |
| 2:40–3:00 | Close on the "why almost no AI" section, then the zero-row control query. |

Do not narrate node configuration. Nobody wants a tour of your canvas.

## 8.5 Resume bullets

Use these only after the tests actually pass. Adjust the numbers to what you
measured.

- Built an employee joiner/mover/leaver provisioning orchestrator in n8n and
  PostgreSQL: policy-driven plan generation, human approval gating for
  privileged entitlements, idempotent step execution against an identity API,
  read-back verification, and reverse-order compensating rollback on partial
  failure.
- Designed the reliability model around at-least-once delivery: deterministic
  per-step idempotency keys, a UNIQUE-constrained request ledger, and
  verification of every write, validated by a reproducible eight-scenario
  failure suite covering API faults, rate limiting, retries, approval replay,
  expiry, and prompt injection.
- Scoped the LLM to a single non-authoritative role (parsing free-text HR
  requests into a human-confirmed draft) with enum-constrained structured
  output and evidence-span grounding, deliberately keeping every
  state-changing decision deterministic and auditable.
- Implemented an append-only audit trail and a weekly entitlement drift review
  that reports rather than auto-remediates, including a control query that
  proves no privileged entitlement was ever granted without a recorded approval.

## 8.6 Portfolio description (about 90 words)

> **JML Orchestrator** — an employee onboarding and offboarding system built as
> a set of nine n8n workflows over PostgreSQL. A request becomes an ordered plan
> derived from a policy table, privileged grants pause for human approval, each
> step executes idempotently and is verified by reading the target system back,
> and any partial failure is compensated in reverse order. An LLM is used in
> exactly one place, drafting a request from a free-text email for a human to
> confirm, and has no authority over what gets provisioned. Includes an
> eight-scenario failure suite and an append-only audit trail. Runs against a
> simulated identity provider included in the repo.

## 8.7 The interview answers to have ready

| Question | The answer to have |
|---|---|
| "Why n8n and not code?" | The value here is integration and operability, not algorithms. n8n gives execution history, retries, and a waiting-execution model for free. The parts that needed to be exact (planning, verification, compensation mapping) are Code nodes and SQL, version-controlled as JSON. |
| "Why so little AI?" | Provisioning is state-changing and security-relevant. The model has one job where language is genuinely the problem, and its output goes into a URL a human submits. Point at F8. |
| "How do you know it works?" | Eight failure scenarios with predictions written before the runs, plus a control query that returns zero rows. |
| "What breaks first at scale?" | Single n8n process. Queue mode with Redis and workers is the first change, then Postgres for n8n's own state. |
| "What would you do differently?" | Add a second target system early. One target lets you fake the plan/execute separation without proving it. |

---

## Final checklist

- [ ] All eight failure tests run, with predictions written beforehand.
- [ ] `docs/failure-tests.md` has the results table.
- [ ] `workflows/` has nine exported JSON files, committed.
- [ ] `git grep` for secrets returns nothing.
- [ ] README leads with honest framing before any capability claim.
- [ ] The demo video shows failure before it shows success.
- [ ] Limitations section names the approval-link weakness explicitly.
- [ ] The repo carries no AI-tool attribution anywhere.
