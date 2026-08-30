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

# --- Browser UI --------------------------------------------------------------
# The chat UI is a separate NVIDIA project, not part of nvidia-nat, so it has to be
# fetched. Two instances: one pointed at the planner (:8001) and one at the bare model
# (:8002), because a UI instance talks to exactly one backend and Scene 1 of the demo
# needs both on screen. See docs\ui.md. Skipped with a warning if node is missing.
$UiRepo = "https://github.com/NVIDIA/NeMo-Agent-Toolkit-UI.git"

# Replace KEY=... in an env file, or append it if absent. Idempotent, so re-running does
# not accumulate duplicate keys.
function Set-EnvKey {
    param([string] $File, [string] $Key, [string] $Value)
    $lines = @(Get-Content -LiteralPath $File | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" })
    $lines += "$Key=$Value"
    Set-Content -LiteralPath $File -Value $lines -Encoding UTF8
}

Write-Host ""
Write-Host "Browser UI"
$node = Get-Command node -ErrorAction SilentlyContinue
$npm  = Get-Command npm  -ErrorAction SilentlyContinue
if ($node -and $npm) {
    if (-not (Test-Path "ui\.git")) {
        if ((Invoke-Native { git clone --depth 1 $UiRepo ui }) -eq 0) { Write-Ok "cloned NeMo-Agent-Toolkit-UI" }
        else { Write-Warn "could not clone $UiRepo -- check your network, or clone it into .\ui yourself" }
    } else { Write-Ok "reusing .\ui" }

    if (Test-Path "ui") {
        if (-not (Test-Path "ui\node_modules")) {
            Push-Location ui
            $rc = Invoke-Native { npm ci --no-audit --no-fund }
            Pop-Location
            if ($rc -eq 0) { Write-Ok "npm ci (about 1100 packages)" } else { Write-Warn "npm ci failed in .\ui" }
        } else { Write-Ok "ui\node_modules present" }

        if (Test-Path "ui\.env") {
            Set-EnvKey "ui\.env" "NAT_BACKEND_URL" "http://127.0.0.1:8001"
            Set-EnvKey "ui\.env" "PORT" "3000"
            Set-EnvKey "ui\.env" "NEXT_INTERNAL_URL" "http://localhost:3099"
            # this one is why the remote agent's reasoning shows up in the chat window
            Set-EnvKey "ui\.env" "NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS" "true"
            Set-EnvKey "ui\.env" "NEXT_PUBLIC_NAT_WORKFLOW" "Planner"
            Set-EnvKey "ui\.env" "NEXT_PUBLIC_NAT_GREETING_TITLE" '"Ask the planner"'
            Set-EnvKey "ui\.env" "NEXT_PUBLIC_NAT_GREETING_SUBTITLE" '"It will delegate anything factual to the researcher."'
            Write-Ok "ui\.env -> planner on :8001, browse :3000"
        } else { Write-Warn "ui\.env not found; the upstream layout may have changed" }

        # instance 2: the bare model, for Scene 1. Windows has no cheap symlink for an
        # unprivileged user, so node_modules is copied rather than linked -- slower and
        # larger than the Unix path, but it does not need Developer Mode.
        if (Test-Path "ui\node_modules") {
            if (Test-Path "ui-model-only") { Remove-Item -Recurse -Force "ui-model-only" }
            New-Item -ItemType Directory -Path "ui-model-only" | Out-Null
            Get-ChildItem -Path "ui" -Force |
                Where-Object { $_.Name -notin @("node_modules", ".next", ".git") } |
                ForEach-Object { Copy-Item -Recurse -Force -LiteralPath $_.FullName -Destination "ui-model-only" }
            Copy-Item -Recurse -Force -LiteralPath "ui\node_modules" -Destination "ui-model-only\node_modules"
            Set-EnvKey "ui-model-only\.env" "NAT_BACKEND_URL" "http://127.0.0.1:8002"
            Set-EnvKey "ui-model-only\.env" "PORT" "3001"
            Set-EnvKey "ui-model-only\.env" "NEXT_INTERNAL_URL" "http://localhost:3098"
            Set-EnvKey "ui-model-only\.env" "NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS" "false"
            Set-EnvKey "ui-model-only\.env" "NEXT_PUBLIC_NAT_WORKFLOW" "Model only"
            Set-EnvKey "ui-model-only\.env" "NEXT_PUBLIC_NAT_GREETING_TITLE" '"Ask the model"'
            Set-EnvKey "ui-model-only\.env" "NEXT_PUBLIC_NAT_GREETING_SUBTITLE" '"No tools. It answers from memory."'
            (Get-Content "ui-model-only\package.json") -replace 'next dev -p 3099', 'next dev -p 3098' |
                Set-Content "ui-model-only\package.json" -Encoding UTF8
            Write-Ok "ui-model-only\.env -> bare model on :8002, browse :3001"
        }
    }
} else {
    Write-Warn "node/npm not found, skipping the browser UI. The CLI demo does not need it."
    Write-Warn "  install Node 18+ if you want the chat window: https://nodejs.org"
}

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
# Glob rather than a fixed list, so a newly added config cannot go unvalidated.
foreach ($cfg in (Get-ChildItem -Path "configs\*.yml" | ForEach-Object { $_.FullName })) {
    if ((Invoke-Native { & $venvNat validate --config_file $cfg }) -eq 0) { Write-Ok $cfg }
    else { Write-Fail "$cfg did not validate. See the error with:`n         .venv\Scripts\nat.exe validate --config_file $cfg" }
}

Write-Host @"

Ready. The main demo is one command:

  .\.venv\Scripts\Activate.ps1
  nat run --config_file configs\chain.yml --input "In which year did Computerworld publish its final print issue? Ask the researcher."

Act two, the same agents split over A2A, needs two terminals:

  # terminal 1
  nat start a2a --config_file configs\researcher.yml

  # terminal 2
  nat run --config_file configs\planner.yml --input "Which company makes the H100, and when was it announced? Use the researcher."

Then open http://localhost:6006 and pick the a2a-demo project.
"@
