-- JML Orchestrator :: canonical schema
-- Target: PostgreSQL 15+ (Neon free tier or any Postgres)
-- Run this ONCE, in order, before building any workflow.

-- gen_random_uuid() lives in pgcrypto on older servers; on PG13+ it is built in.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. employees :: one row per person, regardless of how many runs they have
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS employees (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_ref    text NOT NULL UNIQUE,          -- id from the HR system
    full_name       text NOT NULL,
    personal_email  text,
    work_email      text UNIQUE,                   -- derived, not user supplied
    role_code       text NOT NULL,
    department      text NOT NULL,
    manager_email   text NOT NULL,
    start_date      date,
    end_date        date,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','active','offboarding','offboarded')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. role_entitlements :: the POLICY. What a role is allowed to receive.
--    This table is the whole reason the workflow is deterministic.
--    department '*' means "applies to every department".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS role_entitlements (
    id            serial PRIMARY KEY,
    role_code     text NOT NULL,
    department    text NOT NULL DEFAULT '*',
    action_type   text NOT NULL
                  CHECK (action_type IN ('create_account','add_group','assign_license')),
    target_system text NOT NULL DEFAULT 'mockidp',
    resource      text NOT NULL DEFAULT '',        -- group name or licence sku
    is_privileged boolean NOT NULL DEFAULT false,  -- true => human approval required
    step_order    integer NOT NULL,
    UNIQUE (role_code, department, action_type, resource)
);

-- ---------------------------------------------------------------------------
-- 3. provisioning_runs :: one row per onboard/offboard attempt
--    idempotency_root is UNIQUE. A duplicate form submission cannot create
--    a second run; the database refuses it. This is the dedup mechanism.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provisioning_runs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id       uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    run_type          text NOT NULL CHECK (run_type IN ('onboard','offboard')),
    status            text NOT NULL DEFAULT 'planned'
                      CHECK (status IN ('planned','awaiting_approval','approved','rejected',
                                        'running','completed','failed','rolled_back','expired')),
    requires_approval boolean NOT NULL DEFAULT false,
    approval_token    text UNIQUE,
    approval_sent_at  timestamptz,
    approval_expires_at timestamptz,
    resume_url        text,          -- n8n Wait-node resume URL, stored so the
                                     -- approval callback workflow can release it
    approved_by       text,
    approved_at       timestamptz,
    decision          text CHECK (decision IN ('approved','rejected')),
    requested_by      text NOT NULL,
    idempotency_root  text NOT NULL UNIQUE,
    due_at            timestamptz,                 -- SLA deadline
    started_at        timestamptz,
    finished_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 4. provisioning_steps :: the LEDGER. One row per external side effect.
--    idempotency_key is UNIQUE and is also sent to the IdP as a header, so
--    the same step can never be applied twice even across full replays.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provisioning_steps (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id           uuid NOT NULL REFERENCES provisioning_runs(id) ON DELETE CASCADE,
    step_order       integer NOT NULL,
    action_type      text NOT NULL,
    target_system    text NOT NULL DEFAULT 'mockidp',
    resource         text NOT NULL DEFAULT '',
    is_privileged    boolean NOT NULL DEFAULT false,
    idempotency_key  text NOT NULL UNIQUE,
    status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','in_progress','succeeded','failed',
                                       'skipped','compensated','compensation_failed')),
    attempts         integer NOT NULL DEFAULT 0,
    last_error       text,
    request_payload  jsonb,
    response_payload jsonb,
    verified         boolean NOT NULL DEFAULT false,
    started_at       timestamptz,
    finished_at      timestamptz,
    UNIQUE (run_id, step_order)
);

-- ---------------------------------------------------------------------------
-- 5. audit_events :: append only. Never updated, never deleted.
--    This is the table an auditor reads.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_events (
    id         bigserial PRIMARY KEY,
    run_id     uuid,
    step_id    uuid,
    actor      text NOT NULL,          -- 'system', an email, or 'ai:gemini-flash-latest'
    event_type text NOT NULL,
    detail     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_steps_run           ON provisioning_steps (run_id, step_order);
CREATE INDEX IF NOT EXISTS idx_steps_status        ON provisioning_steps (status);
CREATE INDEX IF NOT EXISTS idx_runs_status_due     ON provisioning_runs (status, due_at);
CREATE INDEX IF NOT EXISTS idx_audit_run           ON audit_events (run_id, created_at);
CREATE INDEX IF NOT EXISTS idx_employees_enddate   ON employees (end_date, status);

-- ---------------------------------------------------------------------------
-- 6. Convenience view used by the reporting workflow in Stage 5
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_run_summary AS
SELECT r.id                                   AS run_id,
       r.run_type,
       r.status                               AS run_status,
       e.employee_ref,
       e.full_name,
       e.work_email,
       e.role_code,
       e.department,
       r.requires_approval,
       r.approved_by,
       r.approved_at,
       r.requested_by,
       r.created_at,
       r.started_at,
       r.finished_at,
       EXTRACT(EPOCH FROM (r.finished_at - r.created_at)) AS seconds_to_complete,
       count(s.*)                                                    AS steps_total,
       count(*) FILTER (WHERE s.status = 'succeeded')                AS steps_succeeded,
       count(*) FILTER (WHERE s.status = 'failed')                   AS steps_failed,
       count(*) FILTER (WHERE s.status = 'compensated')              AS steps_compensated,
       count(*) FILTER (WHERE s.status = 'succeeded' AND NOT s.verified) AS steps_unverified
FROM provisioning_runs r
JOIN employees e            ON e.id = r.employee_id
LEFT JOIN provisioning_steps s ON s.run_id = r.id
GROUP BY r.id, e.employee_ref, e.full_name, e.work_email, e.role_code, e.department;
