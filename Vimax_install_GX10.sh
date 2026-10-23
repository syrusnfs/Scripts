#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/HKUDS/ViMax.git"
INSTALL_DIR="${VIMAX_INSTALL_DIR:-$HOME/ViMax}"
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
UNSLOTH_BASE_URL="${UNSLOTH_BASE_URL:-http://127.0.0.1:8888/v1}"
WEB_PORT="${VIMAX_WEB_PORT:-4173}"
WEB_HOST="0.0.0.0"
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] && (( WEB_PORT >= 1 && WEB_PORT <= 65535 )) || { echo "Invalid VIMAX_WEB_PORT" >&2; exit 1; }

log() { printf '\033[1;36m[ViMax]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
  fail "Run this installer as your regular Ubuntu user (sudo will be requested for apt)."
fi
[[ "$(uname -s)" == Linux ]] || fail "Linux is required."
if [[ "$(uname -m)" != aarch64 ]]; then
  warn "This installer is optimized for ARM64/GB10; detected $(uname -m)."
fi
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || warn "Designed for Ubuntu; detected ${ID:-unknown}."
fi
command -v sudo >/dev/null || fail "sudo is required for installing system packages."
command -v apt-get >/dev/null || fail "apt-get is required."

log "Installing basic system dependencies (no changes to Docker/ComfyUI)."
log "Keeping NodeSource Node.js and bundled npm; avoiding Ubuntu npm conflict."
sudo apt-get update
sudo apt-get install -y git curl ca-certificates build-essential pkg-config python3 python3-venv ffmpeg

# NodeSource Node.js bundles npm. Installing Ubuntu's separate npm package
# alongside NodeSource nodejs causes an apt dependency conflict.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  log "Checking Node.js/npm availability."
  if command -v node >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
    warn "Node.js exists but npm is missing. Checking the NodeSource package."
  fi
  if apt-cache policy nodejs 2>/dev/null | grep -q 'deb.nodesource.com'; then
    log "Installing NodeSource nodejs (npm is bundled; do not install Ubuntu npm)."
    sudo apt-get install -y nodejs
  else
    fail "Node.js/npm unavailable. Configure a supported Node.js repository, then rerun."
  fi
fi
command -v npm >/dev/null 2>&1 || fail "npm is missing. Check your Node.js installation."


export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv to the current user's home directory."
  curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh -o /tmp/vimax-uv-install.sh
  sh /tmp/vimax-uv-install.sh
  rm -f /tmp/vimax-uv-install.sh
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
command -v uv >/dev/null || fail "uv was not found after installation."

if ! command -v node >/dev/null 2>&1; then fail "Node.js not found."; fi
NODE_MAJOR="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
if [[ ! "$NODE_MAJOR" =~ ^[0-9]+$ ]] || (( NODE_MAJOR < 18 )); then
  fail "Node.js >=18 is required; installed: $(node --version). Upgrade Node.js and rerun."
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Existing ViMax checkout detected; preserving local changes and configuration."
  git -C "$INSTALL_DIR" fetch --prune origin
  if [[ -z "$(git -C "$INSTALL_DIR" status --porcelain)" ]]; then
    git -C "$INSTALL_DIR" pull --ff-only || warn "Could not fast-forward. Keeping current checkout."
  else
    warn "Local changes detected. Automatic git pull skipped."
  fi
elif [[ -e "$INSTALL_DIR" ]]; then
  fail "$INSTALL_DIR already exists but is not a git repository. Choose VIMAX_INSTALL_DIR."
else
  log "Cloning official ViMax repository."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
log "Installing Python environment with uv (isolated from ComfyUI)."
uv sync

[[ -f configs/agent.example.yaml ]] || fail "Missing configs/agent.example.yaml in this repository version."
if [[ ! -f configs/agent.local.yaml ]]; then
  cp configs/agent.example.yaml configs/agent.local.yaml
  log "Created configs/agent.local.yaml from the official example."
else
  log "Keeping existing configs/agent.local.yaml unchanged."
fi

if [[ -d web && -f web/package.json ]]; then
  log "Installing ViMax Web UI dependencies."
  (cd web && npm install --no-audit --no-fund)
else
  warn "Web UI directory not found. The TUI remains available."
fi

mkdir -p "$INSTALL_DIR/local-integration"
cat > "$INSTALL_DIR/local-integration/check_services.py" <<'PY'
#!/usr/bin/env python3
import json, os, urllib.request, urllib.error

def probe(name, url, key=''):
    headers = {'Authorization': f'Bearer {key}'} if key else {}
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            body = response.read(1024 * 1024)
            print(f'[OK] {name}: HTTP {response.status} ({url})')
            if name == 'Unsloth':
                try:
                    models = json.loads(body).get('data', [])
                    print('     Models:', ', '.join(str(m.get('id')) for m in models[:8]) or 'none listed')
                except (ValueError, AttributeError):
                    pass
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
        print(f'[NOT READY] {name}: {exc}')

base = os.environ.get('UNSLOTH_BASE_URL', 'http://127.0.0.1:8888/v1').rstrip('/')
comfy = os.environ.get('COMFY_URL', 'http://127.0.0.1:8188').rstrip('/')
probe('Unsloth', base + '/models', os.environ.get('UNSLOTH_API_KEY', ''))
probe('ComfyUI', comfy + '/system_stats')
PY

cat > "$INSTALL_DIR/local-integration/README.txt" <<'TXT'
ViMax + Unsloth + ComfyUI on NVIDIA GB10

1. Edit configs/agent.local.yaml and set:
   llm.model_provider: openai
   llm.model: the exact model ID served by Unsloth
   llm.base_url: your Unsloth OpenAI-compatible API URL (ending in /v1)
   llm.api_key: the API key required by your Unsloth server

2. Configure image and video providers in the same YAML according to ViMax docs.
   ComfyUI is NOT a native ViMax image/video provider in the official quickstart.
   A custom adapter is required to submit ComfyUI workflow API JSON, monitor
   execution, and retrieve the generated files.

3. ComfyUI already running on the host or in Docker is not modified.
   For a ComfyUI container exposed as 0.0.0.0:8188->8188, use:
   COMFY_URL=http://127.0.0.1:8188

4. Run ./vimax-check to verify both endpoints.
5. Run ./vimax-tui to open the ViMax agent.
6. The vimax-web systemd service starts automatically on 0.0.0.0:4173.
7. From another computer on the LAN open http://GB10_IP:4173

The Unsloth API key is not requested or stored by this installer.
TXT

cat > "$INSTALL_DIR/vimax-check" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export UNSLOTH_BASE_URL="${UNSLOTH_BASE_URL:-http://127.0.0.1:8888/v1}"
export COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
exec python3 "$ROOT/local-integration/check_services.py"
SH
cat > "$INSTALL_DIR/vimax-tui" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
exec uv run vimax tui "$@"
SH
cat > "$INSTALL_DIR/vimax-web" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/web"
export VIMAX_WEB_HOST="0.0.0.0"
export VIMAX_WEB_PORT="${VIMAX_WEB_PORT:-4173}"
export HOST="$VIMAX_WEB_HOST"
export HOSTNAME="$VIMAX_WEB_HOST"
export PORT="$VIMAX_WEB_PORT"
DEV_SCRIPT="$(node -e 'const p=require("./package.json");process.stdout.write(p.scripts?.dev||"")')"
if [[ "$DEV_SCRIPT" == *server.mjs* ]]; then
  exec npm run dev
elif [[ "$DEV_SCRIPT" == *next* ]]; then
  exec npm run dev -- --hostname "$VIMAX_WEB_HOST" --port "$VIMAX_WEB_PORT"
elif [[ "$DEV_SCRIPT" == *vite* || "$DEV_SCRIPT" == *astro* ]]; then
  exec npm run dev -- --host "$VIMAX_WEB_HOST" --port "$VIMAX_WEB_PORT"
else
  echo "[ViMax] Unknown Web UI launcher: $DEV_SCRIPT" >&2
  exit 1
fi
SH
chmod 700 "$INSTALL_DIR/vimax-check" "$INSTALL_DIR/vimax-tui" "$INSTALL_DIR/vimax-web"
chmod 600 "$INSTALL_DIR/configs/agent.local.yaml"

# Manage only the dedicated ViMax Web service; existing Docker services are untouched.
[[ -f "$INSTALL_DIR/web/package.json" ]] || fail "ViMax Web UI is missing; cannot create systemd service."
command -v systemctl >/dev/null 2>&1 || fail "systemd is required for service setup."
NODE_BIN="$(command -v node)"
NPM_BIN="$(command -v npm)"
SERVICE_NAME="vimax-web.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
log "Creating and enabling $SERVICE_NAME (0.0.0.0:$WEB_PORT)."
# Escape percent signs in systemd specifiers and avoid expanding user-controlled values.
SYSTEMD_USER="$(id -un)"
SYSTEMD_GROUP="$(id -gn)"
SYSTEMD_HOME="$HOME"
SERVICE_TMP="$(mktemp)"
cat > "$SERVICE_TMP" <<EOF
[Unit]
Description=ViMax Web UI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SYSTEMD_USER
Group=$SYSTEMD_GROUP
WorkingDirectory=$INSTALL_DIR/web
Environment=HOME=$SYSTEMD_HOME
Environment=PATH=$(dirname "$NODE_BIN"):$(dirname "$NPM_BIN"):/usr/local/bin:/usr/bin:/bin
Environment=VIMAX_WEB_HOST=$WEB_HOST
Environment=VIMAX_WEB_PORT=$WEB_PORT
ExecStart=$INSTALL_DIR/vimax-web
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "$SERVICE_TMP" "$SERVICE_FILE"
rm -f "$SERVICE_TMP"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
# Ensure rerunning the installer applies updated wrapper/config even if already active.
sudo systemctl restart "$SERVICE_NAME"
if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Service active: $SERVICE_NAME"
else
  warn "Service did not stay active. Inspect: sudo journalctl -u $SERVICE_NAME -n 80 --no-pager"
fi
# Confirm the actual bind address, not just systemd active state.
BIND_OK=false
for attempt in {1..15}; do
  if command -v ss >/dev/null 2>&1 && ss -H -ltn "( sport = :$WEB_PORT )" 2>/dev/null | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\[::\]|\*):$WEB_PORT$"; then
    BIND_OK=true
    break
  fi
  sleep 1
done
if [[ "$BIND_OK" == true ]]; then
  log "Verified ViMax Web UI is listening on 0.0.0.0:$WEB_PORT (or all IPv6 interfaces)."
else
  warn "Could not verify a public-interface listener on port $WEB_PORT."
  warn "Inspect: sudo ss -lntp '( sport = :$WEB_PORT )'"
  warn "Inspect: sudo journalctl -u $SERVICE_NAME -n 80 --no-pager"
fi
log "Web UI URL: http://GB10_IP:$WEB_PORT (LAN access requires firewall permission)."

log "Installation completed."
printf '\nDirectory: %s\nComfyUI URL (check only): %s\nUnsloth API URL (check only): %s\n\n' "$INSTALL_DIR" "$COMFY_URL" "$UNSLOTH_BASE_URL"
printf 'Next steps:\n  cd %q\n  nano configs/agent.local.yaml\n  ./vimax-check\n  ./vimax-tui\n  sudo systemctl status vimax-web --no-pager\n\n' "$INSTALL_DIR"
warn "ComfyUI workflow automation is not installed yet: it requires your workflow API JSON and a provider adapter."
