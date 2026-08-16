# JML Orchestrator

An employee joiner/mover/leaver provisioning orchestrator built in n8n and
PostgreSQL: policy-driven plan generation, human approval for privileged
entitlements, idempotent execution, read-back verification, and reverse-order
compensating rollback on partial failure.

**This is a working demonstration, not a deployment.** The identity provider in
`mock-idp/` is a simulator written for this project; there is no real IdP behind
it. All employee data is synthetic. The system has never run in a company. What
*is* real is the behaviour under failure, which is demonstrated by a
reproducible test suite rather than claimed.

## Reliability properties, and what proves each one

| Property | Mechanism | Demonstrated by |
|---|---|---|
| Duplicate requests cannot double-provision | `idempotency_root` UNIQUE column plus a pre-check | Resubmitting an identical request is refused by the ledger |
| Retries cannot double-apply | Deterministic per-step `Idempotency-Key` sent to the IdP | Replayed calls return `x-idempotent-replay: true` and change nothing |
| A 2xx response is not trusted | Every step reads the target system back and asserts the intended effect | A write that reports success but does nothing is marked `failed` |
| Partial failure leaves no orphan state | Reverse-order compensating saga over the step ledger | A mid-plan failure deletes the account it created |
| Un-cleanable failure is never silent | `rolled_back` and `failed` are distinct terminal states, with an alert on the second | Specified and implemented; not yet exercised (see `docs/failure-tests.md` F11) |
| Privileged access requires a human | `is_privileged` on the policy row plus a Wait-node gate | Nothing is provisioned until the approval link is clicked |
| Approval is single-use | Token nulled on first use, four validation conditions on the callback | A second click returns 410 |
| Approval is time-bounded | 24-hour expiry checked on the callback and on Wait timeout | Specified and implemented; not yet exercised (F7) |
| Scheduled jobs cannot repeat side effects | `NOT EXISTS` guard plus `ON CONFLICT DO NOTHING` | Four sweeper runs produce exactly one offboarding |
| One bad record cannot abort a batch | Missing accounts emit a zero-step plan instead of throwing | A due employee with no IdP account is audited and skipped |
| Granted access is re-checked, not assumed | Weekly diff of live entitlements against policy | Access granted outside the system is reported as `excess_access` |

Two queries in `db/audit_queries.sql` are **controls** and must always return
zero rows: nothing privileged provisioned without a recorded approval, and
nothing marked succeeded that the read-back could not confirm.

**On evidence.** Six of the behaviours above were exercised repeatedly during
development and are described from what was observed. Three were specified from
the design and have not yet been run as formal scenarios; they are marked as
such rather than implied. `docs/failure-tests.md` holds the full runbook with
expected behaviour written out per scenario, ready to execute and record.

## Limitations

Stated plainly, because a reviewer will find them anyway.

- **The approval link proves possession of the link, not identity.** `approved_by`
  records `link-holder@<ip>`, which is exactly what is known. Production needs
  SSO in front of the callback endpoint, recording the authenticated subject.
- **Webhook URLs point at `localhost`.** Approval links are therefore not
  clickable from a real mail client on another machine. Production needs a
  public HTTPS URL and inbound signature verification.
- **One target system.** A single IdP lets the plan/execute separation look real
  without proving it. A second target would.
- **Work emails are derived from names with no collision handling.** Two people
  called Ada Lovelace would clash on a UNIQUE constraint.
- **n8n runs in single-process mode with SQLite for its own state.** Queue mode
  with Redis and Postgres is the first change needed for concurrency.
- **Execution data is retained indefinitely** and contains employee records.
  `EXECUTIONS_DATA_MAX_AGE` and pruning would be required under any real
  retention policy.
- **Reviewed but not remediated.** The access review reports drift and
  deliberately does not act on it, because a bug in the diff would otherwise
  revoke production access on a Monday morning.

## Operational notes learned by running it

- **Neon's free tier scales compute to zero.** The first connection after an
  idle period can exceed n8n's startup database ping timeout, and n8n activates
  workflows during that window. The result is an n8n that serves `/healthz` fine
  while every webhook and form URL returns 404. Wake the database with any query
  before starting n8n, and verify with
  `curl.exe -s -o NUL -w "%{http_code}" http://localhost:5678/form/jml-request`
  rather than trusting the editor loading.
- **n8n executes a node once per incoming item.** Any node after a loop's `done`
  output that should act once needs **Execute Once**, or you get one email per
  item.
- **`$('Node').all()` after a loop returns the last iteration only.** Aggregate
  by writing each result to `audit_events` inside the loop and summarising with
  SQL.
- **Postgres node operation matters.** `Insert` for audit rows with the `id`
  column left unmapped, `Update` with `id` both mapped and set as the match
  column, and `Insert or Update` for exactly one node.

---

## Start here

| Doc | What it covers |
|---|---|
| [`docs/00-architecture.md`](docs/00-architecture.md) | The system, the nine workflows, and where AI deliberately is not |
| [`docs/01-setup.md`](docs/01-setup.md) | Stage 0: n8n, Neon, mock IdP, four credentials |
| [`docs/02-stage1.md`](docs/02-stage1.md) | Stage 1: form → database → one real account |
| [`docs/03-stage2.md`](docs/03-stage2.md) | Stage 2: policy, plan, ledger, approval gate, ordered execution |
| [`docs/04-stage3-ai.md`](docs/04-stage3-ai.md) | Stage 3: the one place an LLM belongs |
| [`docs/05-stage4-reliability.md`](docs/05-stage4-reliability.md) | Stage 4: rollback saga and the error workflow |
| [`docs/06-stage5-6.md`](docs/06-stage5-6.md) | Stages 5 and 6: audit, sweeper, SLA, drift review, production safeguards |
| [`docs/07-stage7-8.md`](docs/07-stage7-8.md) | Stages 7 and 8: eight failure tests, then packaging |

Work through them in order. Each stage ends with tests that must pass before
the next one starts.

---

## What is already in this repo

```
db/schema.sql               canonical schema: employees, role_entitlements,
                            provisioning_runs, provisioning_steps, audit_events
db/seed_entitlements.sql    the entitlement policy for six roles
mock-idp/main.py            simulated identity provider (FastAPI) with API-key
                            auth, idempotency keys, and injectable faults
mock-idp/test_mock_idp.py   self-check; asserts idempotent replay, injected
                            failure, and rate-limit signalling
scripts/start-n8n.ps1       starts n8n with the right timezone and a persisted
                            encryption key
.env.example                every value the project needs and where it is entered
```

## Quick start

One-time install (this command finishes and exits):

```bash
npm install -g n8n
```

Then every working session, one command. It opens the mock IdP and n8n in their
own windows and leaves the current one free:

```bash
cd "D:\Claude Local\jml-orchestrator"; powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1
```

Confirm both are up:

```bash
curl.exe http://127.0.0.1:8100/health
```

n8n is at http://localhost:5678, the IdP's API docs at http://127.0.0.1:8100/docs.

Then follow `docs/01-setup.md` from §0.3.

---

## PowerShell users: load the IdP helpers

The `curl` examples in `docs/` are written bash-style. Any of them that send a
JSON body (`-d "{\"mode\":\"off\"}"`) **fail on PowerShell 5.1**, which mangles
the escaped quotes and hands curl the JSON as a second URL:

```
curl: (3) URL rejected: Port number was not a decimal number between 0 and 65535
```

Plain `GET` examples with only `-H` headers work fine. For everything else, load
the wrappers once per session:

```bash
cd "D:\Claude Local\jml-orchestrator"; . .\scripts\idp.ps1
```

| Instead of the docs' curl | Use |
|---|---|
| `POST /admin/reset` | `Reset-Idp` |
| `GET /v1/users` | `Get-IdpUsers` |
| `GET /v1/users/{email}` | `Get-IdpUser ada.lovelace@demo-corp.test` |
| `POST /admin/chaos` | `Set-Chaos fail_action assign_license 50` / `Set-Chaos off` |
| manual group grant | `Grant-Group grace.hopper@demo-corp.test prod-admin` |
| `GET /admin/state` | `Get-IdpState` |
| `GET /health` | `Test-Idp` |

## The mock identity provider is a simulator

`mock-idp/` is a FastAPI service written for this project. It is not a real
identity provider and does not talk to one. It exists so the orchestration logic
can be built and failure-tested against something that behaves like a vendor
API: API-key auth, `Idempotency-Key` support with response replay, `429` with
`Retry-After`, and an `/admin/chaos` endpoint that injects failures on demand.

All employee data in this repository is synthetic.

---

## Design commitments

- **The LLM has no authority.** It appears once, drafting a request from a
  free-text email, and its output becomes a pre-filled form URL that a human
  submits. Entitlements, approval requirements, and success are all decided by
  the policy table, the ledger, and read-back verification.
- **Every write is safe to repeat.** Deterministic per-step idempotency keys, a
  UNIQUE-constrained request ledger, and idempotency headers on every call.
- **A 2xx is a claim, not evidence.** Each step reads the target system back and
  asserts the intended effect before being marked succeeded.
- **Partial failure is undone, and un-undoable failure is escalated.**
  `rolled_back` and `failed` are different words for different situations.
- **The audit log is append-only** and can reconstruct any run without the
  execution history.
