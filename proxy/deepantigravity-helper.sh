#!/usr/bin/env bash
# deepantigravity-helper — privileged helper that ONLY edits the
# deepantigravity sentinel block in /etc/hosts.
#
# This is installed to /usr/local/bin/deepantigravity-helper (owned by
# root, mode 0755) by `deepantigravity --setup`. A matching sudoers rule
# at /etc/sudoers.d/deepantigravity lets the installing user run it
# without a password, BUT ONLY with these two specific argument forms:
#
#   sudo deepantigravity-helper add      # add the sentinel block
#   sudo deepantigravity-helper remove   # remove it
#
# Any other invocation just exits 0 without doing anything, so abuse
# of the NOPASSWD rule is contained to flipping these specific lines
# in /etc/hosts.

set -euo pipefail

HOSTS_FILE="/etc/hosts"
SENTINEL_BEGIN="# >>> deepantigravity BEGIN <<<"
SENTINEL_END="# >>> deepantigravity END <<<"
HIJACKED=(
    "cloudcode-pa.googleapis.com"
    "daily-cloudcode-pa.googleapis.com"
)

action="${1:-}"

case "$action" in
    add)
        # Idempotent — if already present, exit successfully.
        if grep -qF "$SENTINEL_BEGIN" "$HOSTS_FILE"; then
            exit 0
        fi
        {
            echo ""
            echo "$SENTINEL_BEGIN"
            for h in "${HIJACKED[@]}"; do echo "127.0.0.1 $h"; done
            echo "$SENTINEL_END"
        } >> "$HOSTS_FILE"
        ;;
    remove)
        # Idempotent — if not present, just exit.
        if ! grep -qF "$SENTINEL_BEGIN" "$HOSTS_FILE"; then
            exit 0
        fi
        # Remove the block (BSD-compatible: use temp file, no `sed -i`
        # on macOS edge cases).
        tmp=$(mktemp /tmp/deepantigravity-hosts-XXXXXX)
        awk -v begin="$SENTINEL_BEGIN" -v end="$SENTINEL_END" '
            $0 == begin { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "$HOSTS_FILE" > "$tmp"
        # Preserve original permissions/ownership
        chmod --reference="$HOSTS_FILE" "$tmp" 2>/dev/null \
            || chmod 644 "$tmp"
        chown --reference="$HOSTS_FILE" "$tmp" 2>/dev/null \
            || chown root:root "$tmp"
        mv "$tmp" "$HOSTS_FILE"
        ;;
    *)
        # Unknown action — exit silently. This narrows the blast radius
        # of the NOPASSWD sudoers rule.
        exit 0
        ;;
esac
