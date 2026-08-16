# Failure test suite

Eight deliberate failure scenarios. **Fill in the Expected column before you run
anything.** A prediction written afterwards is not a prediction, and the value
of this document to a reviewer is that it shows you knew what should happen.

Reset between every test:

```bash
curl.exe -X POST -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/admin/reset
```

```sql
TRUNCATE audit_events, provisioning_steps, provisioning_runs, employees RESTART IDENTITY CASCADE;
```

Full arm/do instructions for each: [`07-stage7-8.md`](07-stage7-8.md) Stage 7.

---

## Results

| # | Scenario | What it proves | Expected | Actual | Pass |
|---|---|---|---|---|---|
| F1 | Mid-plan API failure (`assign_license` fails permanently) | Compensating saga, reverse ordering, clean end state | | | |
| F2 | Duplicate form submission | `idempotency_root` UNIQUE constraint enforces dedup | | | |
| F3 | Manual retry of a succeeded step | `Idempotency-Key` prevents double-apply | | | |
| F4 | Rate limiting (two 429s with `Retry-After`) | Backoff on transient status; transient ≠ rollback | | | |
| F5 | IdP completely down | `failed` vs `rolled_back`; un-cleanable failure escalates | | | |
| F6 | Approval link clicked three times | Single-use token, decision immutability | | | |
| F7 | Approval link used after expiry | Time-bounded authority | | | |
| F8 | Prompt injection through AI intake | Model has no authority; architecture stops it, not the prompt | | | |

---

## Evidence per test

For each row, capture four things and drop them in `docs/screenshots/`:

1. The chaos command you ran
2. The n8n execution graph, showing which nodes went red
3. The `provisioning_steps` query result afterwards
4. The IdP state afterwards (`/admin/state` or the user GET)

```sql
-- Step 3 for any test: the ledger after the run
SELECT step_order, action_type, resource, status, attempts, verified, last_error
FROM provisioning_steps
WHERE run_id = (SELECT id FROM provisioning_runs ORDER BY created_at DESC LIMIT 1)
ORDER BY step_order;
```

```sql
-- The run's own verdict
SELECT run_type, status, requires_approval, decision, approved_at, started_at, finished_at
FROM provisioning_runs ORDER BY created_at DESC LIMIT 1;
```

```bash
curl.exe -H "X-API-Key: dev-mock-idp-key-change-me" http://127.0.0.1:8100/admin/state
```

---

## If a result differs from your prediction

Do not quietly edit the Expected column. Either the system is wrong or your
model of it was. Record which, in one line, under the table:

> F4: predicted the run would fail. It completed. My prediction was wrong; a
> 429 is retried by the node and never reaches the rollback path, which is the
> intended behaviour.

That note is worth more to a reviewer than eight green ticks.
