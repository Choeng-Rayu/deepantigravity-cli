# deepantigravity

Run Google's **Antigravity CLI** (`agy`) with **Kimi Code** or **Nvidia NIM** as the brain instead of Gemini.

You get the full Antigravity experience — agentic loop, browser agent, file editing, terminal sandbox — powered by a different model.

> **Sister project:** Antigravity equivalent of [deepclaude-cli](https://github.com/d-kuro/deepclaude-cli). Same concept, harder interception.

---

## What it does

| Command | What happens |
|---|---|
| `./deepantigravity.sh -b kimi` | Routes `agy` through a local proxy → Kimi Code |
| `./deepantigravity.sh -b nv` | Routes `agy` through a local proxy → Nvidia NIM |
| `agy` (alone) | Talks to real Google Gemini, completely unchanged |

**Zero persistent state.** The `/etc/hosts` redirect exists only while `deepantigravity` is running. When it exits, your system is exactly as before.

---

## Why `/etc/hosts`?

`agy` is a Go binary that hardcodes its endpoint and ignores `HTTPS_PROXY`, `LD_PRELOAD`, and environment-based endpoint overrides. The only way to intercept it is at the DNS/resolver level.

```
agy ──resolves cloudcode-pa.googleapis.com → 127.0.0.1──► deepantigravity proxy ──► Kimi / Nvidia
         (via /etc/hosts, only during session)              (TLS on localhost:443)
```

The proxy:
1. Generates a local CA + leaf cert for `cloudcode-pa.googleapis.com`
2. Translates Gemini API calls → Anthropic (Kimi) or OpenAI (Nvidia)
3. Streams responses back in Gemini format

---

## Quick start

### 1. Prerequisites

- `agy` installed and logged in ([antigravity.google/download](https://antigravity.google/download))
- Node.js ≥ 18
- `sudo` access (one-time only)

### 2. Install

```bash
git clone https://github.com/<you>/deepantigravity-cli.git
cd deepantigravity-cli
cd proxy && npm install && cd ..

cp proxy/.env.example proxy/.env
nano proxy/.env       # add your KIMI_API_KEY and/or NVIDIA_API_KEY
chmod +x deepantigravity.sh
```

### 3. One-time setup

```bash
./deepantigravity.sh --setup
./deepantigravity.sh --status    # verify all ✓
```

This installs a privileged helper, a sudoers rule, and grants port-binding capability to Node. After this, **no more sudo needed**.

### 4. Run

```bash
./deepantigravity.sh              # uses default from API_PROVIDER in .env
./deepantigravity.sh -b kimi      # Kimi Code
./deepantigravity.sh -b nv        # Nvidia NIM
```

### 5. Uninstall

```bash
./deepantigravity.sh --teardown
```

---

## Backends

| Backend | Flag | Cost | Notes |
|---|---|---|---|
| **Kimi Code** | `-b kimi` | Subscription | Model: `kimi-for-coding` |
| **Nvidia NIM** | `-b nv` | Pay-per-token | Model: `moonshotai/kimi-k2.6` (swappable) |

### Configuration (`proxy/.env`)

```ini
# Kimi
API_PROVIDER=kimi
KIMI_API_KEY=sk-your-key          # from https://www.kimi.com/code/console
KIMI_MODEL=kimi-for-coding

# Nvidia
API_PROVIDER=nvidia
NVIDIA_API_KEY=nvapi-your-key     # from https://build.nvidia.com
NVIDIA_MODEL=moonshotai/kimi-k2.6
```

---

## Important: single-session only

Only one `deepantigravity` session can run at a time (one process owns port 443 and the `/etc/hosts` redirect). Stop the current session before starting another.

Check status: `./deepantigravity.sh --status`

---

## Security

The one-time setup installs:

1. **`/usr/local/bin/deepantigravity-helper`** — only adds/removes the hosts entry. Root-owned, mode 0755.
2. **`/etc/sudoers.d/deepantigravity`** — allows passwordless execution of the helper only. Validated with `visudo`.
3. **`CAP_NET_BIND_SERVICE` on node** — lets node bind port 443 without root. Note: this applies to all node scripts on your system.

The local CA key stays at `proxy/.cache/ca-key.pem` (mode 0600). Only `cloudcode-pa.googleapis.com` traffic is redirected — all other Google endpoints (OAuth, telemetry, etc.) go to real Google.

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `API_PROVIDER` | No | `kimi` | Default backend |
| `KIMI_API_KEY` | For Kimi | — | API key |
| `KIMI_MODEL` | No | `kimi-for-coding` | Model name |
| `NVIDIA_API_KEY` | For Nvidia | — | API key |
| `NVIDIA_MODEL` | No | `moonshotai/kimi-k2.6` | Model name |
| `DEEPANTIGRAVITY_DEBUG` | No | — | Set `1` to log requests to `proxy/.cache/requests/` |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| agy returns real Gemini answers | Run `--status`, re-run `--setup` if anything is missing |
| `agy` alone gives "connection refused" | Previous session crashed. Run `--teardown` |
| x509 certificate error | Run `--setup` again to rebuild the CA bundle |
| EACCES bind port 443 | Run `--setup` again (re-grants capability) |

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for detailed solutions or [`HOW_TO_USE.md`](HOW_TO_USE.md) for the full practical guide.

---

## Project structure

```
deepantigravity-cli/
├── deepantigravity.sh          # Main launcher (Linux/macOS)
├── deepantigravity.ps1         # Main launcher (Windows)
├── HOW_TO_USE.md               # Practical usage guide
├── TROUBLESHOOTING.md          # Common issues and fixes
├── CONTRIBUTING.md             # How to contribute
├── proxy/
│   ├── .env.example            # Template for API keys
│   ├── cert.js                 # CA + leaf cert generator
│   ├── gemini-translator.js    # Gemini ↔ Anthropic translation
│   ├── openai-translator.js    # Anthropic ↔ OpenAI for Nvidia
│   ├── model-proxy.js          # HTTPS proxy server
│   ├── start-proxy.js          # Entry point
│   └── deepantigravity-helper.sh  # Privileged helper
└── README.md
```

---

## License

MIT
