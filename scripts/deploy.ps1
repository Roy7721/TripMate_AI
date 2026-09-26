# TripMate AI -> Azure Container Apps.
# Reads the five required keys from .env so no secret is typed into your shell history.
# Safe to re-run: layers already on Docker Hub resume as "Already exists", and if the
# container app already exists this updates it instead of failing.
#
# NOTE on error handling: ErrorActionPreference is deliberately "Continue". In Windows
# PowerShell 5.1, a native command writing to stderr under "Stop" becomes a terminating
# error - and `az` writes a harmless extension WARNING to stderr on every call. Native
# failures are detected with $LASTEXITCODE instead, which is the reliable signal.
$ErrorActionPreference = "Continue"

$Repo    = "G:\Telegram Desktop\TripMate_AI"
$Image   = "ranaroy01/tripmate-ai"
$AppName = "tripmate-ai"
$Group   = "ml-apps"
$EnvName = "yt-sentiment-api-env"

function Die($msg) { Write-Host "`n$msg" -ForegroundColor Red; exit 1 }

Set-Location $Repo

# --- 1. refuse to ship uncommitted code -------------------------------------
if (git status --porcelain) {
    git status --short
    Die "STOP: uncommitted changes. Commit and push first, so the image tag matches GitHub."
}
$sha = (git rev-parse --short HEAD).Trim()
if ((git rev-parse HEAD).Trim() -ne (git rev-parse origin/master).Trim()) {
    Die "STOP: HEAD and origin/master differ. Push first."
}
Write-Host "deploying commit $sha" -ForegroundColor Cyan

# --- 2. read the keys from .env ---------------------------------------------
$cfg = @{}
foreach ($line in Get-Content "$Repo\.env") {
    if ($line -match '^\s*([^=#]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
$need = 'GROQ_API_KEY','TAVILY_API_KEY','AVIATIONSTACK_API_KEY','OPENWEATHER_API_KEY','DATABASE_URL'
$missing = $need | Where-Object { -not $cfg[$_] }
if ($missing) { Die "STOP: .env is missing $($missing -join ', ')" }
if ($cfg['DATABASE_URL'] -notmatch 'neon\.tech') {
    Write-Host "WARNING: DATABASE_URL does not look like Neon." -ForegroundColor Yellow
}

# --- 3. tag and push ---------------------------------------------------------
Write-Host "`n== tagging and pushing $Image`:$sha ==" -ForegroundColor Cyan
docker tag tripmate-v3:test "$Image`:$sha"
if ($LASTEXITCODE -ne 0) { Die "docker tag failed - is Docker Desktop running, and does tripmate-v3:test exist?" }

docker push "$Image`:$sha"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`ndocker push failed. Read the LAST line of the output above:" -ForegroundColor Red
    Write-Host "  'net/http: timeout awaiting response headers' -> network timeout, NOT auth."
    Write-Host "     Re-run this script; completed layers resume as 'Already exists'."
    Write-Host "  'unauthorized' / 'denied'                     -> run 'docker login', then re-run."
    exit 1
}

# --- 4. create or update the container app -----------------------------------
# Azure CLI on Windows is az.cmd - a BATCH wrapper - so cmd.exe re-parses every
# argument and treats an unquoted `&` as a command separator. No quoting survives it
# (embedded quotes and ^-escaping were both tested and both fail). A Neon URL like
# ...?sslmode=require&channel_binding=require therefore gets cut in half.
# Fix: strip the query string entirely. backend.py's get_database_url() re-appends
# sslmode=require by itself, and channel binding moves to PGCHANNELBINDING below,
# which libpq reads and which contains no shell metacharacters.
$dbUrl = ($cfg['DATABASE_URL'] -split '\?')[0]

$secretArgs = @(
    "groq-key=$($cfg['GROQ_API_KEY'])"
    "tavily-key=$($cfg['TAVILY_API_KEY'])"
    "aviationstack-key=$($cfg['AVIATIONSTACK_API_KEY'])"
    "openweather-key=$($cfg['OPENWEATHER_API_KEY'])"
    "database-url=$dbUrl"
)

# Guard: anything cmd.exe would treat as syntax will silently corrupt the secret.
foreach ($s in $secretArgs) {
    if ($s -match '[&|<>^]') {
        Die "STOP: a secret contains a cmd.exe metacharacter (& | < > ^) and would be mangled:`n  $($s -replace ':[^@]*@', ':***@')"
    }
}
# LANGSMITH_* is deliberately omitted: tracing a public demo ships every visitor's
# query to LangSmith and burns that quota.
$envArgs = @(
    "GROQ_API_KEY=secretref:groq-key"
    "TAVILY_API_KEY=secretref:tavily-key"
    "AVIATIONSTACK_API_KEY=secretref:aviationstack-key"
    "OPENWEATHER_API_KEY=secretref:openweather-key"
    "DATABASE_URL=secretref:database-url"
    # Neon's own connection string asks for channel binding; carried here rather than
    # in the URL so no `&` reaches cmd.exe. Verified: libpq reads this, and rejects a
    # bad value, so it is genuinely in effect.
    "PGCHANNELBINDING=require"
)

# `list` returns empty + exit 0 when absent, unlike `show` which errors. Quieter.
$existing = az containerapp list -g $Group --only-show-errors --query "[?name=='$AppName'].name" -o tsv
if ($LASTEXITCODE -ne 0) { Die "az could not list container apps - are you logged in? Try 'az login'." }

if ($existing) {
    Write-Host "`n== app exists: updating secrets, image and scale ==" -ForegroundColor Cyan
    $a = @('containerapp','secret','set','-n',$AppName,'-g',$Group,'--only-show-errors','--secrets') + $secretArgs
    az @a | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "az containerapp secret set failed." }

    $a = @('containerapp','update','-n',$AppName,'-g',$Group,'--only-show-errors',
           '--image',"$Image`:$sha",
           '--cpu','1.0','--memory','2.0Gi',
           '--min-replicas','0','--max-replicas','1',
           '--set-env-vars') + $envArgs
    az @a | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "az containerapp update failed." }
} else {
    Write-Host "`n== creating the container app ==" -ForegroundColor Cyan
    $a = @('containerapp','create','-n',$AppName,'-g',$Group,'--only-show-errors',
           '--environment',$EnvName,
           '--image',"$Image`:$sha",
           '--target-port','8000','--ingress','external',
           '--cpu','1.0','--memory','2.0Gi',
           '--min-replicas','0','--max-replicas','1',
           '--secrets') + $secretArgs + @('--env-vars') + $envArgs
    az @a | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "az containerapp create failed." }
}

# --- 5. report ---------------------------------------------------------------
$fqdn = az containerapp show -n $AppName -g $Group --only-show-errors --query properties.configuration.ingress.fqdn -o tsv
Write-Host "`n=== DEPLOYED ===" -ForegroundColor Green
Write-Host "  commit : $sha"
Write-Host "  image  : $Image`:$sha"
Write-Host "  url    : https://$fqdn"
Write-Host "`nNow run verify_live.ps1 to test a real request through that URL."
