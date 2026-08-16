# 00 · What you are building, and why it is shaped this way

## The system in one paragraph

An HR request ("Ada starts Monday as a senior engineer" / "Ben leaves Friday")
enters through a form. The system turns that request into an explicit,
ordered **plan** of external side effects derived from a policy table, gets a
human to approve anything privileged, executes each step against an identity
provider **idempotently**, verifies after every write that the change actually
landed, and if any step fails it **rolls back the steps that already succeeded**
in reverse order. Every decision and every API call is written to an append-only
audit log. A scheduled sweeper catches offboardings that are due and approvals
that have gone stale.

## Why the design looks like this

Three constraints drive everything:

1. **Provisioning is state-changing and security-relevant.** A skipped
   revocation is a security hole; a wrongly granted admin group is a breach.
   So the execution path is 100% deterministic. No LLM decides what to grant.
2. **External APIs fail halfway.** Step 4 of 6 will time out eventually. A
   half-provisioned account is worse than none, because nobody knows it exists.
   So every run is a saga with compensating actions.
3. **Retries are inevitable, so every write must be safe to repeat.** Each step
   carries an idempotency key that is stable across the entire life of the run.
   Retrying, replaying, or double-submitting the form cannot double-apply.

## Where AI fits, and where it deliberately does not

AI appears in exactly one place: **Stage 3**, parsing a free-text HR email into
a *proposed* structured request. Its output is shown to a human on a
confirmation page and must be explicitly accepted before it becomes a plan.

It is kept out of:

| Decision | Why not AI |
|---|---|
| What entitlements a role gets | Comes from `role_entitlements`. Auditable, diffable, reviewable by a security team. A prompt is none of those. |
| Whether approval is required | A boolean on the policy row. A model that is 99% right here is 1% catastrophic. |
| Whether a step succeeded | Read back from the IdP and compared. Never inferred. |
| What to roll back | A static inverse map. Rollback runs when things are already broken; it must be the most boring code in the system. |

This is a feature of the project, not a limitation, and the README says so
explicitly. Knowing where not to put a model is the point.

## Component map

```
┌──────────────┐  form submit   ┌──────────────────────────────────────┐
│ HR requester │ ─────────────► │ WF1  JML — Intake & Plan             │
└──────────────┘                │  validate → dedup → resolve policy   │
                                │  → write run + steps → approval?     │
                                └───────┬──────────────────────┬───────┘
                                        │ privileged           │ routine
                            ┌───────────▼──────────┐           │
                            │ Send approval email  │           │
                            │ Wait (resume webhook)│           │
                            └───────────┬──────────┘           │
   ┌───────────────┐  click link        │                      │
   │ Manager       │ ──────────────────►│                      │
   └───────────────┘   ┌────────────────▼─────────┐            │
                       │ WF5 JML — Approval       │            │
                       │ Callback (writes         │            │
                       │ decision, hits resume)   │            │
                       └────────────────┬─────────┘            │
                                        └──────────┬───────────┘
                                                   ▼
                                   ┌───────────────────────────┐
                                   │ WF2  JML — Execute Plan   │
                                   │  loop steps in order      │
                                   └───────┬───────────────────┘
                                           │ one step at a time
                                   ┌───────▼───────────────────┐      ┌──────────────┐
                                   │ WF3  JML — Execute Step   │─────►│  Mock IdP    │
                                   │  build → call → verify    │◄─────│ :8100        │
                                   └───────┬───────────────────┘      └──────────────┘
                                    failure│
                                   ┌───────▼───────────────────┐
                                   │ WF4  JML — Rollback       │
                                   │  reverse order compensate │
                                   └───────────────────────────┘

  WF6 JML — Sweeper (hourly)   : due offboardings, stale approvals, SLA breach
  WF7 JML — Error Handler      : set as the Error Workflow on every workflow
  WF8 JML — AI Intake (Stage 3): free text → proposed request → human confirm
  WF9 JML — Access Review      : drift between intended and actual entitlements

  Postgres (Neon): employees · role_entitlements · provisioning_runs
                   provisioning_steps · audit_events
```

## The nine workflows

| # | Name in n8n | Trigger | Purpose |
|---|---|---|---|
| WF1 | `JML — Intake & Plan` | Form Trigger | Validate, dedup, plan, approve, dispatch |
| WF2 | `JML — Execute Plan` | Sub-workflow | Ordered loop over steps, decide rollback |
| WF3 | `JML — Execute Step` | Sub-workflow | One idempotent side effect + verification |
| WF4 | `JML — Rollback` | Sub-workflow | Compensate succeeded steps in reverse |
| WF5 | `JML — Approval Callback` | Webhook | Record the decision, release the Wait |
| WF6 | `JML — Sweeper` | Schedule (hourly) | Due offboardings, stale approvals, SLA |
| WF7 | `JML — Error Handler` | Error Trigger | Central failure logging and alerting |
| WF8 | `JML — AI Intake` | Form Trigger | Free text → structured proposal → confirm |
| WF9 | `JML — Access Review` | Schedule (weekly) | Intended vs actual entitlement drift |

Build them in the order the stage documents give, not this order. WF1 and WF3
come first because they are the thin slice that proves the plumbing.

## Stage plan

| Stage | Doc | What lands |
|---|---|---|
| 0 | `01-setup.md` | Node, n8n, Neon, mock IdP, credentials |
| 1 | `02-stage1.md` | Form → DB row → one real account created |
| 2 | `03-stage2.md` | Policy, plan, step ledger, ordered execution, approval gate |
| 3 | `04-stage3-ai.md` | Free-text intake with structured output and human confirm |
| 4 | `05-stage4-reliability.md` | Verification, retries, rollback saga, error workflow |
| 5 | `06-stage5-6.md` | Audit trail, offboarding, sweeper, SLA, production safeguards |
| 6 | `06-stage5-6.md` | Secrets, timeouts, git export, queue-mode notes |
| 7 | `07-stage7-8.md` | Eight deliberate failure scenarios, each with an expected result |
| 8 | `07-stage7-8.md` | README, diagrams, screenshots, demo script, resume bullets |

## Honesty rules for this project

These are not optional. They are what makes the project credible rather than
another demo with a fabricated metric.

- The IdP is a simulator you wrote. Say so in the README's first paragraph.
- All employee data is synthetic. No real names, no real emails.
- The project has never run in a company. Describe it as a working
  demonstration with reproducible failure tests, not as a deployment.
- The approval link proves possession of the link, not identity. A production
  version needs SSO on the approval page. Write that in the Limitations section
  rather than hoping nobody notices.
