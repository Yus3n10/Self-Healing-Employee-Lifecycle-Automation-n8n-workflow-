# Mock IdP helpers for PowerShell.
#
# PowerShell 5.1 mangles backslash-escaped JSON passed to curl.exe, so every
# bash-style `curl -d "{\"a\":1}"` in the docs fails here with
# "URL rejected: Port number was not a decimal number". These wrappers use
# Invoke-RestMethod instead, which takes the JSON literally.
#
# Load once per session (note the leading dot and space):
#     . .\scripts\idp.ps1
#
# Then:
#     Reset-Idp
#     Get-IdpUsers
#     Get-IdpUser ada.lovelace@demo-corp.test
#     Grant-Group grace.hopper@demo-corp.test prod-admin
#     Set-Chaos fail_action assign_license 50
#     Set-Chaos off
#     Get-IdpState

$script:IdpBase = "http://127.0.0.1:8100"
$script:IdpKey  = "dev-mock-idp-key-change-me"

function script:IdpHeaders([string]$IdempotencyKey) {
    $h = @{ "X-API-Key" = $script:IdpKey }
    if ($IdempotencyKey) { $h["Idempotency-Key"] = $IdempotencyKey }
    return $h
}

function Reset-Idp {
    Invoke-RestMethod -Method Post -Uri "$script:IdpBase/admin/reset" -Headers (IdpHeaders)
}

function Get-IdpState {
    Invoke-RestMethod -Method Get -Uri "$script:IdpBase/admin/state" -Headers (IdpHeaders)
}

function Get-IdpUsers {
    Invoke-RestMethod -Method Get -Uri "$script:IdpBase/v1/users" -Headers (IdpHeaders)
}

function Get-IdpUser([Parameter(Mandatory)][string]$Email) {
    Invoke-RestMethod -Method Get -Uri "$script:IdpBase/v1/users/$Email" -Headers (IdpHeaders)
}

function Grant-Group {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Group,
        [string]$IdempotencyKey = "manual-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    )
    # Deliberately bypasses the orchestrator. Used to simulate access granted
    # by hand outside the system, which offboarding must still revoke.
    Invoke-RestMethod -Method Post `
        -Uri "$script:IdpBase/v1/users/$Email/groups" `
        -Headers (IdpHeaders $IdempotencyKey) `
        -ContentType "application/json" `
        -Body (@{ group = $Group } | ConvertTo-Json -Compress)
}

function Grant-License {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Sku,
        [string]$IdempotencyKey = "manual-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    )
    Invoke-RestMethod -Method Post `
        -Uri "$script:IdpBase/v1/users/$Email/licenses" `
        -Headers (IdpHeaders $IdempotencyKey) `
        -ContentType "application/json" `
        -Body (@{ sku = $Sku } | ConvertTo-Json -Compress)
}

function Set-Chaos {
    # Positional order is Mode, Action, Remaining. Only fail_action takes an
    # Action, so every other mode must name the count:
    #     Set-Chaos fail_action assign_license 50
    #     Set-Chaos -Mode flaky -Remaining 50
    #     Set-Chaos -Mode rate_limit -Remaining 2
    #     Set-Chaos off
    param(
        [ValidateSet('off','rate_limit','fail_action','slow','flaky')]
        [string]$Mode = 'off',
        [ValidateSet('add_group','assign_license','create_account','delete_account',
                     'remove_group','revoke_license','revoke_sessions','suspend_account')]
        [string]$Action,
        [int]$Remaining = 1,
        [double]$SlowSeconds = 3.0
    )
    if ($Action -and $Mode -ne 'fail_action') {
        throw "Action '$Action' only applies to -Mode fail_action. For '$Mode' use: Set-Chaos -Mode $Mode -Remaining <n>"
    }
    $body = @{ mode = $Mode; remaining = $Remaining; slow_seconds = $SlowSeconds }
    if ($Action) { $body.target_action = $Action }
    Invoke-RestMethod -Method Post -Uri "$script:IdpBase/admin/chaos" `
        -Headers (IdpHeaders) -ContentType "application/json" `
        -Body ($body | ConvertTo-Json -Compress)
}

function Test-Idp {
    try {
        $r = Invoke-RestMethod -Method Get -Uri "$script:IdpBase/health" -TimeoutSec 5
        Write-Host "IdP up. users=$($r.users) chaos=$($r.chaos_mode)" -ForegroundColor Green
    } catch {
        Write-Host "IdP DOWN at $script:IdpBase" -ForegroundColor Red
    }
}

Write-Host "IdP helpers loaded: Reset-Idp, Get-IdpUsers, Get-IdpUser, Grant-Group, Grant-License, Set-Chaos, Get-IdpState, Test-Idp" -ForegroundColor Cyan
