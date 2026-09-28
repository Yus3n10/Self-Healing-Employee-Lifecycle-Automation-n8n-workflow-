# Confirms the demo is actually usable, not just that processes exist.
#
#     powershell -ExecutionPolicy Bypass -File .\scripts\check-ready.ps1
#
# Health endpoints answering is not enough: n8n can serve /healthz while none of
# its workflows are registered. This probes a real workflow URL as well.

$ok = $true
function Check($label, $test, $fix) {
    try   { $r = & $test; Write-Host ("  OK    {0}  {1}" -f $label, $r) -ForegroundColor Green }
    catch { Write-Host ("  FAIL  {0}`n        -> {1}" -f $label, $fix) -ForegroundColor Red; $script:ok = $false }
}

function Code($url) {
    try { return [int](Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10).StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } else { throw } }
}

Write-Host "JML demo readiness" -ForegroundColor Cyan

Check "mock IdP up" {
    $h = Invoke-RestMethod http://127.0.0.1:8100/health -TimeoutSec 5
    "users=$($h.users) chaos=$($h.chaos_mode)"
} "run .\scripts\start-all.ps1"

Check "n8n up" {
    (Invoke-WebRequest http://localhost:5678/healthz -UseBasicParsing -TimeoutSec 5) | Out-Null; "healthz ok"
} "run .\scripts\start-all.ps1, then wait 1-3 minutes on a cold start"

Check "intake form registered" {
    $c = Code "http://localhost:5678/form/jml-request"; if ($c -ne 200) { throw "got $c" }; "200"
} "n8n is up but its workflows are not live (404). Restart n8n, then re-run this check"

Check "AI intake form registered" {
    $c = Code "http://localhost:5678/form/jml-ai-intake"; if ($c -ne 200) { throw "got $c" }; "200"
} "same fix as above"

Check "approval webhook registered" {
    $c = Code "http://localhost:5678/webhook/jml-approval?token=00000000000000000000000000000000&decision=approve"
    if ($c -ne 410) { throw "got $c" }; "410 (correct rejection of a junk token)"
} "same fix as above"

Write-Host ""
if ($ok) { Write-Host "Ready. Open http://localhost:5678" -ForegroundColor Green }
else     { Write-Host "Not ready. Fix the FAIL lines above." -ForegroundColor Yellow; exit 1 }
