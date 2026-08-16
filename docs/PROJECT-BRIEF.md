# Project brief: JML Orchestrator

**Purpose of this file.** A single accurate source of facts about this project,
for anyone writing about it: a portfolio entry, a CV bullet, a summary, or an
interview answer. Written 2026-08-16, immediately after the project was finished.

The **Claim boundaries** section is the important one. It lists the specific
sentences that would be false, so nobody has to guess where the line is.

---

## Canonical facts

| Field | Value |
|---|---|
| Project name | **JML Orchestrator** (JML = Joiner, Mover, Leaver, the standard IT identity-lifecycle term) |
| Repo name | `Self-Healing-Employee-Lifecycle-Automation-n8n-workflow-` |
| URL | https://github.com/Yus3n10/Self-Healing-Employee-Lifecycle-Automation-n8n-workflow- |
| Visibility | Public |
| Built | 2026-08-14 to 2026-08-16 (three days) |
| Status | Complete and pushed. Not deployed anywhere; runs locally. |
| Scale | 9 n8n workflows, 5 Postgres tables + 1 view, ~52 files |

---

## What it is, in one paragraph

An employee onboarding and offboarding provisioning system. A request enters
through a web form, gets validated and deduplicated, and becomes an **ordered
plan derived from a policy table**. Steps that grant privileged access pause for
human approval. Each step then executes **idempotently** against an identity API
and is **verified by reading the target system back**. If any step fails partway,
every step that already succeeded is **compensated in reverse order**, so no
half-provisioned account is left behind. Scheduled jobs fire due offboardings and
review entitlement drift weekly. Everything is recorded in an append-only audit
trail.

## The problem it solves

When someone joins, IT works a checklist across several admin consoles. When
someone leaves, all of it has to come back off the same day. Done by hand, steps
get skipped, and a skipped revocation is a security hole nobody notices until an
audit.

**The hard part is not calling the APIs. It is that the APIs fail halfway.** A
half-provisioned account is worse than none, because nobody knows it exists.

---

## Tech stack

| Layer | What |
|---|---|
| Orchestration | n8n 2.34.5, self-hosted via npm |
| Logic | JavaScript in n8n Code nodes |
| Database | PostgreSQL 17 on Neon (serverless free tier) |
| Target system | FastAPI + Uvicorn + Pydantic on Python 3.11 (a simulator written for the project) |
| AI | Google Gemini Flash via n8n's Basic LLM Chain, Structured Output Parser, Auto-fixing Output Parser |
| Notifications | SMTP (Gmail app password) |
| Tooling | PowerShell 5.1, Git, Mermaid |

Everything runs on a free tier or locally.

## The nine workflows

WF1 Intake & Plan · WF2 Execute Plan · WF3 Execute Step · WF4 Rollback ·
WF5 Approval Callback · WF6 Sweeper (hourly) · WF7 Error Handler ·
WF8 AI Intake · WF9 Access Review (weekly)

---

## What it actually demonstrates

Ordered roughly by how much weight each carries with an engineer.

1. **Compensating-transaction saga.** A failed run walks its own ledger backwards
   and undoes what it did. Verified by injecting a fault into the identity API.
2. **Idempotency at two layers.** Deterministic per-step `Idempotency-Key` headers
   plus a UNIQUE-constrained request ledger, so duplicates are *impossible*
   rather than unlikely.
3. **Read-back verification.** A 2xx is treated as a claim, not evidence. Every
   write is followed by a GET that asserts the intended effect. This caught a
   real case where the API reported success and nothing had changed.
4. **Human-in-the-loop approval** that is single-use and expires in 24 hours,
   implemented with a durable Wait node and a decision persisted to the database.
5. **Batch isolation.** One bad record cannot abort a scheduled job.
6. **Scheduler idempotency.** Two independent guards, so an hourly job creates one
   offboarding, not 24.
7. **Constrained LLM use.** Exactly one model, with an enum-constrained schema,
   cross-field validation, evidence grounding, and no authority over any
   state-changing decision.
8. **Auditability.** Append-only event log plus two control queries that must
   return zero rows.

## Fault injection, the through-line

Three separate guards were verified by deliberately breaking things rather than
by reading the code:

- An identity provider made to fail a chosen action, proving rollback works
- The same provider killed **mid-rollback**, proving the system distinguishes
  `rolled_back` from `failed` and escalates only the second
- The LLM prompt stripped of its "quote the source verbatim" rule, proving the
  evidence-grounding check rejects untraceable claims (it rejected all seven
  extracted fields)

That last one is unusual and worth leading with in AI-flavoured contexts. Most
people who build LLM validation never test whether it catches anything.

---

## Claim boundaries

**Never write these.** Each is a sentence an interviewer could dismantle in one
question.

| Do not write | Why |
|---|---|
| "Integrated with Okta / Google Workspace / Azure AD" | The identity provider is a **simulator written for this project**. Say "a simulated identity provider" or "an identity API". |
| "Reduced onboarding time by X%" | Never ran in a company. There is no baseline. No metric exists. |
| "Production-grade" / "production-ready" / "deployed" | Runs single-process on localhost against a simulator. |
| "AI-powered provisioning" | The LLM drafts a request. It provisions nothing. |
| "Validated by an 11-scenario failure suite" | 8 of 11 exercised; the formal record with screenshots is incomplete. Say **"verified by fault injection across eight failure scenarios"**. |
| "Enterprise" anything | It is a demonstration by one person over three days. |

**Always keep this framing available.** The repo README leads with it and the
honesty is part of the pitch:

> A working demonstration, not a deployment. The identity provider is a
> simulator; all employee data is synthetic; it has never run in a company. What
> is real is the behaviour under failure.

**Known limitations, already documented in the repo README:** the approval link
proves possession of the link rather than identity (no SSO); webhook URLs point
at localhost; one target system only; work emails derived from names with no
collision handling; n8n single-process with SQLite for its own state; execution
data retained indefinitely; the access review reports drift but does not
remediate.

---

## Ready-to-use copy

### One-liner (CV header, project card title line)

> Employee provisioning orchestrator in n8n and PostgreSQL: policy-driven plans,
> human approval for privileged access, idempotent execution with read-back
> verification, and compensating rollback on partial failure.

### Very short (GitHub profile README table row, ~15 words)

> Self-healing employee provisioning: 9 n8n workflows with approval gating,
> idempotency, and reverse-order rollback.

### Portfolio site card (~100 words)

> **JML Orchestrator** is an employee onboarding and offboarding system built as
> nine n8n workflows over PostgreSQL. A request becomes an ordered plan derived
> from a policy table, privileged grants pause for human approval, each step
> executes idempotently and is verified by reading the target system back, and
> any partial failure is compensated in reverse order so no half-provisioned
> account is left behind. It keeps an append-only audit trail, fires due
> offboardings on a schedule, and reviews entitlement drift weekly. One tightly
> fenced LLM drafts requests from free-text email but has no authority over what
> gets provisioned. Runs against a simulated identity provider included in the
> repo.

### CV bullets (use two or three, not all four)

> Built an employee joiner/mover/leaver provisioning orchestrator as nine n8n
> workflows over PostgreSQL: each request derives an ordered plan from a policy
> table, privileged entitlements pause for human approval, and every step
> executes idempotently against an identity API and is verified by reading the
> target system back.

> Designed the system around at-least-once delivery semantics: deterministic
> per-step idempotency keys, a UNIQUE-constrained request ledger that makes
> duplicate submissions impossible rather than unlikely, and a reverse-order
> compensating rollback that returns the target system to its prior state when a
> plan fails partway, distinguishing "cleaned up" from "could not clean up" and
> escalating only the second.

> Implemented an append-only audit trail, scheduled jobs for due offboardings and
> SLA breaches with two independent guards against repeating side effects, and a
> weekly entitlement drift review that reports rather than auto-remediates,
> including a control query proving no privileged access was granted without a
> recorded approval.

> Added a single LLM feature that parses free-text HR emails into structured
> requests using an enum-constrained JSON schema, cross-field validation, and
> evidence grounding requiring the model to quote the source substring for every
> field it fills; its output becomes a pre-filled form a human submits rather
> than a database write, so an injected instruction to escalate privileges
> changes nothing about what gets provisioned.

### Skills this project evidences

Add or reinforce, where the portfolio's skill data supports it: n8n, workflow
automation, PostgreSQL, FastAPI, Python, JavaScript, REST API integration,
idempotency, saga / compensating transactions, webhooks, event-driven design,
retry and backoff, audit logging, human-in-the-loop design, LLM output
validation, prompt injection defence, PowerShell, Git.

---

## Assets available

All inside the repo, linkable directly from the portfolio site via raw GitHub
URLs.

| Asset | Path | Use |
|---|---|---|
| **Animated flow diagram** | `docs/assets/lifecycle-flow.svg` | The hero image. Three animated tracks: routine run, approval pause, reverse-order rollback. Confirmed animating on GitHub. Embed as `<img>`, not inline SVG. |
| Architecture diagram | `docs/architecture.mmd` + `docs/screenshots/00-architecture.png` | Mermaid source plus rendered PNG for non-mermaid contexts |
| Workflow canvases | `docs/screenshots/01-08` | Structure |
| Approval email | `docs/screenshots/09-approval-email.png` | The human gate |
| Rollback execution graph | `docs/screenshots/11-rollback-execution.png` | Strongest single image |
| Step ledger after rollback | `docs/screenshots/12-step-ledger-rollback.png` | Shows `compensated / failed / pending` |
| Control query, zero rows | `docs/screenshots/13-control-query-zero-rows.png` | Proves the approval guarantee |
| Request form | `docs/screenshots/16-request-form.png` | The human-facing surface |

**Not yet made:** a demo video. Outline exists at `docs/portfolio.md`. The F1
rollback segment is already screen-recorded; roughly 20 minutes more of recording
would finish it.

---


## In-repo docs worth reading if more detail is needed

`README.md` (the public pitch, with the evidence table) ·
`docs/00-architecture.md` (design rationale, including where AI deliberately is
not) · `docs/portfolio.md` (demo outline, interview answers, screenshot
checklist) · `docs/failure-tests.md` (the eleven-scenario runbook and its
partial results).

---

## Interview answers already prepared

Full versions in `docs/portfolio.md`. Summaries:

- **Why n8n and not code?** The value is integration and operability. n8n gives
  execution history, retries, and a durable waiting-execution model for free. The
  parts that had to be exact are Code nodes and SQL, version-controlled as JSON.
- **Why so little AI?** Provisioning is state-changing and security-relevant. A
  hallucinated group membership is a breach.
- **How do you know it works?** Two control queries that must return zero rows,
  read-back verification on every write, and fault injection across eight
  scenarios.
- **What breaks first at scale?** Single n8n process. Queue mode with Redis and
  workers, then Postgres for n8n's own state.
- **Hardest bug?** A sweeper that threw on a missing account, aborting the whole
  batch so every other due offboarding that hour silently did not happen. Taught
  him that batch jobs must isolate bad records.
- **How do you test an LLM guard?** Fault injection, the same way you test a
  rollback.

