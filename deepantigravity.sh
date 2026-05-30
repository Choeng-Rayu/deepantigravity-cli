#!/usr/bin/env bash
# deepantigravity — Use Google's Antigravity CLI (`agy`) with cheaper LLM backends
#
# DESIGN GOAL: when this launcher is NOT running, `agy` works completely
# normally (real Google Gemini). When it IS running, `agy` is transparently
# routed through our local proxy to a different backend.
#
# Why /etc/hosts edits per-launch?
#   `agy` is a Go binary that bypasses HTTPS_PROXY (verified by strace)
#   AND bypasses LD_PRELOAD libc hooks (verified — Go uses raw syscalls).
#   The only interception that works is /etc/hosts redirection. So we add
#   the redirect only DURING our session and remove it on exit.
#
#   The helper script + sudoers rule installed by `--setup` allow the
#   add/remove without a password prompt, so day-to-day use needs no sudo.
#
# Usage:
#   deepantigravity --setup                         # one-time root setup
#   deepantigravity [-b kimi|nv] [-- agy-args]
#   deepantigravity --teardown                      # full uninstall
#   deepantigravity --status                        # diagnostic

set -euo pipefail

# ── Resolve symlinks ──
_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_SOURCE" ]]; do
    _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
    _SOURCE="$(readlink "$_SOURCE")"
    [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
unset _SOURCE _DIR

# ── OS detection ──
# macOS lacks bwrap / setcap / getcap / getent / fuser / flock, so it
# uses a different launch path (single shared proxy on 127.0.0.1:443,
# run via sudo). Linux keeps the bwrap-per-backend path.
case "$(uname -s)" in
    Darwin) DAG_OS="macos" ;;
    Linux)  DAG_OS="linux" ;;
    *)      DAG_OS="linux" ;;
esac

HELPER_INSTALLED="/usr/local/bin/deepantigravity-helper"
HELPER_SOURCE="$SCRIPT_DIR/proxy/deepantigravity-helper.sh"
SUDOERS_FILE="/etc/sudoers.d/deepantigravity"

# ── Load .env ──
ENV_FILE="$SCRIPT_DIR/proxy/.env"
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        if [[ -z "${!key:-}" ]]; then
            export "$line"
        fi
    done < "$ENV_FILE"
fi

# ── Defaults ──
DEEPANTIGRAVITY_PORT="${DEEPANTIGRAVITY_PORT:-443}"
DEFAULT_BACKEND="${API_PROVIDER:-kimi}"
BACKEND="$DEFAULT_BACKEND"
ACTION="launch"
# ── Shared-session state ──
# Each backend can have its own running proxy bound to a unique loopback
# IP. Multiple terminals using the SAME backend share that backend's
# proxy (refcounted). DIFFERENT backends run in parallel because each
# session uses a `bwrap` mount-namespace to give itself a custom
# /etc/hosts pointing cloudcode-pa.googleapis.com at its backend's IP.
# State lives under:
#   proxy/.cache/sessions/<backend>/
#     ├─ lock         flock target for atomic operations
#     ├─ proxy.pid    PID of the detached proxy (cleaned up by last-out)
#     ├─ proxy.log    proxy stdout+stderr
#     └─ members/     one empty file named <PID> per active session
SESSIONS_ROOT="$SCRIPT_DIR/proxy/.cache/sessions"
CA_BUNDLE_PATH="$SCRIPT_DIR/proxy/.cache/ca-bundle.pem"
JOINED_BACKEND=""    # set to backend name once we register as a member
TMP_HOSTS_FILE=""    # per-session /etc/hosts file, bind-mounted by bwrap

# ── macOS shared-session state (single global proxy on 127.0.0.1:443) ──
# macOS can't isolate /etc/hosts per process, so all terminals share one
# proxy and one backend. State lives in proxy/.cache/macos-session/.
MAC_SESSION_DIR="$SCRIPT_DIR/proxy/.cache/macos-session"
MAC_LOCK="$MAC_SESSION_DIR/lock"
MAC_PID_FILE="$MAC_SESSION_DIR/proxy.pid"
MAC_BACKEND_FILE="$MAC_SESSION_DIR/backend"
MAC_LOG_FILE="$MAC_SESSION_DIR/proxy.log"
MAC_MEMBERS_DIR="$MAC_SESSION_DIR/members"
MAC_JOINED=0         # 1 once this PID is a registered member

# ── Parse args ──
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend|-b) BACKEND="$2"; shift 2 ;;
        --setup)      ACTION="setup"; shift ;;
        --teardown)   ACTION="teardown"; shift ;;
        --status)     ACTION="status"; shift ;;
        --cost)       ACTION="cost"; shift ;;
        --ca-path)    ACTION="ca-path"; shift ;;
        --install-ca) ACTION="install-ca"; shift ;;
        --help|-h)    ACTION="help"; shift ;;
        --)           shift; PASS_ARGS+=("$@"); break ;;
        *)            PASS_ARGS+=("$1"); shift ;;
    esac
done

mask_key() {
    local k="$1"
    if [[ -z "$k" ]]; then echo "MISSING"; else echo "set (****${k: -4})"; fi
}

real_node() {
    local n
    n="$(command -v node 2>/dev/null)" || return 1
    # Linux: resolve symlinks with readlink -f. macOS (BSD readlink) has
    # no -f, and we don't need a fully-resolved path there anyway.
    if [[ "$DAG_OS" == "macos" ]]; then
        echo "$n"
    else
        readlink -f "$n"
    fi
}

helper_installed() {
    [[ -x "$HELPER_INSTALLED" ]]
}

sudoers_installed() {
    [[ -f "$SUDOERS_FILE" ]]
}

node_has_bind_cap() {
    local node_bin
    node_bin="$(real_node)" || return 1
    getcap "$node_bin" 2>/dev/null | grep -q cap_net_bind_service
}

hosts_present() {
    grep -qF "# >>> deepantigravity BEGIN <<<" /etc/hosts 2>/dev/null
}

# Count alive members in $SESSION_MEMBERS, garbage-collecting any whose
# PID is dead (e.g. SIGKILL'd sessions that couldn't run their trap).
# ── Per-backend session helpers ──
# Each backend gets a unique loopback IP. agy inside its bwrap mount-ns
# resolves cloudcode-pa.googleapis.com to this IP via a custom /etc/hosts.
backend_ip() {
    case "$1" in
        kimi)   echo "127.0.10.1" ;;
        deepseekOauthWeb) echo "127.0.30.1" ;;  # Unique IP for deepseekOauthWeb
        nvidia) echo "127.0.20.1" ;;
        *)      echo "127.0.0.1" ;;
    esac
}
backend_dir()      { echo "$SESSIONS_ROOT/$1"; }
backend_lock()     { echo "$SESSIONS_ROOT/$1/lock"; }
backend_pid_file() { echo "$SESSIONS_ROOT/$1/proxy.pid"; }
backend_log_file() { echo "$SESSIONS_ROOT/$1/proxy.log"; }
backend_members()  { echo "$SESSIONS_ROOT/$1/members"; }

# Echoes count of alive member-PIDs for this backend, GCing dead ones.
backend_active_count() {
    local backend="$1"
    local mdir; mdir="$(backend_members "$backend")"
    local count=0
    if [[ -d "$mdir" ]]; then
        for f in "$mdir"/*; do
            [[ -e "$f" ]] || continue
            local pid; pid="$(basename "$f")"
            if kill -0 "$pid" 2>/dev/null; then
                count=$((count + 1))
            else
                rm -f "$f"
            fi
        done
    fi
    echo "$count"
}

# Echoes list of all backends with a session directory present.
backend_active_list() {
    [[ -d "$SESSIONS_ROOT" ]] || return 0
    for d in "$SESSIONS_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done
}

# Atomically (under that backend's flock) remove our member file. If
# we're the last member, kill the proxy and remove the backend's dir.
backend_session_leave() {
    local backend="$1"
    [[ -n "$backend" ]] || return 0
    local bdir; bdir="$(backend_dir "$backend")"
    [[ -d "$bdir" ]] || return 0
    {
        if ! flock -w 5 9; then
            # Best-effort: drop our member file even without the lock.
            rm -f "$(backend_members "$backend")/$$" 2>/dev/null || true
            return 0
        fi
        rm -f "$(backend_members "$backend")/$$"
        local active; active="$(backend_active_count "$backend")"
        if [[ "$active" -gt 0 ]]; then
            return 0
        fi
        # Last out — kill that backend's proxy and remove its dir.
        local pid_file; pid_file="$(backend_pid_file "$backend")"
        if [[ -f "$pid_file" ]]; then
            local pp; pp="$(cat "$pid_file" 2>/dev/null || true)"
            if [[ -n "$pp" ]] && kill -0 "$pp" 2>/dev/null; then
                kill -9 "$pp" 2>/dev/null || true
            fi
        fi
        # Under DEBUG, keep the proxy log for post-mortem proof inspection.
        if [[ "${DEEPANTIGRAVITY_DEBUG:-}" == "1" ]]; then
            cp "$(backend_log_file "$backend")" "$SCRIPT_DIR/proxy/.cache/last-proxy-$backend.log" 2>/dev/null || true
        fi
        rm -rf "$bdir"
    } 9>"$(backend_lock "$backend")"
}

# macOS: drop our member file; if last-out, shut down the root proxy
# (via loopback HTTP, no sudo needed) and remove the /etc/hosts hijack.
mac_session_leave() {
    [[ "$MAC_JOINED" -eq 1 ]] || return 0
    mac_lock_acquire || { rm -f "$MAC_MEMBERS_DIR/$$" 2>/dev/null || true; return 0; }
    rm -f "$MAC_MEMBERS_DIR/$$"
    local active; active="$(mac_active_count)"
    if [[ "$active" -gt 0 ]]; then mac_lock_release; return 0; fi
    # Last out — tell the proxy to exit, then remove the hosts hijack.
    curl -s -m 3 --cacert "$CA_BUNDLE_PATH" \
        --resolve "cloudcode-pa.googleapis.com:$DEEPANTIGRAVITY_PORT:127.0.0.1" \
        -X POST "https://cloudcode-pa.googleapis.com:$DEEPANTIGRAVITY_PORT/_proxy/shutdown" \
        >/dev/null 2>&1 || true
    sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
    if [[ "${DEEPANTIGRAVITY_DEBUG:-}" == "1" ]]; then
        cp "$MAC_LOG_FILE" "$SCRIPT_DIR/proxy/.cache/last-proxy-macos.log" 2>/dev/null || true
    fi
    rm -rf "$MAC_SESSION_DIR"
    mac_lock_release
}

# Cleanup runs on EVERY exit.
cleanup_on_exit() {
    if [[ "$DAG_OS" == "macos" ]]; then
        mac_session_leave
        MAC_JOINED=0
        return
    fi
    if [[ -n "$JOINED_BACKEND" ]]; then
        backend_session_leave "$JOINED_BACKEND"
        JOINED_BACKEND=""
    fi
    if [[ -n "$TMP_HOSTS_FILE" && -f "$TMP_HOSTS_FILE" ]]; then
        rm -f "$TMP_HOSTS_FILE"
        TMP_HOSTS_FILE=""
    fi
}
trap cleanup_on_exit EXIT INT TERM

canonicalize_backend() {
    case "$1" in
        nv|nvidia)               echo "nvidia" ;;
        ds|deepseek|deepseekOauthWeb) echo "deepseekOauthWeb" ;;
        kimi)                    echo "kimi" ;;
        *)                       echo "$1" ;;
    esac
}

# ────────────────────────────────────────────────────────────────
# --setup (macOS)
# ────────────────────────────────────────────────────────────────
do_setup_macos() {
    local node_bin
    if ! node_bin="$(real_node)"; then
        echo "ERROR: node not found on PATH. Install Node.js >= 18 first." >&2
        exit 1
    fi
    if [[ ! -f "$HELPER_SOURCE" ]]; then
        echo "ERROR: helper script missing at $HELPER_SOURCE" >&2
        exit 1
    fi
    local user; user="$(whoami)"

    echo ""
    echo "  deepantigravity — one-time setup (macOS)"
    echo "  ========================================"
    echo "  macOS has no bwrap/setcap, so the proxy runs via sudo and"
    echo "  binds 127.0.0.1:443. This installs (sudo password ONCE):"
    echo "    1. /usr/local/bin/deepantigravity-helper  (edits /etc/hosts)"
    echo "    2. /etc/sudoers.d/deepantigravity         (NOPASSWD: helper + node proxy)"
    echo ""
    echo "  Multiple terminals using the SAME backend share one proxy."
    echo "  Different backends in parallel are NOT supported on macOS."
    echo ""

    # CA + npm deps (no sudo)
    cd "$SCRIPT_DIR/proxy"
    if [[ ! -d node_modules/node-forge ]]; then
        echo "  Installing proxy dependencies (no sudo)..."
        npm install --silent --no-audit --no-fund || {
            echo "ERROR: npm install failed. Run 'cd proxy && npm install'." >&2
            exit 1
        }
    fi
    node cert.js > /dev/null

    echo "  Authenticating with sudo..."
    sudo -v

    # Install helper (root-owned)
    echo "  Installing helper..."
    sudo install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$HELPER_INSTALLED"

    # Sudoers rule: allow the hosts helper AND running the proxy as root
    # without a password. The proxy must run as root to bind :443 (macOS
    # has no setcap). node is allowed ONLY with our start-proxy.js script.
    echo "  Installing sudoers rule..."
    local sudoers_content="# Generated by deepantigravity --setup (macOS). Removed by --teardown.
$user ALL=(root) NOPASSWD: $HELPER_INSTALLED add, $HELPER_INSTALLED remove
$user ALL=(root) NOPASSWD: $node_bin $SCRIPT_DIR/proxy/start-proxy.js *"
    local tmp; tmp=$(mktemp /tmp/dag-sudoers-XXXXXX)
    echo "$sudoers_content" > "$tmp"
    if ! sudo visudo -c -f "$tmp" >/dev/null 2>&1; then
        echo "ERROR: generated sudoers content is invalid:" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    sudo install -o root -g wheel -m 0440 "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"

    echo ""
    echo "  ✓ Setup complete. Try:"
    echo "      deepantigravity -b kimi      # routes through our proxy"
    echo "      deepantigravity -b nv        # via Nvidia NIM"
    echo "      agy                          # works normally (real Gemini)"
    echo ""
}

# ────────────────────────────────────────────────────────────────
# --setup
# ────────────────────────────────────────────────────────────────
do_setup() {
    if [[ "$DAG_OS" == "macos" ]]; then do_setup_macos; return; fi
    local node_bin
    if ! node_bin="$(real_node)"; then
        echo "ERROR: node not found on PATH. Install Node.js >= 18 first." >&2
        exit 1
    fi
    if [[ ! -f "$HELPER_SOURCE" ]]; then
        echo "ERROR: helper script missing at $HELPER_SOURCE" >&2
        exit 1
    fi
    local user
    user="$(whoami)"

    echo ""
    echo "  deepantigravity — one-time setup"
    echo "  ================================="
    echo "  This installs (sudo password required ONCE):"
    echo "    1. bubblewrap (bwrap) — for per-session /etc/hosts isolation"
    echo "    2. CAP_NET_BIND_SERVICE on $node_bin"
    echo ""
    echo "  After this, day-to-day use does NOT need sudo. Each terminal"
    echo "  runs agy inside a bwrap mount-ns, so multiple terminals can"
    echo "  use different backends in parallel."
    echo ""
    echo "  (For backward compat, the legacy /etc/hosts helper + sudoers"
    echo "   rule are also installed. They are no longer used by the"
    echo "   launch path, only by --teardown for cleanup.)"
    echo ""

    # Generate CA + install npm deps before sudo, so the rest is cleaner
    cd "$SCRIPT_DIR/proxy"
    if [[ ! -d node_modules/node-forge ]]; then
        echo "  Installing proxy dependencies (no sudo)..."
        npm install --silent --no-audit --no-fund || {
            echo "ERROR: npm install failed. Run 'cd proxy && npm install'." >&2
            exit 1
        }
    fi
    node cert.js > /dev/null

    echo "  Authenticating with sudo..."
    sudo -v

    # 0. Install bwrap if missing (apt-based distros)
    if ! command -v bwrap >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            echo "  Installing bubblewrap (apt)..."
            sudo apt install -y bubblewrap || {
                echo "ERROR: failed to install bubblewrap." >&2
                exit 1
            }
        else
            echo "ERROR: bwrap not installed and apt not available." >&2
            echo "  Install bubblewrap with your distro's package manager, then re-run --setup." >&2
            exit 1
        fi
    fi

    # 1. Install helper with root ownership
    echo "  Installing helper..."
    sudo install -o root -g root -m 0755 "$HELPER_SOURCE" "$HELPER_INSTALLED"

    # 2. Sudoers rule — locked down to the two specific argument forms
    echo "  Installing sudoers rule..."
    local sudoers_content="# Generated by deepantigravity --setup. Removed by --teardown.
$user ALL=(root) NOPASSWD: $HELPER_INSTALLED add, $HELPER_INSTALLED remove"
    # `visudo -c -f` validates before installing — refuse if invalid
    local tmp; tmp=$(mktemp /tmp/dag-sudoers-XXXXXX)
    echo "$sudoers_content" > "$tmp"
    if ! sudo visudo -c -f "$tmp" >/dev/null 2>&1; then
        echo "ERROR: generated sudoers content is invalid:" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    sudo install -o root -g root -m 0440 "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"

    # 3. setcap on node so we can bind :443 without root each launch
    echo "  Granting CAP_NET_BIND_SERVICE on $node_bin..."
    sudo setcap CAP_NET_BIND_SERVICE=+eip "$node_bin"

    echo ""
    echo "  ✓ Setup complete. Try:"
    echo "      deepantigravity -b kimi        # routes through our proxy"
    echo "      deepantigravity -b deepseek    # via DeepSeek Web OAuth"
    echo "      deepantigravity -b nv          # via Nvidia NIM"
    echo "      agy                            # works normally (real Gemini)"
    echo ""
}

# ────────────────────────────────────────────────────────────────
# --teardown
# ────────────────────────────────────────────────────────────────
do_teardown() {
    echo ""
    echo "  deepantigravity — teardown"
    echo "  =========================="

    # macOS: stop the shared root proxy + clean its session dir.
    if [[ "$DAG_OS" == "macos" ]]; then
        if [[ -d "$MAC_SESSION_DIR" ]]; then
            echo "  Stopping macOS shared proxy..."
            curl -s -m 3 --cacert "$CA_BUNDLE_PATH" \
                --resolve "cloudcode-pa.googleapis.com:$DEEPANTIGRAVITY_PORT:127.0.0.1" \
                -X POST "https://cloudcode-pa.googleapis.com:$DEEPANTIGRAVITY_PORT/_proxy/shutdown" \
                >/dev/null 2>&1 || true
            # Fallback: kill whatever roots are listening on :443.
            local lp; lp="$(lsof -ti "tcp@127.0.0.1:$DEEPANTIGRAVITY_PORT" -s TCP:LISTEN 2>/dev/null | head -1)"
            [[ -n "$lp" ]] && sudo kill -9 "$lp" 2>/dev/null || true
            rm -rf "$MAC_SESSION_DIR"
            echo "  ✓ Proxy stopped, session cleaned"
        fi
    fi

    # Kill any running per-backend proxies
    if [[ -d "$SESSIONS_ROOT" ]]; then
        echo "  Stopping any running backend proxies..."
        for backend in $(backend_active_list); do
            local pid_file; pid_file="$(backend_pid_file "$backend")"
            if [[ -f "$pid_file" ]]; then
                local ppid; ppid="$(cat "$pid_file" 2>/dev/null || true)"
                if [[ -n "$ppid" ]] && kill -0 "$ppid" 2>/dev/null; then
                    echo "    killing $backend proxy (PID $ppid)"
                    kill -9 "$ppid" 2>/dev/null || true
                fi
            fi
        done
        rm -rf "$SESSIONS_ROOT"
        echo "  ✓ Backend proxies stopped, sessions cleaned"
    fi

    # Remove any leftover /etc/hosts entries (legacy from previous version)
    if hosts_present; then
        if helper_installed; then
            echo "  Removing legacy /etc/hosts entries..."
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null \
                || sudo "$HELPER_INSTALLED" remove
        else
            echo "  Removing legacy /etc/hosts entries (sudo password required)..."
            sudo sed -i.deepantigravity-bak \
                '/^# >>> deepantigravity BEGIN <<<$/,/^# >>> deepantigravity END <<<$/d' \
                /etc/hosts
        fi
        echo "  ✓ /etc/hosts cleaned"
    fi

    # Remove helper + sudoers rule
    if helper_installed || sudoers_installed; then
        echo "  Removing helper + sudoers rule (sudo password may be required)..."
        sudo -v
        if helper_installed; then sudo rm -f "$HELPER_INSTALLED"; fi
        if sudoers_installed; then sudo rm -f "$SUDOERS_FILE"; fi
        echo "  ✓ Helper and sudoers rule removed"
    fi

    # Remove setcap on node
    local node_bin
    if node_bin="$(real_node)" && node_has_bind_cap; then
        echo "  Removing CAP_NET_BIND_SERVICE from $node_bin..."
        sudo setcap -r "$node_bin" 2>/dev/null \
            || { sudo -v && sudo setcap -r "$node_bin"; }
        echo "  ✓ Capability removed"
    fi

    echo ""
    echo "  ✓ Teardown complete. \`agy\` is back to normal."
    echo ""
}

# ────────────────────────────────────────────────────────────────
# --status
# ────────────────────────────────────────────────────────────────
show_status_macos() {
    echo ""
    echo "  deepantigravity — Status (macOS)"
    echo "  ================================"
    echo ""
    echo "  agy:                 $(command -v agy 2>/dev/null || echo 'NOT FOUND — install from https://antigravity.google/download')"
    echo "  node:                $(command -v node 2>/dev/null || echo 'NOT FOUND')"
    echo ""
    echo "  Setup state:"
    echo "    Helper:            $(helper_installed && echo "✓ $HELPER_INSTALLED" || echo "✗ missing (run --setup)")"
    echo "    Sudoers rule:      $(sudoers_installed && echo "✓ $SUDOERS_FILE" || echo "✗ missing (run --setup)")"
    echo "    CA cert:           $([[ -f "$SCRIPT_DIR/proxy/.cache/ca.pem" ]] && echo "✓ $SCRIPT_DIR/proxy/.cache/ca.pem" || echo "✗ not yet generated")"
    echo ""
    echo "  Live state:"
    echo "    /etc/hosts:        $(hosts_present && echo "PRESENT (a session is live, or cleanup failed → --teardown)" || echo "clean (correct — agy alone uses real Google)")"
    if [[ -f "$MAC_PID_FILE" ]]; then
        local pp be
        pp="$(cat "$MAC_PID_FILE" 2>/dev/null || true)"
        be="$(cat "$MAC_BACKEND_FILE" 2>/dev/null || true)"
        if [[ -n "$pp" && "$pp" != "unknown" ]] && kill -0 "$pp" 2>/dev/null; then
            echo "    Shared proxy:      PID $pp (backend: ${be:-unknown})"
            echo "    Active sessions:   $(mac_active_count)"
        elif lsof -ti "tcp@127.0.0.1:$DEEPANTIGRAVITY_PORT" -s TCP:LISTEN >/dev/null 2>&1; then
            echo "    Shared proxy:      running on 127.0.0.1:$DEEPANTIGRAVITY_PORT (backend: ${be:-unknown})"
            echo "    Active sessions:   $(mac_active_count)"
        else
            echo "    Shared proxy:      none (state stale, will be cleaned on next launch)"
        fi
    else
        echo "    Shared proxy:      none"
    fi
    echo ""
    echo "  Keys:"
    echo "    KIMI_API_KEY:           $(mask_key "${KIMI_API_KEY:-}")"
    echo "    DEEPSEEK_OAUTH_WEB_TOKEN: $(mask_key "${DEEPSEEK_OAUTH_WEB_TOKEN:-}")"
    echo "    NVIDIA_API_KEY:         $(mask_key "${NVIDIA_API_KEY:-}")"
    echo ""
    echo "  Default backend:    $DEFAULT_BACKEND"
    echo "  Proxy port:         $DEEPANTIGRAVITY_PORT"
    echo "  Note: macOS shares ONE proxy/backend across terminals."
    echo ""
}

show_status() {
    if [[ "$DAG_OS" == "macos" ]]; then show_status_macos; return; fi
    local node_bin
    node_bin="$(real_node 2>/dev/null || echo 'NOT FOUND')"
    echo ""
    echo "  deepantigravity — Status"
    echo "  ========================"
    echo ""
    echo "  agy:                   $(command -v agy 2>/dev/null || echo 'NOT FOUND — install from https://antigravity.google/download')"
    echo "  node:                  $(command -v node 2>/dev/null || echo 'NOT FOUND')"
    echo ""
    echo "  Setup state:"
    echo "    bwrap (bubblewrap):  $(command -v bwrap >/dev/null 2>&1 && echo "✓ $(command -v bwrap)" || echo "✗ missing (run --setup or install: sudo apt install bubblewrap)")"
    echo "    node bind cap:       $(node_has_bind_cap && echo "✓ CAP_NET_BIND_SERVICE on $node_bin" || echo "✗ missing (run --setup)")"
    echo "    CA cert:             $([[ -f "$SCRIPT_DIR/proxy/.cache/ca.pem" ]] && echo "✓ $SCRIPT_DIR/proxy/.cache/ca.pem" || echo "✗ not yet generated")"
    echo "    Helper (legacy):     $(helper_installed && echo "$HELPER_INSTALLED (no longer required)" || echo "not installed (correct — not needed)")"
    echo ""
    echo "  Live state:"
    echo "    /etc/hosts:          $(hosts_present && echo "STALE (run --teardown — new design uses bwrap, not /etc/hosts)" || echo "clean (correct — new design uses bwrap)")"
    # Per-backend proxies
    local found_any=0
    if [[ -d "$SESSIONS_ROOT" ]]; then
        for backend in $(backend_active_list); do
            local pid_file; pid_file="$(backend_pid_file "$backend")"
            local bip; bip="$(backend_ip "$backend")"
            local ppid=""
            [[ -f "$pid_file" ]] && ppid="$(cat "$pid_file" 2>/dev/null || true)"
            if [[ -n "$ppid" ]] && kill -0 "$ppid" 2>/dev/null; then
                local n; n="$(backend_active_count "$backend")"
                echo "    Proxy [$backend]:        PID $ppid on $bip:$DEEPANTIGRAVITY_PORT  ($n session(s))"
                found_any=1
            fi
        done
    fi
    [[ $found_any -eq 0 ]] && echo "    Active proxies:      none"
    echo ""
    echo "  Keys:"
    echo "    KIMI_API_KEY:             $(mask_key "${KIMI_API_KEY:-}")"
    echo "    DEEPSEEK_OAUTH_WEB_TOKEN: $(mask_key "${DEEPSEEK_OAUTH_WEB_TOKEN:-}")"
    echo "    NVIDIA_API_KEY:           $(mask_key "${NVIDIA_API_KEY:-}")"
    echo ""
    echo "  Default backend:       $DEFAULT_BACKEND"
    echo "  Proxy port:            $DEEPANTIGRAVITY_PORT"
    echo ""
}

# ────────────────────────────────────────────────────────────────
# --cost / --ca-path / --install-ca / --help
# ────────────────────────────────────────────────────────────────
show_cost() {
    cat <<EOF

  deepantigravity Provider Pricing
  =================================

  Provider           Input/M    Output/M   Notes
  ----------         --------   --------   -----------
  Kimi Code          subscription          Anthropic-native, kimi-for-coding
  DeepSeek Web OAuth free                 chat.deepseek.com web session, emulated tools, deepseek-v4-pro (1M ctx, thinking)
  Nvidia NIM         \$0.44      \$0.87      OpenAI-compat (default kimi-k2.6)

EOF
}

show_ca_path() {
    local ca="$SCRIPT_DIR/proxy/.cache/ca.pem"
    if [[ ! -f "$ca" ]]; then
        echo "Generating CA..." >&2
        ( cd "$SCRIPT_DIR/proxy" && [[ -d node_modules/node-forge ]] || npm install --silent --no-audit --no-fund )
        node "$SCRIPT_DIR/proxy/cert.js" >/dev/null
    fi
    echo "$ca"
}

show_install_ca() {
    local ca; ca="$(show_ca_path)"
    cat <<EOF

  How to install the deepantigravity CA into your system trust store
  ===================================================================

  Note: deepantigravity does NOT need this for agy to work — agy honors
        SSL_CERT_FILE, which the launcher sets to our CA.

  Linux (Debian/Ubuntu):
    sudo cp "$ca" /usr/local/share/ca-certificates/deepantigravity.crt
    sudo update-ca-certificates

  Linux (Fedora/RHEL):
    sudo cp "$ca" /etc/pki/ca-trust/source/anchors/deepantigravity.pem
    sudo update-ca-trust extract

  macOS:
    sudo security add-trusted-cert -d -r trustRoot \\
      -k /Library/Keychains/System.keychain "$ca"

EOF
}

show_help() {
    cat <<EOF
deepantigravity — Use \`agy\` (Antigravity CLI) with cheap LLM backends

USAGE
  deepantigravity --setup                    one-time, requires sudo password
  deepantigravity [-b BACKEND] [agy-args]    no sudo prompt during normal use
  deepantigravity --teardown                 uninstall everything
  deepantigravity --status                   diagnostic

BACKENDS (all routed through our local proxy)
  -b kimi                    Kimi Code                (Anthropic-native upstream)
  -b ds | deepseek          DeepSeek Web OAuth       (chat.deepseek.com web — emulated tools)
  -b nv | nvidia            Nvidia NIM               (OpenAI-compat upstream)

To use real Google Gemini just run \`agy\` directly — deepantigravity adds
the /etc/hosts redirect only WHILE running, and removes it on exit.

PREREQUISITES
  * agy (Antigravity CLI)              https://antigravity.google/download
  * Node.js >= 18, npm
  * sudo access (only for --setup and --teardown; runtime needs no sudo)

CONFIG
  Edit proxy/.env. Set API_PROVIDER and at least one of KIMI_API_KEY,
  DEEPSEEK_OAUTH_WEB_TOKEN, or NVIDIA_API_KEY.
  DeepSeek web also needs DEEPSEEK_OAUTH_WEB_COOKIE (browser cookie with
  ds_session_id + aws-waf-token). Thinking is on by default
  (DEEPSEEK_OAUTH_WEB_THINKING=0 to disable).

DEBUG
  DEEPANTIGRAVITY_DEBUG=1 deepantigravity -b kimi
  → logs every request body to proxy/.cache/requests/
EOF
}

# ────────────────────────────────────────────────────────────────
# Provider key validation
# ────────────────────────────────────────────────────────────────
resolve_backend() {
    local backend
    backend="$(canonicalize_backend "$BACKEND")"
    RESOLVED_BACKEND="$backend"

    case "$backend" in
        kimi)       if [[ -z "${KIMI_API_KEY:-}" || "$KIMI_API_KEY" =~ ^sk-your ]]; then echo "ERROR: KIMI_API_KEY not set in proxy/.env" >&2; exit 1; fi ;;
        deepseekOauthWeb)   if [[ -z "${DEEPSEEK_OAUTH_WEB_TOKEN:-}" || "$DEEPSEEK_OAUTH_WEB_TOKEN" =~ ^your-deepseek ]]; then echo "ERROR: DEEPSEEK_OAUTH_WEB_TOKEN not set in proxy/.env" >&2; exit 1; fi ;;
        nvidia)     if [[ -z "${NVIDIA_API_KEY:-}" || "$NVIDIA_API_KEY" =~ ^nvapi-your ]]; then echo "ERROR: NVIDIA_API_KEY not set in proxy/.env" >&2; exit 1; fi ;;
        *)          echo "ERROR: Unknown backend '$backend' (only kimi, deepseekOauthWeb, and nvidia are supported)" >&2; exit 1 ;;
    esac
}

ensure_node_modules() {
    if [[ ! -d "$SCRIPT_DIR/proxy/node_modules/node-forge" ]]; then
        echo "  First-run setup: installing proxy dependencies..."
        ( cd "$SCRIPT_DIR/proxy" && npm install --silent --no-audit --no-fund ) || {
            echo "ERROR: npm install failed. Run 'cd proxy && npm install' manually." >&2
            exit 1
        }
    fi
}

free_port() {
    local port="$1"
    local ip="${2:-}"   # Optional: only kill listeners on this specific IP
    local stale_pid=""

    # When ip is given, scope ss's match to that IP:port. Otherwise match any.
    local ss_filter="sport = :$port"
    [[ -n "$ip" ]] && ss_filter="$ss_filter and src = $ip"

    if command -v ss >/dev/null 2>&1; then
        stale_pid=$(ss -tlnp "$ss_filter" 2>/dev/null \
            | awk -F'pid=' '/LISTEN/{split($2,a,","); print a[1]}' | head -1)
    fi
    if [[ -z "$stale_pid" ]] && command -v lsof >/dev/null 2>&1; then
        if [[ -n "$ip" ]]; then
            stale_pid=$(timeout 3 lsof -ti "tcp@$ip:$port" -s TCP:LISTEN 2>/dev/null || true)
        else
            stale_pid=$(timeout 3 lsof -ti tcp:"$port" -s TCP:LISTEN 2>/dev/null || true)
        fi
    fi
    if [[ -n "$stale_pid" ]]; then
        kill -9 "$stale_pid" 2>/dev/null || true
    fi

    # fuser fallback. Without an IP we can't scope it, so we fall back to
    # killing anything on $port (only safe if no other backend uses $port).
    if [[ -z "$ip" ]] && command -v fuser >/dev/null 2>&1; then
        fuser -k -SIGKILL "$port"/tcp 2>/dev/null || true
    fi

    # Wait for kernel to actually release the port (on this IP).
    local n=0
    while [[ $n -lt 30 ]]; do
        if ! ss -tln "$ss_filter" 2>/dev/null | grep -q LISTEN; then break; fi
        sleep 0.1
        n=$((n + 1))
    done
}

# ────────────────────────────────────────────────────────────────
# Main launch path (macOS) — single shared proxy on 127.0.0.1:443
# ────────────────────────────────────────────────────────────────
# macOS has no bwrap, so we can't give each terminal its own /etc/hosts.
# Instead all terminals share ONE proxy + ONE backend (refcounted). The
# proxy runs as root (to bind :443) via the NOPASSWD sudoers rule; the
# global /etc/hosts redirect is added by the helper while a session is
# live and removed when the last terminal exits. Different backends in
# parallel are refused. Locking uses mkdir (flock is unavailable on macOS).
mac_lock_acquire() {
    local n=0
    while ! mkdir "$MAC_LOCK" 2>/dev/null; do
        # Steal a stale lock whose owner PID is dead.
        local owner; owner="$(cat "$MAC_LOCK/owner" 2>/dev/null || true)"
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$MAC_LOCK" 2>/dev/null || true
            continue
        fi
        n=$((n + 1)); [[ $n -gt 100 ]] && return 1
        sleep 0.1
    done
    echo "$$" > "$MAC_LOCK/owner"
    return 0
}
mac_lock_release() { rm -rf "$MAC_LOCK" 2>/dev/null || true; }

mac_active_count() {
    local count=0
    if [[ -d "$MAC_MEMBERS_DIR" ]]; then
        for f in "$MAC_MEMBERS_DIR"/*; do
            [[ -e "$f" ]] || continue
            local pid; pid="$(basename "$f")"
            if kill -0 "$pid" 2>/dev/null; then count=$((count + 1)); else rm -f "$f"; fi
        done
    fi
    echo "$count"
}

launch_agy_macos() {
    if ! helper_installed || ! sudoers_installed; then
        echo "ERROR: setup not complete. Run: $0 --setup" >&2
        exit 1
    fi
    ensure_node_modules
    mkdir -p "$MAC_SESSION_DIR" "$MAC_MEMBERS_DIR"

    local backend="$RESOLVED_BACKEND"
    local node_bin; node_bin="$(real_node)"

    if ! mac_lock_acquire; then
        echo "ERROR: could not acquire session lock (another launcher hung?)." >&2
        exit 1
    fi

    local existing_pid="" existing_backend=""
    [[ -f "$MAC_PID_FILE" ]]     && existing_pid="$(cat "$MAC_PID_FILE" 2>/dev/null || true)"
    [[ -f "$MAC_BACKEND_FILE" ]] && existing_backend="$(cat "$MAC_BACKEND_FILE" 2>/dev/null || true)"

    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        if [[ "$existing_backend" == "$backend" ]]; then
            # JOIN
            touch "$MAC_MEMBERS_DIR/$$"; MAC_JOINED=1
            local n; n="$(mac_active_count)"
            echo "  Joined $backend session: proxy PID $existing_pid on 127.0.0.1:$DEEPANTIGRAVITY_PORT ($n session(s) active)"
            mac_lock_release
        else
            # REFUSE different backend
            local n; n="$(mac_active_count)"
            mac_lock_release
            echo "ERROR: a deepantigravity session is already running with a DIFFERENT backend" >&2
            echo "  Running backend: $existing_backend  (proxy PID $existing_pid, $n session(s))" >&2
            echo "  Requested:       $backend" >&2
            echo "" >&2
            echo "  macOS shares one global proxy, so all terminals must use the same" >&2
            echo "  backend. Re-run with -b $existing_backend, or stop the other session(s)." >&2
            exit 1
        fi
    else
        # START fresh — become the leader.
        rm -f "$MAC_PID_FILE" "$MAC_BACKEND_FILE" "$MAC_LOG_FILE"
        rm -rf "$MAC_MEMBERS_DIR"; mkdir -p "$MAC_MEMBERS_DIR"

        # Clean any stale global hijack from a crashed session.
        if hosts_present; then
            echo "  Cleaning stale /etc/hosts entries..."
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
        fi

        # Resolve real Google IPs BEFORE hijacking (dig bypasses /etc/hosts).
        local cloudcode_ip="" daily_ip=""
        cloudcode_ip="$(dig +short cloudcode-pa.googleapis.com A 2>/dev/null | grep -m1 '^[0-9]')"
        daily_ip="$(dig +short daily-cloudcode-pa.googleapis.com A 2>/dev/null | grep -m1 '^[0-9]')"
        if [[ -z "$cloudcode_ip" ]]; then
            echo "ERROR: could not resolve cloudcode-pa.googleapis.com (dig). Is the network up?" >&2
            mac_lock_release; exit 1
        fi
        [[ -z "$daily_ip" ]] && daily_ip="$cloudcode_ip"
        echo "  Real IPs: cloudcode-pa → $cloudcode_ip, daily-cloudcode-pa → $daily_ip"

        echo "  Adding /etc/hosts redirect for cloudcode-pa.googleapis.com..."
        if ! sudo -n "$HELPER_INSTALLED" add 2>/dev/null; then
            echo "ERROR: passwordless sudo for the helper failed. Run --setup again." >&2
            mac_lock_release; exit 1
        fi

        : > "$MAC_LOG_FILE"
        echo "  Starting $backend proxy on 127.0.0.1:$DEEPANTIGRAVITY_PORT (via sudo) ..."
        # Proxy must run as root to bind :443. It reads keys from
        # proxy/.env itself and resolves real Google IPs via its own
        # DNS (macOS c-ares bypasses /etc/hosts). We pass the resolved
        # IPs through a tiny env file the proxy also reads, to be safe.
        printf 'DEEPANTIGRAVITY_REAL_IP_CLOUDCODE=%s\nDEEPANTIGRAVITY_REAL_IP_DAILY=%s\n' \
            "$cloudcode_ip" "$daily_ip" > "$MAC_SESSION_DIR/proxy.env"
        # The sudoers rule allows exactly: node start-proxy.js *
        DEEPANTIGRAVITY_DEBUG="${DEEPANTIGRAVITY_DEBUG:-}" \
        sudo -n "$node_bin" "$SCRIPT_DIR/proxy/start-proxy.js" \
            "$backend" "$DEEPANTIGRAVITY_PORT" "127.0.0.1" \
            > "$MAC_LOG_FILE" 2>&1 &
        disown 2>/dev/null || true

        # Wait for the proxy to print its port line.
        local tries=0 proxy_port="" ca_path=""
        while [[ $tries -lt 80 ]]; do
            if [[ -s "$MAC_LOG_FILE" ]] && grep -q '^[0-9]\+$' "$MAC_LOG_FILE" 2>/dev/null; then break; fi
            sleep 0.1; tries=$((tries + 1))
        done
        proxy_port="$(grep -m1 '^[0-9]\+$' "$MAC_LOG_FILE" || true)"
        ca_path="$(grep -m1 '^/' "$MAC_LOG_FILE" || true)"
        if [[ -z "$proxy_port" || -z "$ca_path" || ! -f "$ca_path" ]]; then
            echo "ERROR: proxy failed to start. Log:" >&2
            tail -20 "$MAC_LOG_FILE" >&2 2>/dev/null || true
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
            mac_lock_release; exit 1
        fi

        # Find the root-owned proxy PID by its listening socket (we can't
        # use $! — that's sudo's child shell, not necessarily node).
        local proxy_pid=""
        proxy_pid="$(lsof -ti "tcp@127.0.0.1:$DEEPANTIGRAVITY_PORT" -s TCP:LISTEN 2>/dev/null | head -1)"
        echo "${proxy_pid:-unknown}" > "$MAC_PID_FILE"
        echo "$backend" > "$MAC_BACKEND_FILE"
        touch "$MAC_MEMBERS_DIR/$$"; MAC_JOINED=1
        echo "  TLS server on 127.0.0.1:$proxy_port → $backend"
        mac_lock_release
    fi

    # Build combined CA bundle: our CA + macOS system roots (exported
    # from the System keychain). Go's SSL_CERT_FILE REPLACES the trust
    # pool, so non-cloudcode-pa TLS needs the real roots too.
    local our_ca="$SCRIPT_DIR/proxy/.cache/ca.pem"
    {
        cat "$our_ca"
        security find-certificate -a -p \
            /System/Library/Keychains/SystemRootCertificates.keychain 2>/dev/null || true
        security find-certificate -a -p \
            /Library/Keychains/System.keychain 2>/dev/null || true
    } > "$CA_BUNDLE_PATH"
    export SSL_CERT_FILE="$CA_BUNDLE_PATH"
    export SSL_CERT_DIR="$(dirname "$CA_BUNDLE_PATH")"

    echo ""
    set +e
    agy "${PASS_ARGS[@]}"
    local agy_status=$?
    set -e
    return $agy_status
}

# ────────────────────────────────────────────────────────────────
# Main launch path
# ────────────────────────────────────────────────────────────────
launch_agy() {
    if [[ "$DAG_OS" == "macos" ]]; then launch_agy_macos; return; fi
    # Pre-flight
    if ! node_has_bind_cap; then
        echo "ERROR: node lacks CAP_NET_BIND_SERVICE. Run: $0 --setup" >&2
        exit 1
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        echo "ERROR: bwrap (bubblewrap) is not installed. Install with:" >&2
        echo "  sudo apt install -y bubblewrap" >&2
        echo "" >&2
        echo "  bwrap is needed to give each terminal its own /etc/hosts so" >&2
        echo "  different terminals can use different backends in parallel." >&2
        exit 1
    fi

    ensure_node_modules
    mkdir -p "$SESSIONS_ROOT"

    local backend="$RESOLVED_BACKEND"
    local ip; ip="$(backend_ip "$backend")"
    local bdir; bdir="$(backend_dir "$backend")"
    local pid_file; pid_file="$(backend_pid_file "$backend")"
    local log_file; log_file="$(backend_log_file "$backend")"
    local mdir; mdir="$(backend_members "$backend")"
    local lock_file; lock_file="$(backend_lock "$backend")"

    mkdir -p "$bdir" "$mdir"

    # Warn on stale GLOBAL /etc/hosts entries from an older single-session
    # version. The new design never touches /etc/hosts, so any leftovers
    # break DNS for cloudcode-pa.googleapis.com globally. Try the helper
    # if installed; otherwise tell the user to run --teardown.
    if hosts_present; then
        if helper_installed && sudoers_installed; then
            echo "  Cleaning stale global /etc/hosts entries from a previous version..."
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || \
                echo "  WARNING: helper-remove failed; run: $0 --teardown" >&2
            sleep 0.1
        else
            echo "  WARNING: stale /etc/hosts entries found and helper not installed." >&2
            echo "           Manually remove the deepantigravity block from /etc/hosts." >&2
        fi
    fi

    # ── Atomic per-backend critical section: join existing or start ──
    {
        if ! flock -w 10 9; then
            echo "ERROR: could not acquire $backend session lock within 10s." >&2
            exit 1
        fi

        local existing_pid=""
        [[ -f "$pid_file" ]] && existing_pid="$(cat "$pid_file" 2>/dev/null || true)"

        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # JOIN existing backend session
            touch "$mdir/$$"
            JOINED_BACKEND="$backend"
            local n; n="$(backend_active_count "$backend")"
            echo "  Joined $backend session: proxy PID $existing_pid on $ip:$DEEPANTIGRAVITY_PORT ($n session(s) active)"
        else
            # START fresh: spawn this backend's proxy
            rm -f "$pid_file" "$log_file"
            free_port "$DEEPANTIGRAVITY_PORT" "$ip"

            : > "$log_file"
            echo "  Starting $backend proxy on $ip:$DEEPANTIGRAVITY_PORT ..."

            local launcher_cmd="setsid"
            command -v setsid >/dev/null 2>&1 || launcher_cmd="nohup"
            # 9<&- closes FD 9 in the spawned proxy so the lock isn't
            # held by the proxy's inherited FD for its whole lifetime.
            $launcher_cmd env \
                ${DEEPANTIGRAVITY_DEBUG:+DEEPANTIGRAVITY_DEBUG="$DEEPANTIGRAVITY_DEBUG"} \
                node "$SCRIPT_DIR/proxy/start-proxy.js" \
                    "$backend" "$DEEPANTIGRAVITY_PORT" "$ip" \
                > "$log_file" 2>&1 < /dev/null 9<&- &
            local proxy_pid=$!
            disown 2>/dev/null || true

            # Wait for the "port\nca-path" lines.
            local tries=0
            while [[ $tries -lt 60 ]]; do
                if [[ -s "$log_file" ]] && grep -q '^[0-9]\+$' "$log_file" 2>/dev/null; then
                    break
                fi
                if ! kill -0 "$proxy_pid" 2>/dev/null; then
                    echo "ERROR: $backend proxy died on startup. Log:" >&2
                    tail -20 "$log_file" >&2 2>/dev/null || true
                    exit 1
                fi
                sleep 0.1
                tries=$((tries + 1))
            done

            local proxy_port ca_path
            proxy_port="$(grep -m1 '^[0-9]\+$' "$log_file" || true)"
            ca_path="$(grep -m1 '^/' "$log_file" || true)"
            if [[ -z "$proxy_port" || -z "$ca_path" || ! -f "$ca_path" ]]; then
                echo "ERROR: $backend proxy startup output unexpected. Log:" >&2
                tail -20 "$log_file" >&2 2>/dev/null || true
                kill -9 "$proxy_pid" 2>/dev/null || true
                exit 1
            fi

            echo "$proxy_pid" > "$pid_file"
            touch "$mdir/$$"
            JOINED_BACKEND="$backend"
            echo "  TLS server on $ip:$proxy_port → $backend (proxy PID $proxy_pid)"
        fi
    } 9>"$lock_file"

    # Build combined CA bundle (our local CA + system roots). Same CA
    # is used by all backend proxies (they share proxy/.cache/ca.pem).
    local our_ca="$SCRIPT_DIR/proxy/.cache/ca.pem"
    local system_ca=""
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
             /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem; do
        if [[ -f "$f" ]]; then system_ca="$f"; break; fi
    done
    if [[ -n "$system_ca" ]]; then
        cat "$our_ca" "$system_ca" > "$CA_BUNDLE_PATH"
    else
        cp "$our_ca" "$CA_BUNDLE_PATH"
        echo "  WARNING: system CA bundle not found; non-Google TLS may fail" >&2
    fi

    # Per-session /etc/hosts: original entries minus any deepantigravity
    # block, plus a fresh redirect to THIS backend's IP. bwrap will
    # bind-mount this over /etc/hosts only inside agy's namespace, so
    # other terminals (and the host) are unaffected.
    TMP_HOSTS_FILE="$(mktemp /tmp/deepantigravity-hosts-XXXXXX)"
    {
        sed '/# >>> deepantigravity BEGIN <<</,/# <<< deepantigravity END <<</d' /etc/hosts
        echo ""
        echo "# >>> deepantigravity BEGIN <<<  (per-session, bwrap-mounted)"
        echo "$ip cloudcode-pa.googleapis.com"
        echo "$ip daily-cloudcode-pa.googleapis.com"
        echo "# <<< deepantigravity END <<<"
    } > "$TMP_HOSTS_FILE"

    echo ""

    # Run agy inside bwrap with our custom /etc/hosts. Network is shared
    # with the host (no --unshare-net), so agy can still reach our proxy
    # at $ip:443 over loopback. /proc and /dev are fresh mounts.
    set +e
    bwrap \
        --bind / / \
        --proc /proc \
        --dev /dev \
        --bind "$TMP_HOSTS_FILE" /etc/hosts \
        --setenv SSL_CERT_FILE "$CA_BUNDLE_PATH" \
        --setenv SSL_CERT_DIR "$(dirname "$CA_BUNDLE_PATH")" \
        --die-with-parent \
        agy "${PASS_ARGS[@]}"
    local agy_status=$?
    set -e
    return $agy_status
}

# ── Main ──
case "$ACTION" in
    help)        show_help ;;
    setup)       do_setup ;;
    teardown)    do_teardown ;;
    status)      show_status ;;
    cost)        show_cost ;;
    ca-path)     show_ca_path ;;
    install-ca)  show_install_ca ;;
    launch)
        resolve_backend
        launch_agy ;;
esac
