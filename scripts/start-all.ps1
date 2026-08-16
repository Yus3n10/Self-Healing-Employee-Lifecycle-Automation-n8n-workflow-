# Launches both long-running servers, each in its OWN PowerShell window.
# Run this once at the start of a working session:
#     powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1
#
# Both windows stay open and keep running. Close a window (or Ctrl+C inside it)
# to stop that server. Nothing persists in the mock IdP between restarts, which
# is deliberate: every failure test starts from a clean slate.

$root = Split-Path $PSScriptRoot -Parent

# ── Window 1: the mock identity provider on http://127.0.0.1:8100 ───────────
$idp = @"
`$host.UI.RawUI.WindowTitle = 'JML :: mock IdP :8100'
Set-Location '$root\mock-idp'
`$env:MOCK_IDP_API_KEY = 'dev-mock-idp-key-change-me'
.\.venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8100
"@
Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $idp

# ── Window 2: n8n on http://localhost:5678 ──────────────────────────────────
$n8n = @"
`$host.UI.RawUI.WindowTitle = 'JML :: n8n :5678'
Set-Location '$root'
& '$PSScriptRoot\start-n8n.ps1'
"@
Start-Process powershell -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $n8n

Write-Host ""
Write-Host "Two windows opened:" -ForegroundColor Green
Write-Host "  mock IdP  http://127.0.0.1:8100/docs   (ready in ~2 seconds)"
Write-Host "  n8n       http://localhost:5678        (SLOW on first start)"
Write-Host ""
Write-Host "n8n's FIRST start runs database migrations and can take 1-3 minutes." -ForegroundColor Yellow
Write-Host "Until it prints 'Editor is now accessible via: http://localhost:5678/'," -ForegroundColor Yellow
Write-Host "the browser will say 'Unable to connect'. That is normal. Watch the" -ForegroundColor Yellow
Write-Host "n8n window, not the browser." -ForegroundColor Yellow
Write-Host ""
Write-Host "This window is free. Use it for curl and git." -ForegroundColor Cyan
Write-Host '  curl.exe http://127.0.0.1:8100/health'
