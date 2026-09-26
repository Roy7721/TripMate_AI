# TripMate AI -> Azure Container Apps.
# Reads the five required keys from .env so no secret is typed into your shell history.
# Safe to re-run: if the app already exists it updates the image instead of failing.
$ErrorActionPreference = "Stop"

$Repo    = "G:\Telegram Desktop\TripMate_AI"
$Image   = "ranaroy01/tripmate-ai"
$AppName = "tripmate-ai"
$Group   = "ml-apps"
$EnvName = "yt-sentiment-api-env"

Set-Location $Repo

# --- 1. refuse to ship uncommitted code -------------------------------------
if (git status --porcelain) {
    Write-Host "STOP: you have uncommitted changes. Commit and push first." -ForegroundColor Red
    git status --short
    exit 1
}
$sha = (git rev-parse --short HEAD).Trim()
$local  = (git rev-parse HEAD).Trim()
$remote = (git rev-parse origin/master).Trim()
if ($local -ne $remote) {
    Write-Host "STOP: HEAD and origin/master differ. Push first so the tag matches GitHub." -ForegroundColor Red
    exit 1
}
Write-Host "deploying commit $sha" -ForegroundColor Cyan

# --- 2. read the keys from .env ---------------------------------------------
$cfg = @{}
foreach ($line in Get-Content "$Repo\.env") {
    if ($line -match '^\s*([^=#]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
$need = 'GROQ_API_KEY','TAVILY_API_KEY','AVIATIONSTACK_API_KEY','OPENWEATHER_API_KEY','DATABASE_URL'
$missing = $need | Where-Object { -not $cfg[$_] }
if ($missing) { Write-Host "STOP: .env is missing $($missing -join ', ')" -ForegroundColor Red; exit 1 }
if ($cfg['DATABASE_URL'] -notmatch 'neon\.tech') {
    Write-Host "WARNING: DATABASE_URL does not look like Neon. Check it before continuing." -ForegroundColor Yellow
}

# --- 3. tag and push the image ----------------------------------------------
Write-Host "`n== tagging and pushing $Image`:$sha ==" -ForegroundColor Cyan
docker tag tripmate-v3:test "$Image`:$sha"
if (-not $?) { Write-Host "docker tag failed - is Docker Desktop running, and does tripmate-v3:test exist?" -ForegroundColor Red; exit 1 }
docker push "$Image`:$sha"
if (-not $?) { Write-Host "docker push failed - try 'docker login' first." -ForegroundColor Red; exit 1 }

# --- 4. create or update the container app -----------------------------------
$secretArgs = @(
    "groq-key=$($cfg['GROQ_API_KEY'])"
    "tavily-key=$($cfg['TAVILY_API_KEY'])"
    "aviationstack-key=$($cfg['AVIATIONSTACK_API_KEY'])"
    "openweather-key=$($cfg['OPENWEATHER_API_KEY'])"
    "database-url=$($cfg['DATABASE_URL'])"
)
# LANGSMITH_* is deliberately omitted: tracing a public demo ships every visitor's
# query to LangSmith and burns that quota.
$envArgs = @(
    "GROQ_API_KEY=secretref:groq-key"
    "TAVILY_API_KEY=secretref:tavily-key"
    "AVIATIONSTACK_API_KEY=secretref:aviationstack-key"
    "OPENWEATHER_API_KEY=secretref:openweather-key"
    "DATABASE_URL=secretref:database-url"
)

$exists = az containerapp show -n $AppName -g $Group --query name -o tsv 2>$null

if ($exists) {
    Write-Host "`n== app exists: updating image and config ==" -ForegroundColor Cyan
    $a = @('containerapp','secret','set','-n',$AppName,'-g',$Group,'--secrets') + $secretArgs
    az @a | Out-Null
    $a = @('containerapp','update','-n',$AppName,'-g',$Group,
           '--image',"$Image`:$sha",
           '--cpu','1.0','--memory','2.0Gi',
           '--min-replicas','0','--max-replicas','1',
           '--set-env-vars') + $envArgs
    az @a | Out-Null
} else {
    Write-Host "`n== creating the container app ==" -ForegroundColor Cyan
    $a = @('containerapp','create','-n',$AppName,'-g',$Group,
           '--environment',$EnvName,
           '--image',"$Image`:$sha",
           '--target-port','8000','--ingress','external',
           '--cpu','1.0','--memory','2.0Gi',
           '--min-replicas','0','--max-replicas','1',
           '--secrets') + $secretArgs + @('--env-vars') + $envArgs
    az @a | Out-Null
}
if (-not $?) { Write-Host "az command failed - see the error above." -ForegroundColor Red; exit 1 }

# --- 5. report ---------------------------------------------------------------
$fqdn = az containerapp show -n $AppName -g $Group --query properties.configuration.ingress.fqdn -o tsv
Write-Host "`n=== DEPLOYED ===" -ForegroundColor Green
Write-Host "  commit : $sha"
Write-Host "  image  : $Image`:$sha"
Write-Host "  url    : https://$fqdn"
Write-Host "`nNow run verify_live.ps1 to test a real request through that URL."
