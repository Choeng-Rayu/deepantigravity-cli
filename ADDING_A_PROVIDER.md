# Adding a New Provider to deepantigravity

This guide shows how to add a new LLM backend (provider) to
`deepantigravity`, using the **existing two backends as the template**:

- **`kimi`** — Anthropic-native upstream (no format translation needed)
- **`nvidia`** — OpenAI-compatible upstream (translated Gemini → Anthropic → OpenAI)

> Scope note: prefer providers you can reach through a **sanctioned,
> programmatic credential** — an API key, or an official CLI's OAuth flow.
> Both example backends in sections 1–5 use real API keys. Replaying a
> website's browser **session token** is possible but a heavier, fragile
> special case (it breaks the provider's ToS, trips anti-abuse systems,
> is unstable, and usually loses tool-calling) — see **section 6** for
> the shipped `deepseekOauthWeb` example.

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

---

## 6. Advanced: a custom-protocol / web-session backend

Sections 1–5 cover providers reachable through a sanctioned API key. Some
providers have **no usable API for your account** but do expose a browser
chat backend. Driving that is a different, heavier task: it is **not** an
Anthropic/OpenAI API, so it can't reuse `forwardAnthropic`/`forwardOpenAI`
— it needs its own forwarder, its own SSE translation, and often a
proof-of-work step.

> ⚠️ **Caveats — read before doing this.** Replaying a website session
> token breaks most providers' ToS, trips anti-abuse systems, and is
> unstable (tokens/cookies expire, often every few minutes). It also
> usually **loses tool-calling**, which reduces `agy` from an agent to a
> plain Q&A chatbot (no file edits, terminal, or browser agent). Only do
> this for personal experimentation, and expect to refresh credentials
> often.

The shipped **`deepseekOauthWeb`** backend is the worked example
(`chat.deepseek.com`). Here is everything it adds on top of the section-3
edits.

> 📘 For a **standalone, copy-pasteable** version of this — full source for
> every file, the captured wire protocol, and a troubleshooting table — see
> [`DEEPSEEK_OAUTH_WEB_GUIDE.md`](DEEPSEEK_OAUTH_WEB_GUIDE.md).

### 6.1 What's different from an API backend

| Concern | API backend | Web-session backend (deepseek) |
|---|---|---|
| Credential | API key (`x-api-key`/Bearer) | browser `userToken` **+ cookies** |
| Anti-abuse | none | per-turn sha3 **proof-of-work** (WASM) |
| Wire format | Anthropic/OpenAI | bespoke JSON-patch delta SSE |
| Forwarder | reused | **new** `forwardDeepSeekWeb()` |
| Tool calling | yes | **no** (prompt is flattened to text) |

### 6.2 Credentials: token **and** cookie

A web session needs two secrets, both grabbed from the browser at
`chat.deepseek.com` (F12 dev tools):

- **Token** — Application → Local Storage → key `userToken` → its `value`.
- **Cookie** — Network → any `api/v0` request → Request Headers → the full
  `cookie:` value (must include `ds_session_id` **and** `aws-waf-token`,
  which is what gets you past the WAF).

So this backend declares a **second** env var beyond the usual key:

```ini
# proxy/.env(.example)
DEEPSEEK_OAUTH_WEB_TOKEN=your-userToken-from-localStorage
DEEPSEEK_OAUTH_WEB_MODEL=deepseek-v4-flash
DEEPSEEK_OAUTH_WEB_COOKIE=aws-waf-token=...; ds_session_id=...
```

The cookie is plumbed through `start-proxy.js` into the proxy `opts`:

```js
// proxy/start-proxy.js → startProxy({...})
cookie: process.env.DEEPSEEK_OAUTH_WEB_COOKIE || '',
```

`BACKEND_DEFS` points the URL at the **web host**, not an API endpoint:

```js
deepseekOauthWeb: {
    urlDefault:   'https://chat.deepseek.com',
    keyEnv:       'DEEPSEEK_OAUTH_WEB_TOKEN',
    modelEnv:     'DEEPSEEK_OAUTH_WEB_MODEL',
    modelDefault: 'deepseek-v4-flash',
},
```

### 6.3 A third protocol set + dispatch

Instead of `ANTHROPIC_NATIVE`/`OPENAI_COMPAT`, give it its own set and
dispatch branch in `model-proxy.js`:

```js
const ANTHROPIC_NATIVE = new Set(['kimi']);
const OPENAI_COMPAT    = new Set(['nvidia']);
const DEEPSEEK_WEB     = new Set(['deepseekOauthWeb']);   // NEW
```

```js
// in handleGenerate(), after the existing branches:
} else if (DEEPSEEK_WEB.has(effectiveOpts.backend)) {
    await forwardDeepSeekWeb(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
}
```

### 6.4 The proof-of-work solver (`proxy/deepseek-pow.js`)

Every `/chat/completion` call must be preceded by
`POST /api/v0/chat/create_pow_challenge`, whose answer is computed by the
site's **own WASM module**. We ship that module at
`proxy/wasm/sha3_wasm_bg.7b9ca65ddd.wasm` and call it with Node's built-in
`WebAssembly` (no extra deps):

```js
// solvePowChallenge(challenge) → base64 string for the x-ds-pow-response header
const ex = (await WebAssembly.instantiate(await WebAssembly.compile(wasmBytes), {})).exports;
const ptr = ex.__wbindgen_export_0(len, 1);        // malloc + copy challenge/prefix
const ret = ex.__wbindgen_add_to_stack_pointer(-16);
ex.wasm_solve(ret, cPtr, cLen, pPtr, pLen, Number(difficulty));
// status = int32 @ret; answer = float64 @ret+8 ; prefix = `${salt}_${expire_at}_`
```

Re-acquire the memory view **after** the malloc call — the WASM heap can
grow and invalidate the old `ArrayBuffer`.

### 6.5 The forwarder (`forwardDeepSeekWeb` in `model-proxy.js`)

The flow per request:

1. **Flatten** the Anthropic body (system + messages, including any tool
   blocks) into a single `prompt` string — the web endpoint takes only a
   prompt, no tools.
2. `POST /api/v0/chat_session/create {character_id:null}` → session id.
3. `POST /api/v0/chat/create_pow_challenge` → solve it → `x-ds-pow-response`.
4. `POST /api/v0/chat/completion {chat_session_id, prompt, thinking_enabled,…}`
   with the browser headers + cookie, streaming.
5. **Translate the SSE.** The web stream is a JSON-patch delta protocol
   with a sticky "current path" cursor:

   ```
   data: {"p":"response/content","o":"APPEND","v":"42"}   # set path + append
   data: {"v":" more"}                                     # append to current path
   data: {"p":"response/thinking_content","v":"…"}         # reasoning
   data: {"p":"response/status","v":"FINISHED"}            # end
   ```

   We **don't** write a Gemini emitter from scratch — we synthesize
   minimal **Anthropic** SSE events (`message_start`, `content_block_delta`
   with `text_delta`/`thinking_delta`, `message_stop`) and pipe them
   through the existing `AnthropicToGeminiStream`, so the required Gemini
   `{response,traceId,metadata}` wrapper is produced identically to every
   other backend.

### 6.6 Extra files this backend adds

| File | Purpose |
|---|---|
| `proxy/deepseek-pow.js` | Node port of the sha3 PoW solver |
| `proxy/wasm/sha3_wasm_bg.7b9ca65ddd.wasm` | the site's PoW WASM module |
| `proxy/model-proxy.js` → `forwardDeepSeekWeb()` | session + PoW + SSE translation |
| `proxy/start-proxy.js` → `cookie:` opt | passes `DEEPSEEK_OAUTH_WEB_COOKIE` |

The launcher edits (`canonicalize_backend`, `backend_ip` → `127.0.30.1`,
status display) are the same kind as section 4 — nothing web-specific
there.

### 6.7 Test it

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b deepseek -- --print "what is 6*7?"
#   → 6 × 7 = 42
```

Because there's no API key to authenticate the *answer's* origin, the
proof here is the log line showing the live session + PoW + 200 from
`chat.deepseek.com`:

```bash
grep -E "deepseek web replied|POST https://chat.deepseek.com" \
    proxy/.cache/last-proxy-deepseekOauthWeb.log
```

When answers start returning 401 / WAF errors, the token or cookie has
expired — refresh both from the browser.
