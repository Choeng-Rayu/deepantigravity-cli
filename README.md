# deepantigravity

Use Google's **Antigravity CLI** (`agy`) — but with **Kimi Code** or **Nvidia NIM** instead of Gemini.

Same Antigravity UX. Same agentic loop, browser agent, file editing, terminal sandbox. Different brain.

> **Sister project:** This is the Antigravity equivalent of [deepclaude-cli](https://github.com/d-kuro/deepclaude-cli). Same idea, different host CLI, **harder interception**.

---

## Design goal

- **`deepantigravity -b kimi`** → routes through our local proxy to Kimi Code.
- **`deepantigravity -b nv`** → routes through our local proxy to Nvidia NIM.
- **`agy`** (run alone) → still talks to real Google Gemini, completely unchanged.
- **No persistent system state.** The `/etc/hosts` redirect is added at launch and removed on exit. If `deepantigravity` isn't running, your machine is exactly as it was before you installed it.

---

## How it works (and why it's harder than `deepclaude-cli`)

| | `claude` (Claude Code) | `agy` (Antigravity CLI) |
|---|---|---|
| Endpoint override | `ANTHROPIC_BASE_URL` env var ✅ | **None.** Endpoint is hardcoded. |
| `HTTPS_PROXY` | Honored ✅ | **Ignored** ❌ (verified by `strace`) |
| `LD_PRELOAD` libc hooks | Works ✅ | **Ignored** ❌ (Go uses raw syscalls) |
| `SSL_CERT_FILE` | n/a | Honored ✅ |
| Auth | API key in env var | OAuth2 tokens in `~/.gemini/oauth_creds.json` |

So we cannot just swap an env var or load a shim library. The only interception that works is **at the OS resolver layer** — `/etc/hosts`.

```
   ┌─────────┐  resolves cloudcode-pa.googleapis.com → 127.0.0.1
   │   agy   │  (because /etc/hosts says so DURING our session)
   │  (Go)   │  ───────────────────────────────────────────────────► ┌─────────────┐
   │         │  TLS connect to 127.0.0.1:443                         │  Kimi Code  │
   │         │             ┌──────────────────────────┐              │  /          │
   │         │ ◄──TLS────► │  deepantigravity proxy   │ ◄──HTTPS───► │  Nvidia NIM │
   │         │             │  on 127.0.0.1:443        │              │             │
   │         │             │                          │              └─────────────┘
   └─────────┘             │  - Generates a local CA  │
                           │  - Mints leaf cert for   │
                           │    cloudcode-pa...       │
                           │  - Translates Gemini API │
                           │    → Anthropic (Kimi) /  │
                           │    → Anthropic → OpenAI  │
                           │    (Nvidia)              │
                           │  - Translates SSE back   │
                           └──────────────────────────┘
```

Setup once with `sudo` to:

1. Add `127.0.0.1 cloudcode-pa.googleapis.com` to `/etc/hosts` (per-launch only — added on launch, removed on exit).
2. Install a privileged helper + passwordless sudo rule that lets the launcher add/remove the hosts entries without a password.
3. Grant `CAP_NET_BIND_SERVICE` to the `node` binary so it can bind port 443 without root.

After setup, **subsequent runs need no sudo at all**.

---

## Quick start

### 1. Install `agy`

```bash
# Follow https://antigravity.google/download
agy --version
agy install     # one-time Google OAuth login
```

### 2. Install deepantigravity

```bash
git clone https://github.com/<you>/deepantigravity-cli.git
cd deepantigravity-cli
cd proxy && npm install && cd ..

cp proxy/.env.example proxy/.env
nano proxy/.env       # paste your KIMI_API_KEY and/or NVIDIA_API_KEY

chmod +x deepantigravity.sh
```

### 3. One-time setup (sudo password required ONCE)

```bash
./deepantigravity.sh --setup
```

Verify:

```bash
./deepantigravity.sh --status
# Should show all four ✓:
#   ✓ Helper installed   /usr/local/bin/deepantigravity-helper
#   ✓ Sudoers rule       /etc/sudoers.d/deepantigravity
#   ✓ node bind cap      CAP_NET_BIND_SERVICE on /usr/bin/node
#   ✓ CA cert            .../proxy/.cache/ca.pem
#   /etc/hosts entries: absent (correct — agy alone uses real Google)
```

### 4. Use it (no sudo prompt)

```bash
./deepantigravity.sh                       # default backend from API_PROVIDER (kimi)
./deepantigravity.sh -b kimi               # Kimi Code (subscription)
./deepantigravity.sh -b nv                 # Nvidia NIM (default kimi-k2.6)
```

### 5. Use real Gemini

```bash
agy                                         # talks to real Google directly
```

### 6. Uninstall

```bash
./deepantigravity.sh --teardown
```

---

## Supported backends

| Backend | Flag | Cost | Protocol | Notes |
|---|---|---|---|---|
| **Kimi Code** | `-b kimi` | subscription | Anthropic-native | `kimi-for-coding` |
| **Nvidia NIM** | `-b nv` | $0.44 / $0.87 per M | OpenAI-compat (translated) | default `moonshotai/kimi-k2.6` |

---

## Provider Setup

### Kimi Code

```ini
# proxy/.env
API_PROVIDER=kimi
KIMI_API_KEY=sk-your-kimi-key
KIMI_MODEL=kimi-for-coding
```

Get a key from <https://www.kimi.com/code/console>.

### Nvidia NIM

```ini
API_PROVIDER=nvidia
NVIDIA_API_KEY=nvapi-your-nvidia-key
NVIDIA_MODEL=moonshotai/kimi-k2.6
```

Get a key from <https://build.nvidia.com>. You can swap `NVIDIA_MODEL` for any chat-completion model on Build.NVIDIA.

---

## Project structure

```
deepantigravity-cli/
├── deepantigravity.sh              # Main launcher (Linux/macOS)
├── deepantigravity.ps1             # Main launcher (Windows)
├── HOW_TO_USE.md                   # Practical usage guide
├── proxy/
│   ├── .env                        # Your API keys (gitignored)
│   ├── .env.example                # Template
│   ├── package.json                # node-forge dependency
│   ├── deepantigravity-helper.sh   # Privileged helper (installed by --setup)
│   ├── cert.js                     # Self-signed CA + leaf cert generator
│   ├── gemini-translator.js        # Gemini ↔ Anthropic translator
│   ├── openai-translator.js        # Anthropic ↔ OpenAI for Nvidia
│   ├── model-proxy.js              # HTTPS server impersonating cloudcode-pa.googleapis.com
│   ├── start-proxy.js              # Proxy entry point
│   ├── README.md                   # Proxy technical details
│   └── .cache/                     # Generated CA + bundle (gitignored)
└── README.md                       # This file
```

---

## Security model

The **one-time** setup installs:

1. **`/usr/local/bin/deepantigravity-helper`** — root-owned, mode 0755. Reads exactly one argument (`add` or `remove`). Does nothing else.
2. **`/etc/sudoers.d/deepantigravity`** — root-owned, mode 0440. Validated via `visudo -c -f` before installing. Allows your user to run only:
   ```
   /usr/local/bin/deepantigravity-helper add
   /usr/local/bin/deepantigravity-helper remove
   ```
3. **`CAP_NET_BIND_SERVICE` on `/usr/bin/node`** — granted via `setcap`. Lets unprivileged users bind ports < 1024 with the node binary. **This is broader than ideal** — any node script you run can also bind privileged ports.

The CA private key is stored at `proxy/.cache/ca-key.pem` (mode 0600) and never leaves your machine.

`agy` continues to use your normal Google OAuth tokens (`~/.gemini/oauth_creds.json`) for telemetry, browser agent, artifact upload, etc. We don't redirect any of that traffic — only `cloudcode-pa.googleapis.com` model calls.

`SSL_CERT_FILE` is set to a **combined** trust bundle (our CA + the system CA bundle) so non-`cloudcode-pa` TLS connections continue to validate against Google's real certificates.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `API_PROVIDER` | No | Default backend (`kimi` or `nvidia`) |
| `DEEPANTIGRAVITY_PORT` | No | Listen port (keep at `443`) |
| `DEEPANTIGRAVITY_DEBUG` | No | Set to `1` to log every request body to `proxy/.cache/requests/` |
| `KIMI_API_KEY` | For Kimi | API key from kimi.com/code/console |
| `KIMI_MODEL` | No | Default `kimi-for-coding` |
| `NVIDIA_API_KEY` | For Nvidia | API key from build.nvidia.com |
| `NVIDIA_MODEL` | No | Default `moonshotai/kimi-k2.6` |

---

## Single-session constraint

Only **one** `deepantigravity` session can run at a time. If you try to launch a second one while the first is still active, you'll see:

```
ERROR: another deepantigravity session is already running
  PID:     12345
  Backend: kimi

  Only one session can run at a time. Stop the other one first
  (Ctrl-C in its terminal, or 'kill 12345').
```

Why: only one process can bind `127.0.0.1:443`, `/etc/hosts` only has one redirect target, and `agy` has no way to tell the proxy which backend it wants. The lock file `proxy/.cache/deepantigravity.pid` stores the active session.

Run `./deepantigravity.sh --status` to see whether a session is currently running.

---

## Troubleshooting

See `HOW_TO_USE.md` for the practical guide. Most common issues:

- **agy returns real Gemini answers, not the chosen backend** → run `./deepantigravity.sh --status` and re-run `--setup` if any setup component is missing.
- **`agy` alone fails with `connection refused`** → previous session crashed. Run `./deepantigravity.sh --teardown` then continue.
- **`x509: certificate signed by unknown authority`** → the bundle wasn't built. Run `./deepantigravity.sh --setup` again.

---

## License

MIT
