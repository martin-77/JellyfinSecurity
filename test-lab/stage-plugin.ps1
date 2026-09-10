# Build the plugin and stage it into the lab's Jellyfin so it loads on (re)start.
#
#   pwsh ./stage-plugin.ps1            # build (fat) + copy + restart jellyfin
#   pwsh ./stage-plugin.ps1 -NoBuild   # just re-copy an existing dist/ + restart
#
# Reads TESTLAB_DATA from .env (falls back to ./data) so the plugin lands on the
# same NON-C drive the container mounts as /config.

param([switch]$NoBuild, [switch]$NoRestart)

$ErrorActionPreference = 'Stop'
$lab  = $PSScriptRoot
$repo = Split-Path $lab -Parent

# --- resolve TESTLAB_DATA (mirror docker-compose's ${TESTLAB_DATA:-./data}) ---
$dataRoot = Join-Path $lab 'data'
$envFile = Join-Path $lab '.env'
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^\s*TESTLAB_DATA\s*=\s*(.+?)\s*$' | Select-Object -First 1
    if ($m) { $dataRoot = $m.Matches[0].Groups[1].Value }
}
$pluginDir = Join-Path $dataRoot 'jellyfin-config/plugins/JellyfinSecurity'
Write-Host "Data root : $dataRoot"
Write-Host "Plugin dir: $pluginDir"

# --- build (fat package = DLL + all managed/native deps) ----------------------
if (-not $NoBuild) {
    $bash = (Get-Command bash -ErrorAction SilentlyContinue)?.Source
    if (-not $bash) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
    if (-not (Test-Path $bash)) { throw "Git Bash not found; run './build.sh fat' manually then re-run with -NoBuild." }
    Write-Host "Building (./build.sh fat)..."
    Push-Location $repo
    try { & $bash './build.sh' fat; if ($LASTEXITCODE -ne 0) { throw "build.sh failed ($LASTEXITCODE)" } }
    finally { Pop-Location }
}

$dist = Join-Path $repo 'dist/TwoFactorAuth'
if (-not (Test-Path $dist)) { throw "Build output not found at $dist — run a build first (omit -NoBuild)." }

# --- stage (clean copy so removed deps don't linger) --------------------------
if (Test-Path $pluginDir) { Remove-Item $pluginDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
Copy-Item (Join-Path $dist '*') $pluginDir -Recurse -Force
$dll = Join-Path $pluginDir 'Jellyfin.Plugin.TwoFactorAuth.dll'
Write-Host ("Staged " + (Get-ChildItem $pluginDir -Recurse -File | Measure-Object).Count + " files. DLL md5: " + (Get-FileHash $dll -Algorithm MD5).Hash)

# --- restart so Jellyfin reloads the assembly ---------------------------------
if (-not $NoRestart) {
    Write-Host "Restarting jstl-jellyfin..."
    docker restart jstl-jellyfin | Out-Null
    Write-Host "Done. Jellyfin: http://localhost:8096  (via proxy: http://localhost:8097)"
}
