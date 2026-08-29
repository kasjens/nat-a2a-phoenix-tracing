#!/usr/bin/env bash
# Setup for Ubuntu / Debian / WSL2.
# Usage:  bash scripts/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAT_VERSION="1.8.0"
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mfail\033[0m %s\n' "$1"; exit 1; }

echo
echo "NAT + A2A + Phoenix demo setup"
echo "=============================="
echo
echo "Preflight"

# --- Python ---------------------------------------------------------------
PY=""
for candidate in python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    ver=$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    major=${ver%%.*}; minor=${ver##*.}
    if [ "$major" -eq 3 ] && [ "$minor" -ge 11 ]; then PY="$candidate"; break; fi
  fi
done
[ -n "$PY" ] || fail "Python 3.11+ not found. sudo apt install python3.12 python3.12-venv"
ok "python: $PY ($("$PY" -c 'import sys; print(sys.version.split()[0])'))"

if ! "$PY" -c "import venv" >/dev/null 2>&1; then
  fail "python venv module missing. sudo apt install python3-venv"
fi

# --- Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker: running"
  else
    warn "docker installed but not reachable. Start it, or add yourself to the docker group."
  fi
else
  warn "docker not found. Phoenix will not start. See https://docs.docker.com/engine/install/ubuntu/"
fi

# --- API key --------------------------------------------------------------
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  ok ".env loaded"
fi
if [ -n "${NVIDIA_API_KEY:-}" ]; then
  ok "NVIDIA_API_KEY set (${NVIDIA_API_KEY:0:8}...)"
else
  warn "NVIDIA_API_KEY not set. Get one at https://build.nvidia.com, then:"
  warn "  cp .env.example .env  and put the key in it"
fi

# --- Install --------------------------------------------------------------
echo
echo "Installing"
if [ ! -d .venv ]; then
  "$PY" -m venv .venv
  ok "created .venv"
else
  ok "reusing .venv"
fi

# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip --quiet
pip install --quiet "nvidia-nat[phoenix,langchain,a2a]==${NAT_VERSION}"
ok "nvidia-nat ${NAT_VERSION} + phoenix, langchain, a2a"

# --- Phoenix --------------------------------------------------------------
echo
echo "Phoenix"
if docker info >/dev/null 2>&1; then
  docker compose up -d
  for _ in $(seq 1 30); do
    if curl -fs http://localhost:6006 >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if curl -fs http://localhost:6006 >/dev/null 2>&1; then
    ok "Phoenix up at http://localhost:6006"
  else
    warn "Phoenix container started but the UI is not answering yet. Give it a moment."
  fi
else
  warn "skipped, docker unavailable"
fi

# --- Validate -------------------------------------------------------------
echo
echo "Validating configs"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-nvapi-placeholder}" \
  nat validate --config_file configs/researcher.yml >/dev/null 2>&1 \
  && ok "configs/researcher.yml" || fail "configs/researcher.yml did not validate"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-nvapi-placeholder}" \
  nat validate --config_file configs/planner.yml >/dev/null 2>&1 \
  && ok "configs/planner.yml" || fail "configs/planner.yml did not validate"

cat <<'EOF'

Ready. Two terminals:

  # terminal 1
  source .venv/bin/activate
  nat start --config_file configs/researcher.yml

  # terminal 2
  source .venv/bin/activate
  nat run --config_file configs/planner.yml \
    --input "Which company makes the H100, and when was it announced? Use the researcher."

Then open http://localhost:6006 and pick the a2a-demo project.
EOF
