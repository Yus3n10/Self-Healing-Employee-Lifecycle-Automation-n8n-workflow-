# Return the demo to a clean slate.
#
#     .\scripts\reset-demo.ps1
#
# Wipes the mock IdP's in-memory accounts, clears any injected chaos, and puts
# the TRUNCATE statement on your clipboard to paste into the Neon SQL Editor.
#
# What this deliberately does NOT touch:
#   role_entitlements  - the policy table. Wiping it would break every plan.
#   n8n's own database - workflows, credentials, execution history.
#
# Pass -ShowSql to print the SQL instead of copying it.

param([switch]$ShowSql)

$ErrorActionPreference = 'Stop'

$sql = @'
-- JML demo reset. Leaves role_entitlements (the policy) intact.
TRUNCATE audit_events, provisioning_steps, provisioning_runs, employees
  RESTART IDENTITY CASCADE;

-- Confirm: employees 0, runs 0, steps 0, audit 0, entitlements 35.
SELECT (SELECT count(*) FROM employees)          AS employees,
       (SELECT count(*) FROM provisioning_runs)  AS runs,
       (SELECT count(*) FROM provisioning_steps) AS steps,
       (SELECT count(*) FROM audit_events)       AS audit,
       (SELECT count(*) FROM role_entitlements)  AS entitlements;
'@

# --- 1. Mock IdP -----------------------------------------------------------
$h = @{ "X-API-Key" = $(if ($env:MOCK_IDP_API_KEY) { $env:MOCK_IDP_API_KEY }
                       else { "dev-mock-idp-key-change-me" }) }
try {
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8100/admin/reset" `
        -Headers $h -TimeoutSec 10 | Out-Null
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8100/admin/chaos" `
        -Headers $h -ContentType "application/json" -Body '{"mode":"off"}' `
        -TimeoutSec 10 | Out-Null
    $s = Invoke-RestMethod -Uri "http://127.0.0.1:8100/health" -TimeoutSec 10
    Write-Host "IdP reset. users=$($s.users) chaos=$($s.chaos_mode)" -ForegroundColor Green
}
catch {
    Write-Host "IdP not reachable at 127.0.0.1:8100 - start it first." -ForegroundColor Yellow
}

# --- 2. Warn about paused executions ---------------------------------------
# A run waiting on approval holds a run_id that is about to vanish. When the
# link is clicked afterwards the callback finds nothing and returns 410, and the
# paused execution sits until its 24h limit. Harmless, but confusing later.
Write-Host ""
Write-Host "Check n8n > Executions for anything still 'Waiting'." -ForegroundColor Yellow
Write-Host "Delete those first, or their approval links will 410 after the reset."

# --- 3. Postgres -----------------------------------------------------------
Write-Host ""
if ($ShowSql) {
    Write-Host $sql
}
else {
    try {
        Set-Clipboard -Value $sql
        Write-Host "TRUNCATE statement copied to clipboard." -ForegroundColor Green
        Write-Host "Paste it into the Neon SQL Editor and Run."
        Write-Host "Expected result: employees 0, runs 0, steps 0, audit 0, entitlements 35."
    }
    catch {
        Write-Host "Could not access clipboard. Run with -ShowSql and copy manually."
    }
}
