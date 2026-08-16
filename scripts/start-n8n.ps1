# Starts n8n with the environment this project needs.
# Run from a normal (non-admin) PowerShell window:  .\scripts\start-n8n.ps1
#
# N8N_ENCRYPTION_KEY: generate ONCE, then keep it forever. Changing it makes
# every saved credential undecryptable. Generate with:
#   [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Max 256 }))

# Key resolution order, most authoritative first:
#   1. N8N_ENCRYPTION_KEY already set in this session
#   2. the key n8n itself generated in ~/.n8n/config   <-- adopt, never override
#   3. our own backup copy
#   4. generate a new one
# Order matters: n8n writes ~/.n8n/config on its first run of ANY command,
# including `n8n --help`. Overriding that key with a different one is how you
# end up with credentials that no longer decrypt.
$keyFile    = Join-Path $HOME ".n8n\project-encryption-key.txt"
$n8nConfig  = Join-Path $HOME ".n8n\config"

if (-not $env:N8N_ENCRYPTION_KEY) {
    if (Test-Path $n8nConfig) {
        try {
            $cfgKey = (Get-Content $n8nConfig -Raw | ConvertFrom-Json).encryptionKey
        } catch { $cfgKey = $null }
        if ($cfgKey) {
            $env:N8N_ENCRYPTION_KEY = $cfgKey
            Write-Host "Adopted the encryption key already in $n8nConfig"
        }
    }
}

if (-not $env:N8N_ENCRYPTION_KEY -and (Test-Path $keyFile)) {
    $env:N8N_ENCRYPTION_KEY = (Get-Content $keyFile -Raw).Trim()
    Write-Host "Loaded encryption key from $keyFile"
}

if (-not $env:N8N_ENCRYPTION_KEY) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $env:N8N_ENCRYPTION_KEY = [Convert]::ToBase64String($bytes)
    Write-Host "Generated a NEW encryption key."
}

# Always keep a backup copy outside n8n's own config.
if (-not (Test-Path $keyFile) -or
    ((Get-Content $keyFile -Raw).Trim() -ne $env:N8N_ENCRYPTION_KEY)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $keyFile) | Out-Null
    Set-Content -Path $keyFile -Value $env:N8N_ENCRYPTION_KEY -Encoding utf8
    Write-Host "Backed the key up to $keyFile"
    Write-Host "Copy that file somewhere safe. Losing it means re-entering every credential."
}

$env:GENERIC_TIMEZONE               = "Asia/Manila"
$env:TZ                             = "Asia/Manila"
$env:N8N_HOST                       = "localhost"
$env:N8N_PORT                       = "5678"
$env:N8N_PROTOCOL                   = "http"
# n8n 2.x renamed this. WEBHOOK_URL still works but prints a deprecation warning.
$env:N8N_WEBHOOK_URL                = "http://localhost:5678/"
$env:N8N_DEFAULT_BINARY_DATA_MODE   = "filesystem"
$env:N8N_DIAGNOSTICS_ENABLED        = "false"
$env:N8N_RUNNERS_ENABLED            = "true"
$env:N8N_LOG_LEVEL                  = "info"

Write-Host "Starting n8n on http://localhost:5678 ..."
n8n start
