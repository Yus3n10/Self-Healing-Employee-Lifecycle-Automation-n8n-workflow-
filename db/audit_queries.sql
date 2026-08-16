-- JML Orchestrator :: the queries that make the system defensible.
-- Run these in the Neon SQL Editor. Queries 3 and 5 are controls: they are
-- expected to return ZERO rows, always. If either ever returns a row, a
-- guarantee the README claims has a hole in it.

-- 1. Complete story of one run, in order, from the audit log alone.
--    Replace the UUID. This is the query you run when someone asks
--    "who granted prod-admin to this person and on whose authority?"
SELECT created_at, actor, event_type, detail
FROM audit_events
WHERE run_id = '00000000-0000-0000-0000-000000000000'
ORDER BY id;

-- 2. Who currently holds privileged entitlements, and under whose approval.
SELECT e.work_email, e.role_code, s.action_type, s.resource,
       r.approved_by, r.approved_at, r.requested_by
FROM provisioning_steps s
JOIN provisioning_runs  r ON r.id = s.run_id
JOIN employees          e ON e.id = r.employee_id
WHERE s.is_privileged AND s.status = 'succeeded'
ORDER BY r.approved_at DESC;

-- 3. CONTROL: anything privileged that was provisioned without an approval.
--    Expected: zero rows.
SELECT e.work_email, s.action_type, s.resource, r.id AS run_id, r.status
FROM provisioning_steps s
JOIN provisioning_runs  r ON r.id = s.run_id
JOIN employees          e ON e.id = r.employee_id
WHERE s.is_privileged
  AND s.status = 'succeeded'
  AND r.approved_at IS NULL;

-- 4. Runs that ended dirty and still need a human.
SELECT run_id, run_type, employee_ref, steps_failed, steps_compensated
FROM v_run_summary
WHERE run_status = 'failed'
ORDER BY created_at DESC;

-- 5. CONTROL: steps that reported success but could not be verified.
--    Expected: zero rows. A non-zero result means the IdP said yes and the
--    read-back disagreed, which is the failure mode verification exists for.
SELECT run_id, employee_ref, steps_unverified
FROM v_run_summary
WHERE steps_unverified > 0;

-- 6. Leavers whose access was not fully revoked. The security question.
SELECT e.employee_ref, e.full_name, e.work_email, e.end_date, e.status,
       r.status AS offboard_run_status,
       count(*) FILTER (WHERE s.status <> 'succeeded') AS steps_not_done
FROM employees e
LEFT JOIN provisioning_runs  r ON r.employee_id = e.id AND r.run_type = 'offboard'
LEFT JOIN provisioning_steps s ON s.run_id = r.id
WHERE e.end_date IS NOT NULL
  AND e.end_date <= (now() AT TIME ZONE 'Asia/Manila')::date
GROUP BY e.employee_ref, e.full_name, e.work_email, e.end_date, e.status, r.status
HAVING e.status <> 'offboarded' OR count(*) FILTER (WHERE s.status <> 'succeeded') > 0;

-- 7. Median time from request to completion, by run type.
SELECT run_type,
       count(*) AS runs,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds_to_complete)::numeric, 1) AS median_seconds,
       round(max(seconds_to_complete)::numeric, 1) AS worst_seconds
FROM v_run_summary
WHERE run_status = 'completed' AND seconds_to_complete IS NOT NULL
GROUP BY run_type;

-- 8. How often the idempotency layer actually caught a repeat.
SELECT count(*) FILTER (WHERE event_type = 'duplicate_request_blocked') AS duplicate_requests,
       count(*) FILTER (WHERE event_type = 'step_succeeded'
                          AND (detail ->> 'idempotent_replay')::boolean) AS replayed_steps,
       count(*) FILTER (WHERE event_type = 'step_failed')                AS failed_steps,
       count(*) FILTER (WHERE event_type = 'step_compensated')           AS compensated_steps
FROM audit_events;

-- 9. AI proposals versus what humans actually submitted. Run this after the
--    project has some history; it is how you measure the model rather than
--    assert it.
SELECT date_trunc('day', created_at) AS day,
       count(*) FILTER (WHERE event_type = 'ai_extraction_proposed') AS proposed,
       count(*) FILTER (WHERE event_type = 'ai_extraction_rejected') AS rejected,
       round(avg((detail ->> 'confidence')::numeric)
             FILTER (WHERE event_type = 'ai_extraction_proposed'), 3) AS mean_confidence
FROM audit_events
WHERE event_type IN ('ai_extraction_proposed', 'ai_extraction_rejected')
GROUP BY 1 ORDER BY 1 DESC;
