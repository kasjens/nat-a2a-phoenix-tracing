# Setup for Windows (PowerShell 5.1 or PowerShell 7+).
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$NatVersion = "1.8.0"

# nat's CLI prints U+2713 / U+2717 status glyphs. On a stock Windows code page
# (cp1252) that raises UnicodeEncodeError inside click, and nat exits 1 even when
# the config is valid. Force UTF-8 for every child Python process.
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

function Write-Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host "  fail $m" -ForegroundColor Red; exit 1 }

# Several tools here write to stderr on a perfectly normal run: `docker info`
# when the daemon is down, `docker compose` progress, pip warnings, and
# `nat validate` emitting the 0.0.0.0 auth warning for researcher.yml. Under
# $ErrorActionPreference = "Stop", PowerShell 5.1 wraps native stderr in a
# terminating NativeCommandError, which would abort the script on all of those.
# Run native commands through here and judge them by exit code instead.
function Invoke-Native {
    param([Parameter(Mandatory = $true)][scriptblock] $Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Command *>$null
        return $LASTEXITCODE
    } catch {
        return 1
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-DockerRunning {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    return ((Invoke-Native { docker info }) -eq 0)
}

Write-Host ""
Write-Host "NAT + A2A + Phoenix demo setup"
Write-Host "=============================="
Write-Host ""
Write-Host "Preflight"

# --- Python -----------------------------------------------------------------
$py = $null
$pyArgs = @()
foreach ($candidate in @(@("py", "-3.12"), @("py", "-3.11"), @("python"))) {
    $exe  = $candidate[0]
    $rest = @($candidate | Select-Object -Skip 1)
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        try {
            $ver = & $exe @rest -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($ver -match '^3\.(1[1-9]|[2-9][0-9])$') { $py = $exe; $pyArgs = $rest; break }
        } catch { }
    }
}
if (-not $py) {
    Write-Fail "Python 3.11+ not found. Install from https://www.python.org/downloads/ and tick 'Add to PATH'."
}
Write-Ok "python: $py $($pyArgs -join ' ')".TrimEnd()

# --- Docker -----------------------------------------------------------------
if (Get-Command docker -ErrorAction SilentlyContinue) {
    if (Test-DockerRunning) { Write-Ok "docker: running" }
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
if (-not (Test-Path ".venv")) {
    & $py @pyArgs -m venv .venv
    Write-Ok "created .venv"
} else {
    Write-Ok "reusing .venv"
}

$venvPy  = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$venvNat = Join-Path $RepoRoot ".venv\Scripts\nat.exe"

$null = Invoke-Native { & $venvPy -m pip install --upgrade pip --quiet }
if ((Invoke-Native { & $venvPy -m pip install --quiet "nvidia-nat[phoenix,langchain,a2a]==$NatVersion" }) -ne 0) {
    Write-Fail "pip install of nvidia-nat $NatVersion failed. Re-run to see the error:`n         .venv\Scripts\python.exe -m pip install `"nvidia-nat[phoenix,langchain,a2a]==$NatVersion`""
}
Write-Ok "nvidia-nat $NatVersion + phoenix, langchain, a2a"

# Two compatibility shims the demo cannot run without. See plugin\ for the why.
if ((Invoke-Native { & $venvPy -m pip install --quiet -e ./plugin }) -ne 0) {
    Write-Fail "pip install of plugin/ failed. Re-run to see the error:`n         .venv\Scripts\python.exe -m pip install -e ./plugin"
}
Write-Ok "nat-demo-shims (a2a_client_shared + wikipedia user-agent)"

# --- Phoenix ----------------------------------------------------------------
Write-Host ""
Write-Host "Phoenix"
if (Test-DockerRunning) {
    if ((Invoke-Native { docker compose up -d }) -ne 0) {
        Write-Warn "docker compose up -d failed. Run it by hand to see the error."
    }
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
foreach ($cfg in @("configs\chain.yml", "configs\researcher.yml", "configs\planner.yml")) {
    if ((Invoke-Native { & $venvNat validate --config_file $cfg }) -eq 0) { Write-Ok $cfg }
    else { Write-Fail "$cfg did not validate. See the error with:`n         .venv\Scripts\nat.exe validate --config_file $cfg" }
}

Write-Host @"

Ready. The main demo is one command:

  .\.venv\Scripts\Activate.ps1
  nat run --config_file configs\chain.yml --input "Which company makes the H100, and when was it announced? Ask the researcher."

Act two, the same agents split over A2A, needs two terminals:

  # terminal 1
  nat start a2a --config_file configs\researcher.yml

  # terminal 2
  nat run --config_file configs\planner.yml --input "Which company makes the H100, and when was it announced? Use the researcher."

Then open http://localhost:6006 and pick the a2a-demo project.
"@
