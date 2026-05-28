# Security Policy

## What this tool does to your system

1. **`/etc/hosts` modification** — Adds a redirect during active sessions only. Removed on exit.
2. **Local CA certificate** — Stored at `proxy/.cache/ca-key.pem` (mode 0600). Never leaves your machine.
3. **Privileged helper** — `/usr/local/bin/deepantigravity-helper` can only add/remove one specific hosts entry.
4. **Sudoers rule** — Allows passwordless execution of the helper only. No other commands.
5. **CAP_NET_BIND_SERVICE** — Granted to `/usr/bin/node`. Note: this affects all Node.js scripts system-wide.

## Scope of interception

Only `cloudcode-pa.googleapis.com` traffic is redirected. All other endpoints (Google OAuth, telemetry, other APIs) go to their real destinations.

## API key storage

Keys are stored in `proxy/.env` (gitignored). They are only sent to their respective upstream providers (Kimi or Nvidia).

## Reporting a vulnerability

If you find a security issue, please open a private issue or email the maintainer directly. Do not open a public issue for security vulnerabilities.

## Recommendations

- Review `proxy/deepantigravity-helper.sh` before running `--setup`
- Keep `proxy/.cache/` permissions restricted
- Run `--teardown` if you no longer use the tool
