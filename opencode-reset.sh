#!/usr/bin/env bash
# ==============================================================================
# OpenCode Reset & Token Sync Script
# ==============================================================================
# Usage:
#   opencode-reset [NEW_TOKEN] [PROVIDER]
#   opencode-reset                     (Interactive / auto-sync auth.json & .env)
#   opencode-reset --sync              (Non-interactive sync from auth.json/.env)
#   opencode-reset --status            (Show current service & token status)
#   opencode-reset --restart           (Restart service & sync auth.json -> DB)
#   opencode-reset --install           (Symlink to ~/.local/bin/opencode-reset)
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# File paths
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
AUTH_FILE="$SHARE_DIR/auth.json"
DB_FILE="$SHARE_DIR/opencode.db"
ENV_FILE="$CONFIG_DIR/.env"
TUI_FILE="$CONFIG_DIR/tui.json"
FAILOVER_STATE="$CONFIG_DIR/failover-state.json"

OPENCODE_BIN=$(command -v opencode 2>/dev/null || echo "$HOME/.opencode/bin/opencode")
if [[ ! -x "$OPENCODE_BIN" ]]; then
  echo -e "${RED}[ERROR]${NC} OpenCode binary not found at $OPENCODE_BIN" >&2
  exit 1
fi

PYTHON_BIN=$(command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON_BIN" ]]; then
  echo -e "${RED}[ERROR]${NC} python3 is required." >&2
  exit 1
fi

mask_token() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "(none)"
  elif [[ ${#token} -le 12 ]]; then
    echo "******"
  else
    echo "${token:0:8}...${token: -4}"
  fi
}

print_header() {
  echo -e "${CYAN}${BOLD}=====================================================${NC}"
  echo -e "${CYAN}${BOLD}       OpenCode Token & Service Reset Manager        ${NC}"
  echo -e "${CYAN}${BOLD}=====================================================${NC}"
}

# Returns: DB_TOKEN|AUTH_TOKEN|ENV_TOKEN
detect_tokens() {
  local provider="${1:-opencode}"
  DB_FILE="$DB_FILE" AUTH_FILE="$AUTH_FILE" ENV_FILE="$ENV_FILE" PROVIDER="$provider" \
  "$PYTHON_BIN" - <<'EOF'
import sqlite3, json, os, re

db_path = os.environ["DB_FILE"]
auth_path = os.environ["AUTH_FILE"]
env_path = os.environ["ENV_FILE"]
provider = os.environ["PROVIDER"]

db_token = ""
auth_token = ""
env_token = ""

if os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5.0)
        cur = conn.cursor()
        cur.execute(
            "SELECT value FROM credential WHERE integration_id = ? AND active = 1 ORDER BY time_updated DESC LIMIT 1",
            (provider,),
        )
        row = cur.fetchone()
        if row:
            db_token = json.loads(row[0]).get("key", "")
        conn.close()
    except Exception:
        pass

if os.path.exists(auth_path):
    try:
        with open(auth_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            entry = data.get(provider, {})
            if isinstance(entry, dict):
                auth_token = entry.get("key", "")
    except Exception:
        pass

if os.path.exists(env_path):
    try:
        up = re.sub(r"[^a-zA-Z0-9]", "_", provider).upper()
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                t = line.strip()
                if t.startswith(f"{up}_API_KEY="):
                    env_token = t.split("=", 1)[1].strip().strip('"').strip("'")
                    break
                elif t.startswith(f"{up}_API_KEYS="):
                    raw = t.split("=", 1)[1].strip().strip('"').strip("'")
                    parts = [k.strip() for k in raw.split(",") if k.strip()]
                    if parts:
                        env_token = parts[0]
    except Exception:
        pass

print(f"{db_token}|{auth_token}|{env_token}")
EOF
}

show_status() {
  print_header
  echo -e "${BLUE}▶ OpenCode Binary:${NC} $OPENCODE_BIN"

  local service_status
  service_status=$("$OPENCODE_BIN" service status 2>&1 || true)
  if [[ "$service_status" =~ ^http://.* ]]; then
    echo -e "${GREEN}▶ Service Status:${NC} RUNNING (${service_status})"
  else
    echo -e "${YELLOW}▶ Service Status:${NC} STOPPED"
  fi

  echo -e "\n${BOLD}Stored Credentials in Database:${NC}"
  DB_FILE="$DB_FILE" AUTH_FILE="$AUTH_FILE" "$PYTHON_BIN" - <<'EOF'
import sqlite3, json, os

db_path = os.environ["DB_FILE"]
auth_path = os.environ["AUTH_FILE"]

if not os.path.exists(db_path):
    print(f"  Database not found at {db_path}")
    raise SystemExit(0)

auth_data = {}
if os.path.exists(auth_path):
    try:
        with open(auth_path, "r", encoding="utf-8") as f:
            auth_data = json.load(f)
    except Exception:
        pass

try:
    conn = sqlite3.connect(db_path, timeout=5.0)
    cur = conn.cursor()
    cur.execute("SELECT integration_id, label, value, active FROM credential ORDER BY integration_id, active DESC")
    rows = cur.fetchall()
    conn.close()
    for prov, label, val, act in rows:
        try:
            key = json.loads(val).get("key", "")
            masked = key[:8] + "..." + key[-4:] if len(key) > 12 else ("******" if key else "(oauth/ext)")
        except Exception:
            key = ""
            masked = "***"
        status = "\033[0;32m[ACTIVE]\033[0m  " if act == 1 else "\033[0;37m[inactive]\033[0m"
        sync_note = ""
        if act == 1 and isinstance(auth_data.get(prov), dict):
            ak = auth_data[prov].get("key", "")
            if ak and key and ak != key:
                sync_note = " \033[1;33m(differs from auth.json!)\033[0m"
        print(f"  {status} {prov:12} | {label:18} | {masked}{sync_note}")
except Exception as e:
    print(f"  Error reading database: {e}")
EOF
}

install_symlink() {
  local target_dir="$HOME/.local/bin"
  mkdir -p "$target_dir"
  local script_path
  script_path=$("$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")
  ln -sf "$script_path" "$target_dir/opencode-reset"
  echo -e "${GREEN}[OK]${NC} Symlinked $script_path -> $target_dir/opencode-reset"
}

ARG1="${1:-}"

case "$ARG1" in
  --status|-s)
    show_status
    exit 0
    ;;
  --install)
    install_symlink
    exit 0
    ;;
  --help|-h)
    echo "Usage:"
    echo "  opencode-reset [TOKEN] [PROVIDER]   Set new token for provider (default: opencode) & reset"
    echo "  opencode-reset                      Interactive prompt (detects auth.json / DB changes)"
    echo "  opencode-reset --sync               Non-interactive sync from auth.json & restart"
    echo "  opencode-reset --restart            Sync auth.json -> DB and restart service"
    echo "  opencode-reset --status             Show service and credential status"
    echo "  opencode-reset --install            Install symlink to ~/.local/bin/opencode-reset"
    exit 0
    ;;
esac

NON_INTERACTIVE=false
if [[ "$ARG1" == "--restart" || "$ARG1" == "-r" || "$ARG1" == "--sync" ]]; then
  NON_INTERACTIVE=true
  shift
fi

PROVIDER="${2:-opencode}"
if [[ "$NON_INTERACTIVE" == true && -n "${1:-}" ]]; then
  PROVIDER="$1"
fi

IFS='|' read -r DB_TOKEN AUTH_TOKEN ENV_TOKEN < <(detect_tokens "$PROVIDER")

# Prefer auth.json if it was edited and differs from DB, otherwise fallback to DB -> ENV
DEFAULT_TOKEN="${AUTH_TOKEN:-${DB_TOKEN:-$ENV_TOKEN}}"
NEW_TOKEN=""

print_header

if [[ "$NON_INTERACTIVE" == false && -n "${1:-}" ]]; then
  NEW_TOKEN="$1"
elif [[ "$NON_INTERACTIVE" == false && -t 0 ]]; then
  echo -e "Provider:          ${BOLD}${PROVIDER}${NC}"
  echo -e "DB active token:   ${CYAN}$(mask_token "$DB_TOKEN")${NC}"
  if [[ -n "$AUTH_TOKEN" && "$AUTH_TOKEN" != "$DB_TOKEN" ]]; then
    echo -e "auth.json token:   ${YELLOW}$(mask_token "$AUTH_TOKEN") (unsynced edit detected!)${NC}"
  fi
  echo -ne "Enter new token (Enter to sync/keep ${BOLD}$(mask_token "$DEFAULT_TOKEN")${NC}): "
  read -r user_input
  NEW_TOKEN="${user_input:-$DEFAULT_TOKEN}"
else
  NEW_TOKEN="$DEFAULT_TOKEN"
fi

# ------------------------------------------------------------------------------
# STEP 1: Stop OpenCode Background Service
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/5] Stopping OpenCode background service...${NC}"
"$OPENCODE_BIN" service stop >/dev/null 2>&1 || true

for _ in {1..3}; do
  pgrep -f "opencode serve" >/dev/null 2>&1 || break
  sleep 1
done

if pgrep -f "opencode serve" >/dev/null 2>&1; then
  pkill -9 -f "opencode serve" 2>/dev/null || true
  sleep 1
fi
echo -e "  ${GREEN}✓${NC} Service stopped."

# ------------------------------------------------------------------------------
# STEP 2: Sync Credentials (auth.json <-> opencode.db <-> .env)
# ------------------------------------------------------------------------------
if [[ -n "$NEW_TOKEN" ]]; then
  echo -e "${BLUE}[2/5] Syncing credentials for '${PROVIDER}'...${NC}"
  DB_FILE="$DB_FILE" AUTH_FILE="$AUTH_FILE" ENV_FILE="$ENV_FILE" \
  PROVIDER="$PROVIDER" NEW_TOKEN="$NEW_TOKEN" "$PYTHON_BIN" - <<'EOF'
import sqlite3, json, time, os, re

db_path = os.environ["DB_FILE"]
auth_path = os.environ["AUTH_FILE"]
env_path = os.environ["ENV_FILE"]
provider = os.environ["PROVIDER"].strip().lower()
new_token = os.environ["NEW_TOKEN"].strip()
now = int(time.time() * 1000)

# 1. Update auth.json atomically
auth_data = {}
if os.path.exists(auth_path):
    try:
        with open(auth_path, "r", encoding="utf-8") as f:
            auth_data = json.load(f)
    except Exception:
        auth_data = {}

entry = auth_data.get(provider)
if not isinstance(entry, dict):
    entry = {"type": "api"}
entry["key"] = new_token
entry.setdefault("type", "api")
auth_data[provider] = entry

os.makedirs(os.path.dirname(auth_path), exist_ok=True)
tmp_auth = f"{auth_path}.{os.getpid()}.tmp"
with open(tmp_auth, "w", encoding="utf-8") as f:
    json.dump(auth_data, f, indent=2)
os.chmod(tmp_auth, 0o600)
os.replace(tmp_auth, auth_path)

# 2. Update SQLite opencode.db
def sync_provider_to_db(cur, prov_id, token_str):
    cur.execute("SELECT id, value, active FROM credential WHERE integration_id = ?", (prov_id,))
    rows = cur.fetchall()

    matching_id = None
    key_rows = []
    for r_id, r_val, r_act in rows:
        try:
            parsed = json.loads(r_val)
            if parsed.get("type") in (None, "key", "api"):
                key_rows.append((r_id, r_val, r_act))
                if parsed.get("key") == token_str:
                    matching_id = r_id
        except Exception:
            pass

    val_json = json.dumps({"type": "key", "key": token_str})
    cur.execute("UPDATE credential SET active = 0 WHERE integration_id = ?", (prov_id,))

    if matching_id:
        cur.execute("UPDATE credential SET value = ?, active = 1, time_updated = ? WHERE id = ?", (val_json, now, matching_id))
    elif key_rows:
        target = next((r for r in key_rows if r[2] == 1), key_rows[0])
        cur.execute("UPDATE credential SET value = ?, active = 1, time_updated = ? WHERE id = ?", (val_json, now, target[0]))
    elif not rows:
        new_id = f"cred_{hex(now)[2:]}{os.urandom(6).hex()}"
        label = "OpenCode Console" if prov_id == "opencode" else "API key"
        cur.execute(
            "INSERT INTO credential (id, integration_id, label, value, connector_id, method_id, active, time_created, time_updated) VALUES (?, ?, ?, ?, NULL, NULL, 1, ?, ?)",
            (new_id, prov_id, label, val_json, now, now),
        )

if os.path.exists(db_path):
    conn = sqlite3.connect(db_path, timeout=10.0)
    cur = conn.cursor()
    sync_provider_to_db(cur, provider, new_token)

    for prov_key, prov_val in auth_data.items():
        if prov_key == provider or not isinstance(prov_val, dict):
            continue
        k = prov_val.get("key")
        if k and isinstance(k, str):
            sync_provider_to_db(cur, prov_key, k.strip())

    conn.commit()
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    conn.close()

# 3. Update .env atomically if present
if os.path.exists(env_path):
    try:
        with open(env_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        up = re.sub(r"[^a-zA-Z0-9]", "_", provider).upper()
        prefix_multi = f"{up}_API_KEYS="
        prefix_single = f"{up}_API_KEY="
        new_lines = []

        for line in lines:
            trimmed = line.strip()
            if trimmed.startswith(prefix_single):
                new_lines.append(f'{prefix_single}"{new_token}"\n')
            elif trimmed.startswith(prefix_multi):
                val = trimmed[len(prefix_multi):].strip().strip('"').strip("'")
                keys = [k.strip() for k in val.split(",") if k.strip() and k.strip() != new_token]
                new_lines.append(f'{prefix_multi}"{",".join([new_token] + keys)}"\n')
            elif trimmed.startswith("OPENCODE_FAILOVER_KEYS="):
                try:
                    raw_json = trimmed[len("OPENCODE_FAILOVER_KEYS="):].strip().strip('"').strip("'")
                    fo = json.loads(raw_json)
                    if provider in fo and isinstance(fo[provider], list):
                        fo[provider] = [new_token] + [k for k in fo[provider] if k != new_token]
                        new_lines.append(f"OPENCODE_FAILOVER_KEYS={json.dumps(fo)}\n")
                        continue
                except Exception:
                    pass
                new_lines.append(line)
            else:
                new_lines.append(line)

        tmp_env = f"{env_path}.{os.getpid()}.tmp"
        with open(tmp_env, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        os.replace(tmp_env, env_path)
    except Exception:
        pass
EOF
  echo -e "  ${GREEN}✓${NC} Database, auth.json, and .env synced."
else
  echo -e "${YELLOW}[2/5] No token found to sync; continuing with reset...${NC}"
fi

# ------------------------------------------------------------------------------
# STEP 3: Cleanup Broken Failover & Stale Cache State
# ------------------------------------------------------------------------------
echo -e "${BLUE}[3/5] Cleaning up stale failover state...${NC}"
if [[ -f "$FAILOVER_STATE" ]]; then
  rm -f "$FAILOVER_STATE"
  echo -e "  ${GREEN}✓${NC} Removed failover-state.json"
fi

if [[ -f "$TUI_FILE" ]]; then
  TUI_FILE="$TUI_FILE" CONFIG_DIR="$CONFIG_DIR" "$PYTHON_BIN" - <<'EOF'
import json, os

tui_file = os.environ["TUI_FILE"]
config_dir = os.environ["CONFIG_DIR"]
try:
    with open(tui_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    plugins = data.get("plugin", [])
    if isinstance(plugins, list):
        filtered = [
            p for p in plugins
            if not (p == "./plugins/tui.tsx" and not os.path.exists(os.path.join(config_dir, "plugins", "tui.tsx")))
        ]
        if len(filtered) != len(plugins):
            data["plugin"] = filtered
            with open(tui_file, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            print("  \033[0;32m✓\033[0m Removed broken ./plugins/tui.tsx from tui.json")
except Exception:
    pass
EOF
fi

# ------------------------------------------------------------------------------
# STEP 4: Start OpenCode Background Service
# ------------------------------------------------------------------------------
echo -e "${BLUE}[4/5] Starting OpenCode background service...${NC}"
"$OPENCODE_BIN" service start >/dev/null 2>&1 || true

SERVICE_URL=""
for _ in {1..6}; do
  STATUS_OUT=$("$OPENCODE_BIN" service status 2>&1 || true)
  if [[ "$STATUS_OUT" =~ ^http://.* ]]; then
    SERVICE_URL="$STATUS_OUT"
    break
  fi
  sleep 1
done

if [[ -z "$SERVICE_URL" ]]; then
  if pgrep -f "opencode serve" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Service process running."
  else
    echo -e "  ${RED}✗ Failed to start service. Run: opencode service start${NC}" >&2
    exit 1
  fi
else
  echo -e "  ${GREEN}✓${NC} Service online: ${BOLD}${SERVICE_URL}${NC}"
fi

"$OPENCODE_BIN" reload >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# STEP 5: Verification & Summary
# ------------------------------------------------------------------------------
echo -e "${BLUE}[5/5] Verifying active credentials...${NC}"
IFS='|' read -r FINAL_DB_TOKEN _ _ < <(detect_tokens "$PROVIDER")

echo -e "\n${GREEN}${BOLD}✔ Reset Completed!${NC}"
echo -e "  • Provider:     ${BOLD}${PROVIDER}${NC}"
echo -e "  • Active Token: ${CYAN}$(mask_token "$FINAL_DB_TOKEN")${NC}"
[[ -n "$SERVICE_URL" ]] && echo -e "  • Service URL:  ${BOLD}${SERVICE_URL}${NC}"
