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
# Many `deepantigravity` launches can share ONE proxy as long as they
# all request the same backend (only one process can bind 127.0.0.1:443
# and /etc/hosts has only one redirect target). The first launch starts
# the proxy as a detached daemon; subsequent launches join as members;
# the last launch to exit tears everything down. State lives under:
#   proxy/.cache/session/
#     ├─ lock            flock target for atomic operations
#     ├─ proxy.pid       PID of the detached proxy (cleaned up by last-out)
#     ├─ backend         backend name (kimi or nvidia)
#     ├─ ca-bundle.pem   combined CA (our local CA + system trust store)
#     ├─ proxy.log       proxy stdout+stderr
#     └─ members/        one empty file named <PID> per active session
SESSION_DIR="$SCRIPT_DIR/proxy/.cache/session"
SESSION_LOCK="$SESSION_DIR/lock"
SESSION_PROXY_PID="$SESSION_DIR/proxy.pid"
SESSION_BACKEND="$SESSION_DIR/backend"
SESSION_BUNDLE="$SESSION_DIR/ca-bundle.pem"
SESSION_LOG="$SESSION_DIR/proxy.log"
SESSION_MEMBERS="$SESSION_DIR/members"
JOINED_SESSION=0    # 1 if we registered ourselves as a session member

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
    readlink -f "$n"
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
# Echoes the count.
session_active_member_count() {
    local count=0
    if [[ -d "$SESSION_MEMBERS" ]]; then
        for f in "$SESSION_MEMBERS"/*; do
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

# Atomically (under flock) remove our member file. If we're the last
# active member, kill the proxy and remove /etc/hosts entries.
session_leave() {
    [[ "$JOINED_SESSION" -eq 1 ]] || return 0
    [[ -d "$SESSION_DIR" ]] || return 0
    {
        if ! flock -w 5 9; then
            # Best-effort: at least drop our member file even without
            # the lock, so we don't pollute the refcount forever.
            rm -f "$SESSION_MEMBERS/$$" 2>/dev/null || true
            return 0
        fi
        rm -f "$SESSION_MEMBERS/$$"
        local active; active=$(session_active_member_count)
        if [[ "$active" -gt 0 ]]; then
            return 0
        fi
        # We're the last one out — tear down.
        if [[ -f "$SESSION_PROXY_PID" ]]; then
            local proxy_pid; proxy_pid=$(cat "$SESSION_PROXY_PID" 2>/dev/null || true)
            if [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
                # SIGKILL because Node's HTTP server graceful shutdown blocks
                # on long-lived SSE connections from agy.
                kill -9 "$proxy_pid" 2>/dev/null || true
            fi
        fi
        if helper_installed && hosts_present; then
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
        fi
        # Remove session state (keep proxy.log around briefly for post-mortem
        # in debug mode — it'll be wiped on next session start).
        rm -f "$SESSION_PROXY_PID" "$SESSION_BACKEND" "$SESSION_BUNDLE"
        rm -rf "$SESSION_MEMBERS"
        rmdir "$SESSION_DIR" 2>/dev/null || true
    } 9>"$SESSION_LOCK"
    JOINED_SESSION=0
}

# Cleanup runs on EVERY exit. Defers to session_leave which handles
# refcount-based teardown of the shared proxy + /etc/hosts.
cleanup_on_exit() {
    session_leave
}
trap cleanup_on_exit EXIT INT TERM

canonicalize_backend() {
    case "$1" in
        nv|nvidia)     echo "nvidia" ;;
        kimi)          echo "kimi" ;;
        *)             echo "$1" ;;
    esac
}

# ────────────────────────────────────────────────────────────────
# --setup
# ────────────────────────────────────────────────────────────────
do_setup() {
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
    echo "    1. /usr/local/bin/deepantigravity-helper       (root-owned helper)"
    echo "    2. /etc/sudoers.d/deepantigravity              (NOPASSWD for $user → helper)"
    echo "    3. CAP_NET_BIND_SERVICE on $node_bin"
    echo ""
    echo "  After this, day-to-day use does NOT need sudo. The /etc/hosts"
    echo "  entries are added on each \`deepantigravity\` launch and removed"
    echo "  on exit, so plain \`agy\` always works."
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
    echo "      deepantigravity -b kimi      # routes through our proxy"
    echo "      deepantigravity -b nv        # via Nvidia NIM"
    echo "      agy                          # works normally (real Gemini)"
    echo ""
}

# ────────────────────────────────────────────────────────────────
# --teardown
# ────────────────────────────────────────────────────────────────
do_teardown() {
    echo ""
    echo "  deepantigravity — teardown"
    echo "  =========================="

    # Remove any leftover /etc/hosts entries
    if hosts_present; then
        if helper_installed; then
            echo "  Removing /etc/hosts entries..."
            sudo -n "$HELPER_INSTALLED" remove 2>/dev/null \
                || sudo "$HELPER_INSTALLED" remove
        else
            echo "  Removing /etc/hosts entries (sudo password required)..."
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
show_status() {
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
    echo "    Helper installed:    $(helper_installed && echo "✓ $HELPER_INSTALLED" || echo "✗ missing (run --setup)")"
    echo "    Sudoers rule:        $(sudoers_installed && echo "✓ $SUDOERS_FILE" || echo "✗ missing (run --setup)")"
    echo "    node bind cap:       $(node_has_bind_cap && echo "✓ CAP_NET_BIND_SERVICE on $node_bin" || echo "✗ missing (run --setup)")"
    echo "    CA cert:             $([[ -f "$SCRIPT_DIR/proxy/.cache/ca.pem" ]] && echo "✓ $SCRIPT_DIR/proxy/.cache/ca.pem" || echo "✗ not yet generated")"
    echo ""
    echo "  Live state:"
    echo "    /etc/hosts entries:  $(hosts_present && echo "PRESENT" || echo "absent (correct — agy alone uses real Google)")"
    # Show shared session if any
    if [[ -d "$SESSION_DIR" ]] && [[ -f "$SESSION_PROXY_PID" ]]; then
        local lpid lbe
        lpid=$(cat "$SESSION_PROXY_PID" 2>/dev/null || true)
        lbe=$(cat "$SESSION_BACKEND" 2>/dev/null || true)
        if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
            local n_active=0
            if [[ -d "$SESSION_MEMBERS" ]]; then
                for f in "$SESSION_MEMBERS"/*; do
                    [[ -e "$f" ]] || continue
                    local mpid; mpid="$(basename "$f")"
                    kill -0 "$mpid" 2>/dev/null && n_active=$((n_active + 1))
                done
            fi
            echo "    Shared proxy:        PID $lpid (backend: ${lbe:-unknown})"
            echo "    Active sessions:     $n_active"
        else
            echo "    Shared proxy:        none (state is stale, will be cleaned on next launch)"
        fi
    else
        echo "    Shared proxy:        none"
    fi
    echo ""
    echo "  Keys:"
    echo "    KIMI_API_KEY:        $(mask_key "${KIMI_API_KEY:-}")"
    echo "    NVIDIA_API_KEY:      $(mask_key "${NVIDIA_API_KEY:-}")"
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

  Provider        Input/M    Output/M   Notes
  ----------      --------   --------   -----------
  Kimi Code       subscription          Anthropic-native, kimi-for-coding
  Nvidia NIM      \$0.44      \$0.87      OpenAI-compat (default kimi-k2.6)

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
deepantigravity — Use \`agy\` (Antigravity CLI) with Kimi or Nvidia NIM

USAGE
  deepantigravity --setup                    one-time, requires sudo password
  deepantigravity [-b BACKEND] [agy-args]    no sudo prompt during normal use
  deepantigravity --teardown                 uninstall everything
  deepantigravity --status                   diagnostic

BACKENDS (all routed through our local proxy)
  -b kimi                 Kimi Code             (Anthropic-native upstream)
  -b nv | nvidia          Nvidia NIM            (OpenAI-compat upstream)

To use real Google Gemini just run \`agy\` directly — deepantigravity adds
the /etc/hosts redirect only WHILE running, and removes it on exit.

PREREQUISITES
  * agy (Antigravity CLI)              https://antigravity.google/download
  * Node.js >= 18, npm
  * sudo access (only for --setup and --teardown; runtime needs no sudo)

CONFIG
  Edit proxy/.env. Set API_PROVIDER and at least one of KIMI_API_KEY,
  NVIDIA_API_KEY.

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
        nvidia)     if [[ -z "${NVIDIA_API_KEY:-}" || "$NVIDIA_API_KEY" =~ ^nvapi-your ]]; then echo "ERROR: NVIDIA_API_KEY not set in proxy/.env" >&2; exit 1; fi ;;
        *)          echo "ERROR: Unknown backend '$backend' (only kimi and nvidia are supported)" >&2; exit 1 ;;
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
    local stale_pid=""
    if command -v ss >/dev/null 2>&1; then
        stale_pid=$(ss -tlnp "sport = :$port" 2>/dev/null \
            | awk -F'pid=' '/LISTEN/{split($2,a,","); print a[1]}' | head -1)
    fi
    if [[ -z "$stale_pid" ]] && command -v lsof >/dev/null 2>&1; then
        stale_pid=$(timeout 3 lsof -ti tcp:"$port" -s TCP:LISTEN 2>/dev/null || true)
    fi
    if [[ -n "$stale_pid" ]]; then
        kill -9 "$stale_pid" 2>/dev/null || true
    fi

    # Strongest fallback: fuser -k. Sends SIGKILL to any process holding
    # the TCP port, regardless of whether ss/lsof saw the PID. This catches
    # orphaned daemons that were detached from the original launcher.
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -SIGKILL "$port"/tcp 2>/dev/null || true
    fi

    # Wait until the kernel has actually released the port.
    if ss -tln "sport = :$port" 2>/dev/null | grep -q LISTEN; then
        local n=0
        while [[ $n -lt 30 ]]; do
            if ! ss -tln "sport = :$port" 2>/dev/null | grep -q LISTEN; then break; fi
            sleep 0.1
            n=$((n + 1))
        done
    fi
}

# ────────────────────────────────────────────────────────────────
# Main launch path
# ────────────────────────────────────────────────────────────────
launch_agy() {
    # Pre-flight: setup must have been done
    if ! helper_installed || ! sudoers_installed; then
        echo "ERROR: setup not complete. Run:" >&2
        echo "  $0 --setup" >&2
        exit 1
    fi
    if ! node_has_bind_cap && [[ "$DEEPANTIGRAVITY_PORT" -lt 1024 ]]; then
        echo "ERROR: node lacks CAP_NET_BIND_SERVICE for port $DEEPANTIGRAVITY_PORT. Run:" >&2
        echo "  $0 --setup" >&2
        exit 1
    fi

    ensure_node_modules
    mkdir -p "$SESSION_DIR" "$SESSION_MEMBERS"

    # ── Atomic critical section: join existing session OR start a new one ──
    # flock serialises concurrent launches. Inside, we either:
    #   (a) JOIN: existing proxy alive + same backend → just register
    #   (b) REFUSE: existing proxy alive + different backend
    #   (c) START: no live proxy → spawn detached daemon, write session state
    {
        if ! flock -w 10 9; then
            echo "ERROR: could not acquire session lock within 10s — another launcher may be hung." >&2
            exit 1
        fi

        local existing_pid="" existing_backend=""
        [[ -f "$SESSION_PROXY_PID" ]] && existing_pid=$(cat "$SESSION_PROXY_PID" 2>/dev/null || true)
        [[ -f "$SESSION_BACKEND" ]]   && existing_backend=$(cat "$SESSION_BACKEND" 2>/dev/null || true)

        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # ── (a) or (b): a proxy is already running ──
            if [[ "$existing_backend" == "$RESOLVED_BACKEND" ]]; then
                # JOIN
                if [[ ! -f "$SESSION_BUNDLE" ]]; then
                    echo "ERROR: session is corrupted (proxy alive but ca-bundle missing)." >&2
                    echo "  Stop the running session and try again." >&2
                    exit 1
                fi
                touch "$SESSION_MEMBERS/$$"
                JOINED_SESSION=1
                local n_active; n_active=$(session_active_member_count)
                echo "  Joined shared session: backend=$existing_backend, proxy PID=$existing_pid ($n_active session(s) active)"
                export SSL_CERT_FILE="$SESSION_BUNDLE"
                export SSL_CERT_DIR="$(dirname "$SESSION_BUNDLE")"
            else
                # REFUSE
                local n_active; n_active=$(session_active_member_count)
                echo "ERROR: another deepantigravity session is running with a DIFFERENT backend" >&2
                echo "  Running backend: $existing_backend  (proxy PID $existing_pid, $n_active session(s) active)" >&2
                echo "  Requested:       $RESOLVED_BACKEND" >&2
                echo "" >&2
                echo "  All concurrent sessions on this machine must use the same backend" >&2
                echo "  (only one process can bind 127.0.0.1:443 and there's only one" >&2
                echo "  /etc/hosts redirect target)." >&2
                echo "" >&2
                echo "  Either re-run with -b $existing_backend, or stop the other sessions." >&2
                exit 1
            fi
        else
            # ── (c): no live proxy — start fresh ──
            # Clean stale session state (proxy was killed, members are dead)
            rm -f "$SESSION_PROXY_PID" "$SESSION_BACKEND" "$SESSION_BUNDLE" "$SESSION_LOG"
            rm -rf "$SESSION_MEMBERS"
            mkdir -p "$SESSION_MEMBERS"

            # Clean stale /etc/hosts (from a crashed previous session)
            if hosts_present; then
                echo "  Detected stale /etc/hosts entries — cleaning..."
                if ! sudo -n "$HELPER_INSTALLED" remove 2>/dev/null; then
                    echo "ERROR: passwordless sudo for the helper failed. Run --teardown then --setup." >&2
                    exit 1
                fi
                sleep 0.1
            fi

            # Resolve real Google IPs BEFORE hijacking /etc/hosts.
            # systemd-resolved serves /etc/hosts even on direct DNS queries.
            local cloudcode_ip="" daily_ip=""
            cloudcode_ip=$(getent ahostsv4 cloudcode-pa.googleapis.com 2>/dev/null | awk 'NR==1{print $1}')
            daily_ip=$(getent ahostsv4 daily-cloudcode-pa.googleapis.com 2>/dev/null | awk 'NR==1{print $1}')
            if [[ -z "$cloudcode_ip" || "$cloudcode_ip" == "127.0.0.1" ]]; then
                echo "ERROR: could not resolve real IP of cloudcode-pa.googleapis.com (got: '$cloudcode_ip')" >&2
                exit 1
            fi
            [[ -z "$daily_ip" || "$daily_ip" == "127.0.0.1" ]] && daily_ip="$cloudcode_ip"
            echo "  Real IPs: cloudcode-pa → $cloudcode_ip, daily-cloudcode-pa → $daily_ip"

            echo "  Adding /etc/hosts redirect for cloudcode-pa.googleapis.com..."
            if ! sudo -n "$HELPER_INSTALLED" add 2>/dev/null; then
                echo "ERROR: passwordless sudo for the helper failed. Run --setup again." >&2
                exit 1
            fi

            free_port "$DEEPANTIGRAVITY_PORT"

            # Spawn proxy DETACHED (nohup + setsid) so it survives this
            # leader's exit. The proxy writes port + CA path on stdout
            # within ~1s, then keeps running.
            : > "$SESSION_LOG"
            echo "  Starting deepantigravity TLS server → $RESOLVED_BACKEND ..."

            local nohup_or_setsid="setsid"
            command -v setsid >/dev/null 2>&1 || nohup_or_setsid="nohup"
            # IMPORTANT: 9<&- closes FD 9 in the spawned proxy. Otherwise
            # the proxy inherits the launcher's flock-holder FD and the
            # lock stays held FOR THE ENTIRE LIFE OF THE PROXY (because
            # flock is released only when ALL FDs on the open file
            # description close). Subsequent launchers would deadlock on
            # `flock 9` until the proxy itself died.
            $nohup_or_setsid env \
                DEEPANTIGRAVITY_REAL_IP_CLOUDCODE="$cloudcode_ip" \
                DEEPANTIGRAVITY_REAL_IP_DAILY="$daily_ip" \
                ${DEEPANTIGRAVITY_DEBUG:+DEEPANTIGRAVITY_DEBUG="$DEEPANTIGRAVITY_DEBUG"} \
                node "$SCRIPT_DIR/proxy/start-proxy.js" "$RESOLVED_BACKEND" "$DEEPANTIGRAVITY_PORT" \
                > "$SESSION_LOG" 2>&1 < /dev/null 9<&- &
            local proxy_pid=$!
            disown 2>/dev/null || true

            # Wait for "port-number\nca-path" lines to appear on stdout.
            local tries=0
            while [[ $tries -lt 60 ]]; do
                if [[ -s "$SESSION_LOG" ]] && grep -q '^[0-9]\+$' "$SESSION_LOG" 2>/dev/null; then
                    break
                fi
                if ! kill -0 "$proxy_pid" 2>/dev/null; then
                    echo "ERROR: proxy died on startup. Last log lines:" >&2
                    tail -20 "$SESSION_LOG" >&2 2>/dev/null || true
                    sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
                    exit 1
                fi
                sleep 0.1
                tries=$((tries + 1))
            done

            local proxy_port ca_path
            proxy_port=$(grep -m1 '^[0-9]\+$' "$SESSION_LOG" || true)
            ca_path=$(grep -m1 '^/' "$SESSION_LOG" || true)
            if [[ -z "$proxy_port" ]] || [[ -z "$ca_path" ]] || [[ ! -f "$ca_path" ]]; then
                echo "ERROR: proxy startup output unexpected. Log:" >&2
                tail -20 "$SESSION_LOG" >&2 2>/dev/null || true
                kill -9 "$proxy_pid" 2>/dev/null || true
                sudo -n "$HELPER_INSTALLED" remove 2>/dev/null || true
                exit 1
            fi

            # Build combined CA bundle (our local CA + system roots) so
            # non-cloudcode-pa TLS still validates.
            local system_ca=""
            for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
                     /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem; do
                if [[ -f "$f" ]]; then system_ca="$f"; break; fi
            done
            if [[ -n "$system_ca" ]]; then
                cat "$ca_path" "$system_ca" > "$SESSION_BUNDLE"
            else
                cp "$ca_path" "$SESSION_BUNDLE"
                echo "  WARNING: system CA bundle not found; non-Google TLS may fail" >&2
            fi

            # Record session state and register self as first member
            echo "$proxy_pid" > "$SESSION_PROXY_PID"
            echo "$RESOLVED_BACKEND" > "$SESSION_BACKEND"
            touch "$SESSION_MEMBERS/$$"
            JOINED_SESSION=1

            echo "  TLS server on 127.0.0.1:$proxy_port  → $RESOLVED_BACKEND  (proxy PID $proxy_pid)"
            echo "  CA bundle: $SESSION_BUNDLE"

            export SSL_CERT_FILE="$SESSION_BUNDLE"
            export SSL_CERT_DIR="$(dirname "$SESSION_BUNDLE")"
        fi
    } 9>"$SESSION_LOCK"

    echo ""

    # Run agy in foreground. Trap fires session_leave on exit, which
    # decrements refcount and tears down the proxy + /etc/hosts only
    # if we were the last active session.
    set +e
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
