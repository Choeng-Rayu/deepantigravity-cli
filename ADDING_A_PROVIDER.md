# Adding a New Provider to deepantigravity

This guide shows how to add a new LLM backend (provider) to
`deepantigravity`, using the **existing two backends as the template**:

- **`kimi`** — Anthropic-native upstream (no format translation needed)
- **`nvidia`** — OpenAI-compatible upstream (translated Gemini → Anthropic → OpenAI)

> Scope note: only add providers you can reach through a **sanctioned,
> programmatic credential** — an API key, or an official CLI's OAuth flow.
> Replaying a website's browser **session token** is out of scope: it
> breaks the provider's ToS, trips anti-abuse systems, and is unstable.
> Both example backends here use real API keys.

---

## 1. How interception works (the mental model)

`agy` (Antigravity CLI) is a Go binary that only talks to
`cloudcode-pa.googleapis.com`. deepantigravity transparently intercepts
that traffic and re-routes the model-generation calls to your chosen
backend:

```
agy ──TLS──► our local proxy (impersonates cloudcode-pa)
                 │
                 ├─ bootstrap calls (loadCodeAssist, fetchAvailableModels, …)
                 │     └─► forwarded to REAL Google (your account/tier stay intact)
                 │
                 └─ /v1internal:streamGenerateContent  (the actual model call)
                       └─► translated to YOUR backend:
                             • Anthropic-native  → forwardAnthropic()
                             • OpenAI-compatible → forwardOpenAI()
```

Interception is platform-specific but the proxy is shared:
- **Linux** — `bwrap` mount-ns gives each terminal its own `/etc/hosts`
  (so different backends can run in parallel, each on its own loopback IP).
- **macOS / Windows** — one global `/etc/hosts` redirect + one shared
  proxy on `127.0.0.1:443` (same-backend only).

You do **not** touch any of the OS-specific session logic when adding a
provider. You only declare the backend in a few well-defined spots.

---

## 2. Pick the provider's protocol

Decide which family your provider's API speaks. This determines whether
you reuse the Anthropic path or the OpenAI path — **no new translator is
needed for either**:

| Provider speaks… | Reuse | Example |
|---|---|---|
| Anthropic Messages API (`/v1/messages`) | `ANTHROPIC_NATIVE` | `kimi` |
| OpenAI Chat Completions (`/chat/completions`) | `OPENAI_COMPAT` | `nvidia` |

If it's neither (e.g. AWS Event Stream, a bespoke protocol), you'd need a
new translator module — that's a larger task, not covered here.

---

## 3. The five edits (worked example: adding `groq`)

Say you're adding **Groq** (OpenAI-compatible, API key `gsk_…`, model
`llama-3.3-70b-versatile`, endpoint `https://api.groq.com/openai/v1`).

### Edit 1 — `proxy/.env.example` and your `proxy/.env`

Declare the key + model so users know what to set:

```ini
# Groq (OpenAI-compatible)
GROQ_API_KEY=gsk-your-groq-key
GROQ_MODEL=llama-3.3-70b-versatile
# Optional: models shown in agy's /model picker (comma-separated)
# GROQ_MODELS=llama-3.3-70b-versatile,qwen-2.5-coder-32b
```

### Edit 2 — `proxy/start-proxy.js` → `BACKEND_DEFS` + `canonicalize()`

Add the upstream definition:

```js
const BACKEND_DEFS = {
    kimi:   { /* … */ },
    nvidia: { /* … */ },
    groq: {
        urlDefault:   'https://api.groq.com/openai/v1',
        keyEnv:       'GROQ_API_KEY',
        modelEnv:     'GROQ_MODEL',
        modelDefault: 'llama-3.3-70b-versatile',
    },
};
```

And teach `canonicalize()` any short aliases:

```js
function canonicalize(name) {
    switch (name) {
        case 'kimi':                 return 'kimi';
        case 'nv': case 'nvidia':    return 'nvidia';
        case 'gq': case 'groq':      return 'groq';   // NEW
        default:                     return name;
    }
}
```

### Edit 3 — `proxy/model-proxy.js` → protocol set

Put the backend in the correct set so the proxy knows which forwarder to
use (Groq is OpenAI-compatible):

```js
const ANTHROPIC_NATIVE = new Set(['kimi']);
const OPENAI_COMPAT    = new Set(['nvidia', 'groq']);   // add here
```

> Anthropic-native provider instead? Add it to `ANTHROPIC_NATIVE`.
> That's the only line that changes in `model-proxy.js`.

#### (Optional) selectable models in the `/model` picker

`selectableModels()` currently only injects extra models for `nvidia`.
To give your provider the same picker treatment, generalize it — e.g.:

```js
function selectableModels(opts) {
    const map = {
        nvidia: { env: 'NVIDIA_MODELS', def: DEFAULT_NVIDIA_MODELS },
        groq:   { env: 'GROQ_MODELS',   def: ['llama-3.3-70b-versatile',
                                              'qwen-2.5-coder-32b'] },
    };
    const cfg = map[opts.backend];
    if (!cfg) return [];
    const fromEnv = (process.env[cfg.env] || '').split(',')
        .map(s => s.trim()).filter(Boolean);
    const list = fromEnv.length ? fromEnv : cfg.def;
    if (opts.targetModel && !list.includes(opts.targetModel)) list.unshift(opts.targetModel);
    return list;
}
```

If you skip this, the provider still works — agy just shows Google's
model names (all routed to your one configured model).

### Edit 4 — `deepantigravity.sh` (Linux/macOS launcher)

Three small spots:

**(a) `canonicalize_backend()`** — map aliases:
```bash
canonicalize_backend() {
    case "$1" in
        nv|nvidia)     echo "nvidia" ;;
        kimi)          echo "kimi" ;;
        gq|groq)       echo "groq" ;;     # NEW
        *)             echo "$1" ;;
    esac
}
```

**(b) `resolve_backend()`** — validate the key is present:
```bash
    case "$backend" in
        kimi)    if [[ -z "${KIMI_API_KEY:-}" ... ]]; then ... fi ;;
        nvidia)  if [[ -z "${NVIDIA_API_KEY:-}" ... ]]; then ... fi ;;
        groq)    if [[ -z "${GROQ_API_KEY:-}" || "$GROQ_API_KEY" =~ ^gsk-your ]]; then
                     echo "ERROR: GROQ_API_KEY not set in proxy/.env" >&2; exit 1; fi ;;   # NEW
        *)       echo "ERROR: Unknown backend '$backend'" >&2; exit 1 ;;
    esac
```

**(c) `backend_ip()`** (Linux parallel-backend support) — give it a
unique loopback IP so it can run alongside other backends:
```bash
backend_ip() {
    case "$1" in
        kimi)   echo "127.0.10.1" ;;
        nvidia) echo "127.0.20.1" ;;
        groq)   echo "127.0.30.1" ;;     # NEW — must be unique
        *)      echo "127.0.0.1" ;;
    esac
}
```

### Edit 5 — `deepantigravity.ps1` (Windows launcher)

Mirror the alias + validation in `Convert-Backend` and `Resolve-Backend`:

```powershell
function Convert-Backend([string]$name) {
    switch ($name) {
        'nv'        { 'nvidia' }
        'nvidia'    { 'nvidia' }
        'kimi'      { 'kimi' }
        'gq'        { 'groq' }      # NEW
        'groq'      { 'groq' }      # NEW
        default     { $name }
    }
}

function Resolve-Backend {
    $b = Convert-Backend $Backend
    switch ($b) {
        'kimi'   { if (-not $env:KIMI_API_KEY ...)   { throw 'KIMI_API_KEY not set' } }
        'nvidia' { if (-not $env:NVIDIA_API_KEY ...) { throw 'NVIDIA_API_KEY not set' } }
        'groq'   { if (-not $env:GROQ_API_KEY)       { throw 'GROQ_API_KEY not set in proxy/.env' } }   # NEW
        default  { throw "Unknown backend: $b" }
    }
    return $b
}
```

> Windows/macOS share one proxy/backend at a time, so you don't need a
> per-backend loopback IP there — only Linux's `backend_ip()` needs the
> new unique address.

---

## 4. Test it

```bash
# 1. Put the key in proxy/.env
echo 'GROQ_API_KEY=gsk_...'                 >> proxy/.env
echo 'GROQ_MODEL=llama-3.3-70b-versatile'   >> proxy/.env

# 2. Quick end-to-end check (DEBUG keeps the proxy log on exit)
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b groq -- --print "what is 6*7?"

# 3. Verify the upstream actually served it (server-authoritative proof)
grep "UPSTREAM SERVER REPORTS" proxy/.cache/last-proxy-groq.log
#   → ✓ UPSTREAM SERVER REPORTS model="llama-3.3-70b-versatile" (host=api.groq.com, …)
```

The `UPSTREAM SERVER REPORTS` line reads the `model` field out of the
provider's **own response bytes** — it's the proof the answer came from
your new backend, not Google.

### Sanity checklist
- [ ] `node --check proxy/start-proxy.js && node --check proxy/model-proxy.js`
- [ ] `bash -n deepantigravity.sh`
- [ ] `./deepantigravity.sh -b <new> -- --print "ping"` returns an answer
- [ ] `grep "UPSTREAM SERVER REPORTS" proxy/.cache/last-proxy-<new>.log`
      shows your provider's host + model
- [ ] plain `agy` (no wrapper) still reaches real Gemini after exit
- [ ] (Linux) the new `backend_ip` is unique so it can run in parallel

---

## 5. Quick reference — files & symbols to touch

| File | Symbol | What to add |
|---|---|---|
| `proxy/.env(.example)` | — | `<NAME>_API_KEY`, `<NAME>_MODEL` |
| `proxy/start-proxy.js` | `BACKEND_DEFS` | upstream url/keyEnv/modelEnv/default |
| `proxy/start-proxy.js` | `canonicalize()` | short aliases |
| `proxy/model-proxy.js` | `ANTHROPIC_NATIVE` **or** `OPENAI_COMPAT` | one set entry |
| `proxy/model-proxy.js` | `selectableModels()` *(optional)* | `/model` picker list |
| `deepantigravity.sh` | `canonicalize_backend()` | aliases |
| `deepantigravity.sh` | `resolve_backend()` | key validation |
| `deepantigravity.sh` | `backend_ip()` | **unique** loopback IP (Linux parallel) |
| `deepantigravity.ps1` | `Convert-Backend` | aliases |
| `deepantigravity.ps1` | `Resolve-Backend` | key validation |

That's the whole surface. Anthropic-native providers are the smallest
change (one set entry + the declarations); OpenAI-compatible providers
reuse the existing translator with the same effort.
