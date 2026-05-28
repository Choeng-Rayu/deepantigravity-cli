# How to use deepantigravity

A practical guide. For the design rationale and architecture, see `README.md`.

This build supports exactly two backends: **Kimi Code** and **Nvidia NIM**.

---

## TL;DR

```bash
# One-time setup (sudo password required ONCE)
cd ~/deepantigravity-cli
./deepantigravity.sh --setup

# Use it
./deepantigravity.sh -b kimi          # routes agy through Kimi Code
./deepantigravity.sh -b nv            # routes agy through Nvidia NIM
agy                                    # still works normally (real Gemini)
```

---

## 1. First-time installation

### Prerequisites

- `agy` (Antigravity CLI) installed and logged in: <https://antigravity.google/download>
- Node.js ≥ 18
- `sudo` access (only for `--setup` and `--teardown`; daily use is sudo-free)

### Steps

```bash
# 1. Clone / enter the repo
cd ~/deepantigravity-cli

# 2. Install proxy dependencies
cd proxy && npm install && cd ..

# 3. Configure your API keys
cp proxy/.env.example proxy/.env
nano proxy/.env
```

In `proxy/.env`, set at least one of:

```ini
API_PROVIDER=kimi              # default backend (kimi or nvidia)

KIMI_API_KEY=sk-…              # from https://www.kimi.com/code/console
KIMI_MODEL=kimi-for-coding

NVIDIA_API_KEY=nvapi-…         # from https://build.nvidia.com
NVIDIA_MODEL=moonshotai/kimi-k2.6
```

```bash
# 4. One-time setup — needs your sudo password ONCE
./deepantigravity.sh --setup
```

Setup installs:

| | What | Where |
|---|---|---|
| 1 | Privileged helper script (only edits the deepantigravity sentinel block in `/etc/hosts`) | `/usr/local/bin/deepantigravity-helper` |
| 2 | Passwordless sudo rule (allows your user to call the helper without a password — locked to two argument forms only) | `/etc/sudoers.d/deepantigravity` |
| 3 | `CAP_NET_BIND_SERVICE` capability on `/usr/bin/node` | system |

After this, **daily use needs no sudo**.

```bash
# 5. Verify
./deepantigravity.sh --status
```

Expected:

```
Setup state:
  Helper installed:    ✓ /usr/local/bin/deepantigravity-helper
  Sudoers rule:        ✓ /etc/sudoers.d/deepantigravity
  node bind cap:       ✓ CAP_NET_BIND_SERVICE on /usr/bin/node
  CA cert:             ✓ /home/you/deepantigravity-cli/proxy/.cache/ca.pem

Live state:
  /etc/hosts entries:  absent (correct — agy alone uses real Google)
```

---

## 2. Daily use

```bash
./deepantigravity.sh -b kimi    # Kimi Code (subscription, kimi-for-coding)
./deepantigravity.sh -b nv      # Nvidia NIM (default moonshotai/kimi-k2.6)
```

No flag → uses `API_PROVIDER` from `proxy/.env`.

### Pass arguments to agy

Anything after `--` (or any unrecognized arg) is forwarded to `agy`:

```bash
./deepantigravity.sh -b kimi -- --print "explain this code"
./deepantigravity.sh -b nv -- --add-dir ./src --print "where's the auth bug?"
./deepantigravity.sh -b kimi -- --continue              # resume last conversation
```

### Run agy normally (real Gemini)

```bash
agy
agy --print "hello"
```

`/etc/hosts` is only modified for the lifetime of a `deepantigravity` session.

### Optional: put `deepantigravity` on PATH

```bash
sudo ln -s "$(pwd)/deepantigravity.sh" /usr/local/bin/deepantigravity
deepantigravity -b kimi
deepantigravity --status
```

---

## 3. Switching backends

Method 1 — per-launch flag:

```bash
./deepantigravity.sh -b kimi
./deepantigravity.sh -b nv
```

Method 2 — change the default in `proxy/.env`:

```ini
API_PROVIDER=nvidia
```

Method 3 — change which model the active backend uses:

```ini
KIMI_MODEL=kimi-for-coding                # default
NVIDIA_MODEL=moonshotai/kimi-k2.6          # default; any model from build.nvidia.com works
```

---

## 4. Inspect / debug

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi -- --print "test"
```

Expected output:

```
[proxy] >>> streamGenerateContent: model=gemini-3-flash-agent, contents=6, tools=19
[proxy]     translated → kimi: model=kimi-for-coding, messages=6, tools=19, max_tokens=...
[proxy]     POST https://api.kimi.com/coding/v1/messages (body=...b)
[proxy]     upstream replied: 200 OK
[proxy]     stream done: anthropic_in=...b, gemini_out=...b in N chunks
```

Captures live in:

```
proxy/.cache/requests/      # raw bodies of each call from agy
proxy/.cache/responses/     # SSE streams we sent back to agy
```

Other useful commands:

```bash
./deepantigravity.sh --help
./deepantigravity.sh --status
./deepantigravity.sh --cost
./deepantigravity.sh --ca-path
./deepantigravity.sh --install-ca   # OS-specific instructions for system trust (optional)
```

---

## 5. Troubleshooting

### "another deepantigravity session is already running"

Only one `deepantigravity` session can run at a time (it owns port 443, the
`/etc/hosts` redirect, and the lock file `proxy/.cache/deepantigravity.pid`).
The error message tells you the PID and backend of the running session:

```
ERROR: another deepantigravity session is already running
  PID:     12345
  Backend: kimi

  Only one session can run at a time. Stop the other one first
  (Ctrl-C in its terminal, or 'kill 12345').
```

To see the running session at any time: `./deepantigravity.sh --status`.

To run with a different backend: stop the current session (`kill <PID>` or
Ctrl-C in its terminal), then launch with `-b <backend>`.

### "agy gives me real Gemini answers, not Kimi/Nvidia"

Either the launcher exited before agy finished (so the `/etc/hosts` redirect was already removed), or `--setup` wasn't completed. Run:

```bash
./deepantigravity.sh --status
```

If any of the three setup components is `✗`, run `./deepantigravity.sh --setup` again.

### "agy gives me `connection refused` even when running plain agy"

A previous deepantigravity session crashed without removing the `/etc/hosts` entries.

```bash
./deepantigravity.sh --teardown
agy                                  # works again
```

### "passwordless sudo for the helper failed"

Re-run setup:

```bash
./deepantigravity.sh --setup
```

### "EACCES bind 0.0.0.0:443"

```bash
sudo setcap CAP_NET_BIND_SERVICE=+eip "$(readlink -f $(which node))"
```

Or just re-run `--setup`.

### "x509: certificate signed by unknown authority"

The combined CA bundle is missing. Run with debug to verify the bundle gets built:

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi
ls -la proxy/.cache/ca-bundle.pem    # should exist and be ~225 KB
```

If the file isn't created, check `/etc/ssl/certs/ca-certificates.crt` exists (it should on Ubuntu/Debian).

### "agy hangs and produces no output"

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi -- --print "hi"
```

Look for `upstream replied: 4XX/5XX` lines — that tells you the backend rejected the request.

---

## 6. Uninstalling

```bash
cd ~/deepantigravity-cli
./deepantigravity.sh --teardown
```

Removes:

- `/usr/local/bin/deepantigravity-helper`
- `/etc/sudoers.d/deepantigravity`
- `CAP_NET_BIND_SERVICE` from `/usr/bin/node`
- Any leftover `/etc/hosts` entries

Then optionally:

```bash
rm -rf ~/deepantigravity-cli
sudo rm -f /usr/local/bin/deepantigravity      # if you symlinked
```

---

## 7. One-paragraph summary

`agy` is a Go binary that hardcodes `cloudcode-pa.googleapis.com` and ignores `HTTPS_PROXY`. So when you launch `deepantigravity`, the launcher (1) resolves Google's real IP, (2) adds an `/etc/hosts` entry redirecting `cloudcode-pa.googleapis.com` to `127.0.0.1` via the privileged helper, (3) starts a Node.js HTTPS server on `127.0.0.1:443` that presents a TLS cert signed by our local CA, (4) sets `SSL_CERT_FILE` to a combined bundle (our CA + system CAs) so `agy` trusts both our cert and Google's real certs for non-cloudcode-pa endpoints, (5) execs `agy`. The proxy forwards `agy`'s bootstrap calls (loadCodeAssist, fetchAvailableModels, …) transparently to the real Google IP we captured in step 1, and intercepts only the model-generation calls (`/v1internal:streamGenerateContent`), translating them Gemini → Anthropic → Kimi (direct) or Gemini → Anthropic → OpenAI → Nvidia. On exit (success, error, Ctrl-C, or kill) the launcher removes the `/etc/hosts` entries so plain `agy` works normally again.
