#!/usr/bin/env bash
# Setup for Ubuntu / Debian / WSL2.
# Usage:  bash scripts/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAT_VERSION="1.8.0"

# nat's CLI prints U+2713 / U+2717 status glyphs. Under a non-UTF-8 locale
# (LANG=C, minimal containers) that raises UnicodeEncodeError inside click and
# nat exits 1 even when the config is valid.
export PYTHONIOENCODING=utf-8

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

# Two compatibility shims the demo cannot run without. See plugin/ for the why.
pip install --quiet -e ./plugin
ok "nat-demo-shims (a2a_client_shared + wikipedia user-agent)"

# --- Browser UI -----------------------------------------------------------
# The chat UI is a separate NVIDIA project, not part of nvidia-nat, so it has to be
# fetched. Two instances are set up: one pointed at the planner (:8001) and one at the
# bare model (:8002), because a UI instance talks to exactly one backend and Scene 1 of
# the demo needs both on screen. See docs/ui.md.
#
# Skipped, with a warning, if node is missing -- the CLI demo does not need any of this.
UI_REPO="https://github.com/NVIDIA/NeMo-Agent-Toolkit-UI.git"

# Replace KEY=... in an env file, or append it if absent. Idempotent, so re-running the
# script does not accumulate duplicate keys or re-patch an already-patched value.
set_env_key() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    local tmp; tmp="$(mktemp)"
    grep -vE "^${key}=" "$file" > "$tmp" && printf '%s=%s\n' "$key" "$value" >> "$tmp" && mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

echo
echo "Browser UI"
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  if [ ! -d ui/.git ]; then
    if git clone --depth 1 "$UI_REPO" ui >/dev/null 2>&1; then
      ok "cloned NeMo-Agent-Toolkit-UI"
    else
      warn "could not clone $UI_REPO -- check your network, or clone it into ./ui yourself"
    fi
  else
    ok "reusing ./ui"
  fi

  if [ -d ui ]; then
    if [ ! -d ui/node_modules ]; then
      (cd ui && npm ci --no-audit --no-fund >/dev/null 2>&1) \
        && ok "npm ci (about 1100 packages)" || warn "npm ci failed in ./ui"
    else
      ok "ui/node_modules present"
    fi

    # instance 1: the planner
    if [ -f ui/.env ]; then
      set_env_key ui/.env NAT_BACKEND_URL "http://127.0.0.1:8001"
      set_env_key ui/.env PORT "3000"
      set_env_key ui/.env NEXT_INTERNAL_URL "http://localhost:3099"
      # this one is why the remote agent's reasoning shows up in the chat window
      set_env_key ui/.env NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS "true"
      set_env_key ui/.env NEXT_PUBLIC_NAT_WORKFLOW "Planner"
      set_env_key ui/.env NEXT_PUBLIC_NAT_GREETING_TITLE '"Ask the planner"'
      set_env_key ui/.env NEXT_PUBLIC_NAT_GREETING_SUBTITLE '"It will delegate anything factual to the researcher."'
      ok "ui/.env -> planner on :8001, browse :3000"
    else
      warn "ui/.env not found; the upstream layout may have changed"
    fi

    # instance 2: the bare model, for Scene 1. node_modules is symlinked rather than
    # installed twice; the internal Next port must differ or the two dev servers fight.
    if [ -d ui/node_modules ]; then
      rm -rf ui-model-only
      mkdir -p ui-model-only
      (cd ui && tar cf - --exclude=node_modules --exclude=.next --exclude=.git .) \
        | (cd ui-model-only && tar xf -)
      ln -sfn "$REPO_ROOT/ui/node_modules" ui-model-only/node_modules
      set_env_key ui-model-only/.env NAT_BACKEND_URL "http://127.0.0.1:8002"
      set_env_key ui-model-only/.env PORT "3001"
      set_env_key ui-model-only/.env NEXT_INTERNAL_URL "http://localhost:3098"
      set_env_key ui-model-only/.env NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS "false"
      set_env_key ui-model-only/.env NEXT_PUBLIC_NAT_WORKFLOW "Model only"
      set_env_key ui-model-only/.env NEXT_PUBLIC_NAT_GREETING_TITLE '"Ask the model"'
      set_env_key ui-model-only/.env NEXT_PUBLIC_NAT_GREETING_SUBTITLE '"No tools. It answers from memory."'
      sed -i 's/next dev -p 3099/next dev -p 3098/' ui-model-only/package.json
      ok "ui-model-only/.env -> bare model on :8002, browse :3001"
    fi
  fi
else
  warn "node/npm not found, skipping the browser UI. The CLI demo does not need it."
  warn "  install Node 18+ if you want the chat window: https://nodejs.org"
fi

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
# Glob rather than a fixed list: the repo has grown from three configs to five, and a
# new one silently going unvalidated is exactly the kind of thing this script is for.
export NVIDIA_API_KEY="${NVIDIA_API_KEY:-nvapi-placeholder}"
for cfg in configs/*.yml; do
  nat validate --config_file "$cfg" >/dev/null 2>&1 \
    && ok "$cfg" || fail "$cfg did not validate"
done

cat <<'EOF'

Ready. The main demo is one command:

  source .venv/bin/activate
  nat run --config_file configs/chain.yml \
    --input "In which year did Computerworld publish its final print issue? Ask the researcher."

Act two, the same agents split over A2A, needs two terminals:

  # terminal 1
  nat start a2a --config_file configs/researcher.yml

  # terminal 2
  nat run --config_file configs/planner.yml \
    --input "Which company makes the H100, and when was it announced? Use the researcher."

Then open http://localhost:6006 and pick the a2a-demo project.
EOF
