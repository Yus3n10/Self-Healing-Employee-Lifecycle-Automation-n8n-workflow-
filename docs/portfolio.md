# Portfolio assets

Everything here is scoped to what has actually been built and observed. Claims
about the failure suite, the AI intake, and production deployment are worded to
match reality. If you later run the full suite or build Stage 3, the notes at the
bottom say exactly which sentences get stronger.

---

## Demo video outline (3 minutes)

Lead with failure. Anyone can film a green workflow.

| Time | Content | Asset |
|---|---|---|
| 0:00–0:20 | The problem, spoken over the architecture diagram. "When someone joins, IT works a checklist across several consoles. When they leave, all of it has to come back off the same day. Done by hand, steps get skipped, and a skipped revocation is a security hole nobody notices until an audit." | `docs/screenshots/00-architecture.png` |
| 0:20–0:45 | Submit a routine onboarding. It completes with no human involved. Show the account in the IdP with its groups and licences. | screen recording |
| 0:45–1:20 | Submit a privileged onboarding. **Show that nothing is provisioned.** Open the approval email, point at the `[PRIVILEGED]` lines. Approve. Show it complete. | screen recording |
| 1:20–2:15 | Arm the fault. Submit. Narrate live: three steps go green, the fourth retries three times and fails, the loop breaks, rollback compensates in reverse. Show the IdP account deleted and the ledger explaining every transition. | **already recorded (F1)** |
| 2:15–2:35 | The control query returning zero rows: nothing privileged was ever provisioned without a recorded approval. | SQL screenshot |
| 2:35–3:00 | Close on the "Where AI is, and deliberately is not" section of the README. | README scroll |

Do not narrate node configuration. Nobody wants a tour of the canvas.

**What you already have:** the F1 rollback recording and the F2 duplicate
screenshot. That covers the most important 55 seconds.

**What is still needed:** the routine and privileged onboarding segments, the
control query screenshot, and the closing scroll. About 20 minutes of recording.

---

## Screenshot checklist

| # | Shot | Status |
|---|---|---|
| 1 | Architecture diagram | done |
| 2 | WF1 canvas, showing the branching | done |
| 3 | WF3 canvas with the red error-output branch visible | done |
| 4 | WF4 rollback canvas | done |
| 5 | Approval email with `[PRIVILEGED]` rows | **needed** |
| 6 | Executions list showing a run in *Waiting* state | **needed** |
| 7 | F1 execution graph: green, green, green, red, then rollback | **needed** |
| 8 | `provisioning_steps` after F1: mixed `compensated` / `failed` / `pending` | **needed** |
| 9 | Control query returning zero rows | **needed** |
| 10 | Access review drift email naming `prod-admin` | **needed** |

Shots 7, 8 and 9 are the three that carry the most weight and none of them need
a new test run: 7 and 8 can be cropped from the F1 recording, and 9 is one query
against data you already have.

---

## Resume bullets

Four bullets. Use two or three, not all four, unless this is the only project on
the page.

**1. Scope and architecture**

> Built an employee joiner/mover/leaver provisioning orchestrator as eight n8n
> workflows over PostgreSQL: each request derives an ordered plan from a policy
> table, privileged entitlements pause for human approval, and every step
> executes idempotently against an identity API and is verified by reading the
> target system back.

**2. Reliability engineering (the strongest one)**

> Designed the system around at-least-once delivery semantics: deterministic
> per-step idempotency keys, a UNIQUE-constrained request ledger that makes
> duplicate submissions impossible rather than unlikely, and a reverse-order
> compensating rollback that returns the target system to its prior state when a
> plan fails partway, distinguishing "cleaned up" from "could not clean up" and
> escalating only the second.

**3. Auditability and operations**

> Implemented an append-only audit trail, scheduled jobs for due offboardings and
> SLA breaches with two independent guards against repeating side effects, and a
> weekly entitlement drift review that reports rather than auto-remediates,
> including a control query proving no privileged access was granted without a
> recorded approval.

**4. Constrained AI in a security-relevant workflow**

> Added a single LLM feature that parses free-text HR emails into structured
> requests using an enum-constrained JSON schema, cross-field validation, and
> evidence grounding that requires the model to quote the source substring for
> every field it fills; its output becomes a pre-filled form a human submits
> rather than a database write, so an injected instruction to escalate
> privileges changes nothing about what gets provisioned.

### Wording to avoid

| Do not write | Because |
|---|---|
| "Validated by an 11-scenario failure suite" | The suite is specified, not executed |
| "AI-powered provisioning" | The LLM drafts a request; it provisions nothing |
| "Reduced onboarding time by X%" | Never ran in a company; there is no baseline |
| "Production-grade" / "production-ready" | It runs single-process against a simulator |
| "Integrated with Okta / Google Workspace" | The IdP is a simulator you wrote |

---

## Portfolio description (about 100 words)

> **JML Orchestrator** is an employee onboarding and offboarding system built as
> eight n8n workflows over PostgreSQL. A request becomes an ordered plan derived
> from a policy table, privileged grants pause for human approval, each step
> executes idempotently and is verified by reading the target system back, and
> any partial failure is compensated in reverse order so no half-provisioned
> account is left behind. It keeps an append-only audit trail, fires due
> offboardings on a schedule, and reviews entitlement drift weekly. No LLM is
> involved in any provisioning decision, which is a design choice the README
> explains. Runs against a simulated identity provider included in the repo.

## One-liner

> Employee provisioning orchestrator in n8n and PostgreSQL: policy-driven plans,
> human approval for privileged access, idempotent execution with read-back
> verification, and compensating rollback on partial failure.

---

## Interview answers to have ready

| Question | Answer |
|---|---|
| "Why n8n and not code?" | The value is integration and operability, not algorithms. n8n gives execution history, retries, and a durable waiting-execution model for free. The parts that had to be exact, plan construction, verification, and the compensation map, are Code nodes and SQL, version-controlled as JSON. |
| "Why so little AI?" | Provisioning is state-changing and security-relevant. A hallucinated group membership is a breach. The one place language is genuinely the problem is parsing a free-text request, and even there the output would be a draft a human submits. |
| "How do you know it works?" | Two control queries that must return zero rows, read-back verification on every write, and a failure runbook with expected behaviour written per scenario. Six of those behaviours were exercised repeatedly during development; the formal suite has not been run end to end yet, and the README says so. |
| "What breaks first at scale?" | Single n8n process. Queue mode with Redis and workers is the first change, then Postgres for n8n's own state instead of SQLite. |
| "What would you do differently?" | Add a second target system early. One target lets you fake the plan/execute separation without proving it. |
| "What was the hardest bug?" | A sweeper that threw on a missing account, which aborted the entire batch so every other due offboarding that hour silently did not happen. The fix was to emit a zero-step plan and audit the record instead of throwing. It taught me that batch jobs must isolate bad records. |

---

## What gets stronger later

| If you do this | These sentences change |
|---|---|
| Run F1 to F11 and record results | "Validated by an 11-scenario failure suite" becomes usable. Two README rows move from "not yet exercised" to "Observed". |
| Force the model to fabricate once | The evidence-grounding row moves from "not yet exercised" to "Observed". Temporarily delete the "copy values from the message" rule from the WF8 prompt, submit an email with no date, and confirm the check fires. |
| Add a second target system | The plan/execute separation stops being an assertion. |
| Put it behind a tunnel with SSO | The two largest Limitations entries disappear. |
