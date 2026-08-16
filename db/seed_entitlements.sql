-- JML Orchestrator :: the entitlement policy.
--
-- This table IS the authorisation model. Everything the system provisions comes
-- from here, which is why it is a table you can diff and review rather than a
-- prompt or a pile of if-statements.
--
-- Step order convention, relied on by Build Plan and by Rollback's reverse pass:
--     10      create_account   (must be first; nothing can be granted to nobody)
--     20-49   add_group
--     50-89   assign_license
--     90-99   reserved for offboarding actions (suspend, delete)
--
-- is_privileged = true forces a human approval gate for the whole run.
-- Set it on anything that grants write access to production, source control,
-- finance data, or the identity system itself.

TRUNCATE role_entitlements RESTART IDENTITY;

INSERT INTO role_entitlements
  (role_code, department, action_type, target_system, resource, is_privileged, step_order)
VALUES
-- ── ENG_JUNIOR / Engineering ── 6 steps, 1 privileged ───────────────────────
  ('ENG_JUNIOR',    'Engineering', 'create_account',  'mockidp', '',                false, 10),
  ('ENG_JUNIOR',    'Engineering', 'add_group',       'mockidp', 'all-staff',       false, 20),
  ('ENG_JUNIOR',    'Engineering', 'add_group',       'mockidp', 'engineering',     false, 21),
  ('ENG_JUNIOR',    'Engineering', 'add_group',       'mockidp', 'repo-write',      true,  22),
  ('ENG_JUNIOR',    'Engineering', 'assign_license',  'mockidp', 'IDE_PRO',         false, 50),
  ('ENG_JUNIOR',    'Engineering', 'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51),

-- ── ENG_SENIOR / Engineering ── 7 steps, 2 privileged ───────────────────────
  ('ENG_SENIOR',    'Engineering', 'create_account',  'mockidp', '',                false, 10),
  ('ENG_SENIOR',    'Engineering', 'add_group',       'mockidp', 'all-staff',       false, 20),
  ('ENG_SENIOR',    'Engineering', 'add_group',       'mockidp', 'engineering',     false, 21),
  ('ENG_SENIOR',    'Engineering', 'add_group',       'mockidp', 'repo-write',      true,  22),
  ('ENG_SENIOR',    'Engineering', 'add_group',       'mockidp', 'prod-readonly',   true,  23),
  ('ENG_SENIOR',    'Engineering', 'assign_license',  'mockidp', 'IDE_PRO',         false, 50),
  ('ENG_SENIOR',    'Engineering', 'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51),

-- ── SALES_REP / Sales ── 5 steps, 0 privileged (the no-approval happy path) ──
  ('SALES_REP',     'Sales',       'create_account',  'mockidp', '',                false, 10),
  ('SALES_REP',     'Sales',       'add_group',       'mockidp', 'all-staff',       false, 20),
  ('SALES_REP',     'Sales',       'add_group',       'mockidp', 'sales',           false, 21),
  ('SALES_REP',     'Sales',       'assign_license',  'mockidp', 'CRM_SEAT',        false, 50),
  ('SALES_REP',     'Sales',       'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51),

-- ── FIN_ANALYST / Finance ── 6 steps, 1 privileged ──────────────────────────
  ('FIN_ANALYST',   'Finance',     'create_account',  'mockidp', '',                false, 10),
  ('FIN_ANALYST',   'Finance',     'add_group',       'mockidp', 'all-staff',       false, 20),
  ('FIN_ANALYST',   'Finance',     'add_group',       'mockidp', 'finance',         false, 21),
  ('FIN_ANALYST',   'Finance',     'add_group',       'mockidp', 'finance-reports', true,  22),
  ('FIN_ANALYST',   'Finance',     'assign_license',  'mockidp', 'ERP_SEAT',        false, 50),
  ('FIN_ANALYST',   'Finance',     'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51),

-- ── SUPPORT_AGENT / Support ── 5 steps, 0 privileged ────────────────────────
  ('SUPPORT_AGENT', 'Support',     'create_account',  'mockidp', '',                false, 10),
  ('SUPPORT_AGENT', 'Support',     'add_group',       'mockidp', 'all-staff',       false, 20),
  ('SUPPORT_AGENT', 'Support',     'add_group',       'mockidp', 'support',         false, 21),
  ('SUPPORT_AGENT', 'Support',     'assign_license',  'mockidp', 'HELPDESK_SEAT',   false, 50),
  ('SUPPORT_AGENT', 'Support',     'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51),

-- ── IT_ADMIN / IT ── 6 steps, 1 privileged. Also forced to approval by role. ─
  ('IT_ADMIN',      'IT',          'create_account',  'mockidp', '',                false, 10),
  ('IT_ADMIN',      'IT',          'add_group',       'mockidp', 'all-staff',       false, 20),
  ('IT_ADMIN',      'IT',          'add_group',       'mockidp', 'it',              false, 21),
  ('IT_ADMIN',      'IT',          'add_group',       'mockidp', 'idp-admin',       true,  22),
  ('IT_ADMIN',      'IT',          'assign_license',  'mockidp', 'ADMIN_SEAT',      false, 50),
  ('IT_ADMIN',      'IT',          'assign_license',  'mockidp', 'OFFICE_BASIC',    false, 51);

-- Verification. Expected: 6 rows, counts 6 / 7 / 5 / 6 / 5 / 6.
SELECT role_code,
       department,
       count(*)                                  AS entitlements,
       count(*) FILTER (WHERE is_privileged)     AS privileged
FROM role_entitlements
GROUP BY role_code, department
ORDER BY role_code;
