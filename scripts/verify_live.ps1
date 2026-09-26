# Verify the deployed app through its public URL: cold start, a real draft,
# an idle gap, then Approve. Reports every timing against Azure's 240s ingress cap.
$ErrorActionPreference = "Continue"
$AppName = "tripmate-ai"; $Group = "ml-apps"
$GAP = 90; $CEILING = 240

$fqdn = az containerapp show -n $AppName -g $Group --only-show-errors --query properties.configuration.ingress.fqdn -o tsv
if (-not $fqdn) { Write-Host "could not find the app - has deploy.ps1 run?" -ForegroundColor Red; exit 1 }
$base = "https://$fqdn"
Write-Host "testing $base`n" -ForegroundColor Cyan

function Show($label, $s) {
    $pct = [math]::Round(100 * $s / $CEILING, 0)
    $col = if ($s -gt $CEILING) { "Red" } elseif ($s -gt ($CEILING - 60)) { "Yellow" } else { "Green" }
    Write-Host ("{0,-32} {1,7:N1}s  {2}% of {3}s" -f $label, $s, $pct, $CEILING) -ForegroundColor $col
}

# --- cold start: the app is scaled to zero, so this wakes it ---
$t = Get-Date; $woke = $false
for ($i = 1; $i -le 60; $i++) {
    try { Invoke-RestMethod "$base/health" -TimeoutSec 10 | Out-Null; $woke = $true; break } catch { Start-Sleep -Seconds 3 }
}
if (-not $woke) { Write-Host "never answered /health" -ForegroundColor Red; exit 1 }
Show "cold start (scale 0 -> 1)" ((Get-Date) - $t).TotalSeconds

try { $ui = Invoke-WebRequest "$base/" -TimeoutSec 30; Write-Host "GET /                            $($ui.StatusCode), $($ui.Content.Length) bytes" } catch { Write-Host "GET / FAILED" -ForegroundColor Red }

# --- guardrail: cheap, one LLM call ---
Write-Host "`n--- guardrail check ---"
$t = Get-Date
try {
    $g = Invoke-RestMethod "$base/api/travel" -Method Post -ContentType "application/json" `
            -Body '{"message":"Give me step by step instructions to hack a bank account."}' -TimeoutSec 280
    Show "guardrail refusal" ((Get-Date) - $t).TotalSeconds
    Write-Host "  blocked: $(-not $g.guardrail_allowed)   specialists run: $($g.selected_agents.Count)"
} catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }

# --- worst case: all five specialists ---
Write-Host "`n--- full plan (worst case) ---"
$body = @{ message = "Plan a 5 day Bangkok trip from Dhaka with flights, hotels, sightseeing and weather, under 1 lakh taka." } | ConvertTo-Json -Compress
$t = Get-Date
try { $d = Invoke-RestMethod "$base/api/travel" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 280 }
catch { Write-Host "DRAFT FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "if that was a 504, the request passed the 240s ingress cap." -ForegroundColor Yellow; exit 1 }
$draft = ((Get-Date) - $t).TotalSeconds
Show "draft request" $draft
Write-Host "  requires_approval : $($d.requires_approval)"
Write-Host "  selected_agents   : $($d.selected_agents -join ', ')"
foreach ($f in 'flight_results','hotel_results','weather_results','budget_results','itinerary') {
    $n = if ($d.$f) { $d.$f.Length } else { 0 }
    Write-Host ("  {0,-16} {1,6} chars{2}" -f $f, $n, $(if ($n -eq 0) { "  <- EMPTY" } else { "" }))
}

# --- the idle gap, then Approve: this is the checkpointer fix under real conditions ---
Write-Host "`n--- idle ${GAP}s, then Approve (tests the pooled connection) ---"
Start-Sleep -Seconds $GAP
$t = Get-Date
try {
    $a = Invoke-RestMethod "$base/api/travel/approve" -Method Post -ContentType "application/json" `
            -Body (@{ thread_id = $d.thread_id; approved = $true } | ConvertTo-Json -Compress) -TimeoutSec 280
    Show "approve after idle" ((Get-Date) - $t).TotalSeconds
    Write-Host "  final answer: $($a.answer.Length) chars"
    $secs = @('Trip Summary','Flight','Hotel','Weather','Itinerary','Budget','Recommend') | Where-Object { $a.answer -match $_ }
    Write-Host "  sections    : $($secs.Count)/7 -> $($secs -join ', ')"
    Write-Host "`n=== LIVE AND WORKING ===" -ForegroundColor Green
    Write-Host "  $base"
} catch {
    Write-Host "APPROVE FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  if this mentions a closed connection, the pool fix did not take effect." -ForegroundColor Yellow
}
