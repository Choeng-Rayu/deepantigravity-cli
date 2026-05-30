# How to Use deepantigravity

Step-by-step practical guide. For architecture details, see `README.md`.

> **Note:** This guide covers Linux/macOS. For Windows, use `deepantigravity.ps1` instead.

---

## Quick start (30 seconds if already set up)

```bash
./deepantigravity.sh -b kimi      # use Kimi Code
./deepantigravity.sh -b nv        # use Nvidia NIM
./deepantigravity.sh -b deepseek  # use DeepSeek web session (emulated tools)
./deepantigravity.sh --help       # show all options
agy                                # use real Gemini (unchanged)
```

---

## Step 1: Install prerequisites

You need three things:

1. **`agy`** — install from [antigravity.google/download](https://antigravity.google/download), then run `agy install` to log in
2. **Node.js ≥ 18** — check with `node --version`
3. **sudo access** — needed once during setup

---

## Step 2: Clone and configure

```bash
git clone https://github.com/<you>/deepantigravity-cli.git
cd deepantigravity-cli
cd proxy && npm install && cd ..
chmod +x deepantigravity.sh
```

Set up your API keys:

```bash
cp proxy/.env.example proxy/.env
nano proxy/.env
```

Add at least one backend key:

```ini
# Pick one (or both):
API_PROVIDER=kimi                  # default backend when no -b flag

KIMI_API_KEY=sk-your-key           # get from https://www.kimi.com/code/console
NVIDIA_API_KEY=nvapi-your-key      # get from https://build.nvidia.com
```

---

## Step 3: Run one-time setup

```bash
./deepantigravity.sh --setup
```

This does three things (requires sudo once):
- Installs a helper script that can add/remove the `/etc/hosts` redirect
- Adds a sudoers rule so daily use needs no password
- Grants Node.js the ability to bind port 443

Verify everything worked:

```bash
./deepantigravity.sh --status
```

All items should show ✓. After this, **no more sudo needed**.

---

## Step 4: Use it

### Basic usage

```bash
./deepantigravity.sh              # uses default backend from .env
./deepantigravity.sh -b kimi      # force Kimi Code
./deepantigravity.sh -b nv        # force Nvidia NIM
./deepantigravity.sh -b deepseek  # force DeepSeek web session (emulated tools)
./deepantigravity.sh --status     # check setup and running state
```

### Pass arguments to agy

Everything after `--` goes to `agy`:

```bash
./deepantigravity.sh -b kimi -- --print "explain this code"
./deepantigravity.sh -b nv -- --add-dir ./src --print "find the bug"
./deepantigravity.sh -b kimi -- --continue
```

### Use real Gemini (no proxy)

```bash
agy                               # works normally when deepantigravity isn't running
```

---

## Step 5: Switch backends

Three ways:

| Method | How |
|---|---|
| Per-launch flag | `./deepantigravity.sh -b kimi` or `-b nv` |
| Change default | Edit `API_PROVIDER=nvidia` in `proxy/.env` |
| Change model | Edit `NVIDIA_MODEL=` or `KIMI_MODEL=` in `proxy/.env` |

---

## Optional: DeepSeek web session backend (`-b deepseek`)

This backend drives the **`chat.deepseek.com` web chat** instead of the
paid API, so it works with a normal DeepSeek website login (no API key).

> **Tools are emulated.** The web endpoint has no *native* tool-calling, so
> the proxy describes the tools in the prompt and parses `<tool_call>`
> markers back into real actions. Agentic features (file edits, terminal,
> etc.) **do work**, but less reliably than on a native API backend — a
> model may occasionally describe an action instead of emitting the marker.
> For the most reliable agentic use, prefer an API-key backend (Kimi,
> Nvidia, or a DeepSeek `sk-` API key).

### Get the two secrets from your browser

Open `chat.deepseek.com`, log in, then press **F12**:

1. **Token** — Application → Local Storage → `https://chat.deepseek.com`
   → key `userToken` → copy its `value`.
2. **Cookie** — Network → click any `api/v0/...` request → Request Headers
   → copy the **entire** `cookie:` value (it must contain `ds_session_id`
   and `aws-waf-token`).

### Put them in `proxy/.env`

```ini
DEEPSEEK_OAUTH_WEB_TOKEN=<the userToken value>
DEEPSEEK_OAUTH_WEB_MODEL=deepseek-v4-pro
DEEPSEEK_OAUTH_WEB_COOKIE=aws-waf-token=...; ds_session_id=...
```

> Defaults to the expert model **`deepseek-v4-pro`** with reasoning
> ("thinking") **on** and DeepSeek V4's full **1M-token context**. Disable
> thinking with `DEEPSEEK_OAUTH_WEB_THINKING=0`.

### Run it

```bash
./deepantigravity.sh -b deepseek -- --print "what is 6*7?"
#   → 6 × 7 = 42
```

> **Credentials expire.** When answers start failing with 401 / "WAF" /
> "please wait" errors, the token or cookie has lapsed — re-grab both from
> the browser. Treat them like passwords; anyone with them can use your
> DeepSeek account.

---

## Debugging

Enable verbose logging:

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi -- --print "test"
```

This logs request/response bodies to `proxy/.cache/requests/` and shows translation details in the terminal.

Check token usage: `./deepantigravity.sh --cost`

---

## Troubleshooting

For detailed solutions, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### "another deepantigravity session is already running"

Only one session can run at a time. Check what's running:

```bash
./deepantigravity.sh --status
```

Stop it with Ctrl-C in its terminal or `kill <PID>`, then start a new one.

### agy returns real Gemini answers (not Kimi/Nvidia)

The proxy isn't intercepting. Fix:

```bash
./deepantigravity.sh --status     # check for ✗ marks
./deepantigravity.sh --setup      # re-run if anything missing
```

### `agy` alone gives "connection refused"

A previous session crashed without cleanup:

```bash
./deepantigravity.sh --teardown   # removes stale /etc/hosts entry
agy                                # works again
```

### x509 certificate error

CA bundle is missing or stale:

```bash
./deepantigravity.sh --setup      # rebuilds CA + bundle
```

### EACCES bind port 443

Node lost its port-binding capability:

```bash
./deepantigravity.sh --setup      # re-grants CAP_NET_BIND_SERVICE
```

### Nuclear reset (if everything is broken)

```bash
./deepantigravity.sh --teardown && rm -rf proxy/.cache && ./deepantigravity.sh --setup
```

---

## Uninstall

```bash
./deepantigravity.sh --teardown
```

This removes the helper, sudoers rule, node capability, and any `/etc/hosts` entries.

To fully remove:

```bash
rm -rf ~/deepantigravity-cli
```

---

## Optional: add to PATH

```bash
sudo ln -s "$(pwd)/deepantigravity.sh" /usr/local/bin/deepantigravity
deepantigravity -b kimi
deepantigravity --status
```
