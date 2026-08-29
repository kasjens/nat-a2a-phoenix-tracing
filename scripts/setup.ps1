# Setup for Windows (PowerShell 5.1 or PowerShell 7+).
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$NatVersion = "1.8.0"

function Write-Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host "  fail $m" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "NAT + A2A + Phoenix demo setup"
Write-Host "=============================="
Write-Host ""
Write-Host "Preflight"

# --- Python -----------------------------------------------------------------
$py = $null
foreach ($cmd in @("py -3.12", "py -3.11", "python")) {
    $parts = $cmd.Split(" ")
    $exe = $parts[0]
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        try {
            $ver = & $exe $parts[1..($parts.Length-1)] -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($ver -match '^3\.(1[1-9]|[2-9][0-9])$') { $py = $cmd; break }
        } catch { }
    }
}
if (-not $py) {
    Write-Fail "Python 3.11+ not found. Install from https://www.python.org/downloads/ and tick 'Add to PATH'."
}
Write-Ok "python: $py"

# --- Docker -----------------------------------------------------------------
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker info *>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "docker: running" }
    else { Write-Warn "Docker Desktop is installed but not running. Start it before the demo." }
} else {
    Write-Warn "docker not found. Phoenix will not start. See https://docs.docker.com/desktop/install/windows-install/"
}

# --- API key ----------------------------------------------------------------
if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $val = $Matches[2].Trim('"').Trim("'")
            [Environment]::SetEnvironmentVariable($Matches[1], $val, "Process")
        }
    }
    Write-Ok ".env loaded"
}
if ($env:NVIDIA_API_KEY) {
    Write-Ok "NVIDIA_API_KEY set ($($env:NVIDIA_API_KEY.Substring(0, [Math]::Min(8, $env:NVIDIA_API_KEY.Length)))...)"
} else {
    Write-Warn "NVIDIA_API_KEY not set. Get one at https://build.nvidia.com, then:"
    Write-Warn "  copy .env.example .env   and put the key in it"
}

# --- Install ----------------------------------------------------------------
Write-Host ""
Write-Host "Installing"
$pyParts = $py.Split(" ")
if (-not (Test-Path ".venv")) {
    & $pyParts[0] $pyParts[1..($pyParts.Length-1)] -m venv .venv
    Write-Ok "created .venv"
} else {
    Write-Ok "reusing .venv"
}

$venvPy  = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$venvNat = Join-Path $RepoRoot ".venv\Scripts\nat.exe"

& $venvPy -m pip install --upgrade pip --quiet
& $venvPy -m pip install --quiet "nvidia-nat[phoenix,langchain,a2a]==$NatVersion"
Write-Ok "nvidia-nat $NatVersion + phoenix, langchain, a2a"

# --- Phoenix ----------------------------------------------------------------
Write-Host ""
Write-Host "Phoenix"
docker info *>$null
if ($LASTEXITCODE -eq 0) {
    docker compose up -d
    $up = $false
    foreach ($i in 1..30) {
        try {
            Invoke-WebRequest -Uri "http://localhost:6006" -UseBasicParsing -TimeoutSec 2 *>$null
            $up = $true; break
        } catch { Start-Sleep -Seconds 1 }
    }
    if ($up) { Write-Ok "Phoenix up at http://localhost:6006" }
    else { Write-Warn "Phoenix container started but the UI is not answering yet. Give it a moment." }
} else {
    Write-Warn "skipped, docker unavailable"
}

# --- Validate ---------------------------------------------------------------
Write-Host ""
Write-Host "Validating configs"
if (-not $env:NVIDIA_API_KEY) { $env:NVIDIA_API_KEY = "nvapi-placeholder" }
foreach ($cfg in @("configs\researcher.yml", "configs\planner.yml")) {
    & $venvNat validate --config_file $cfg *>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok $cfg } else { Write-Fail "$cfg did not validate" }
}

Write-Host @"

Ready. Two terminals:

  # terminal 1
  .\.venv\Scripts\Activate.ps1
  nat start --config_file configs\researcher.yml

  # terminal 2
  .\.venv\Scripts\Activate.ps1
  nat run --config_file configs\planner.yml --input "Which company makes the H100, and when was it announced? Use the researcher."

Then open http://localhost:6006 and pick the a2a-demo project.
"@
