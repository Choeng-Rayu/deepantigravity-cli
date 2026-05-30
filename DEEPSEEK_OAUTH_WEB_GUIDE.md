# DeepSeek OAuth Web — Implementation Guide

A complete, copy-pasteable guide to the **`deepseekOauthWeb`** backend: how
it works, every file it touches, and the exact code, so you can rebuild it
from scratch or port the same technique to another website chat backend.

> **What this backend is.** It drives the **`chat.deepseek.com` web chat**
> (the same thing you use in a browser) instead of the paid DeepSeek API.
> Auth is your **browser session** (a `userToken` + cookies), not an API
> key.
>
> **Tools are emulated, not native.** The web endpoint has **no native
> tool-calling**. To make `agy`'s agentic features (file edits, terminal,
> etc.) work, the proxy describes the tools in the prompt and asks the
> model to emit `<tool_call>{...}</tool_call>` markers, which it parses
> back into real `functionCall`s. This **works**, but is less reliable
> than a native API backend — a model may occasionally narrate an action
> instead of emitting the marker. For the most robust agentic use, prefer
> an API-key backend (Kimi, Nvidia) or a real DeepSeek `sk-` API key.
>
> **Fragile by nature.** Session tokens and the WAF cookie expire (often
> within minutes to hours) and replaying them may violate DeepSeek's ToS.
> This is for personal experimentation.

---

## 1. Why it can't reuse the existing forwarders

The other backends speak a standard API:

- `kimi` → Anthropic Messages API → `forwardAnthropic()`
- `nvidia` → OpenAI Chat Completions → `forwardOpenAI()`

`chat.deepseek.com` speaks **none** of those. It is a bespoke web backend
with three extra obstacles:

| Obstacle | What it means |
|---|---|
| **Browser auth** | Needs `Authorization: Bearer <userToken>` **plus** the site cookies (`ds_session_id`, `aws-waf-token`) to pass the WAF. |
| **Proof-of-work** | Every `/chat/completion` must first solve a sha3 challenge using the site's **own WASM**, returned in an `x-ds-pow-response` header. |
| **JSON-patch SSE** | The response stream is a delta protocol with a sticky "path" cursor, not Anthropic/OpenAI SSE. |
| **No native tools** | Tool-calling is emulated via prompt markers (`<tool_call>{…}</tool_call>`) parsed back into `functionCall`s. |

So it gets its own forwarder (`forwardDeepSeekWeb`), its own PoW module
(`deepseek-pow.js`), and a shipped WASM file. The one thing it **reuses**
is the final `AnthropicToGeminiStream` — we synthesize Anthropic SSE and
feed it through, so agy receives the exact Gemini wrapper every backend
produces.

### Request flow

```
agy → proxy → forwardDeepSeekWeb():
   1. flatten Gemini→Anthropic body into ONE prompt string
   2. POST /api/v0/chat_session/create            → session id
   3. POST /api/v0/chat/create_pow_challenge       → challenge
        └─ solvePowChallenge(challenge)  (WASM)    → x-ds-pow-response
   4. POST /api/v0/chat/completion  (stream)
        └─ JSON-patch delta SSE
             → synthesize Anthropic SSE
                → AnthropicToGeminiStream
                   → Gemini SSE → agy
```

---

## 2. Get the two secrets from your browser

Open `https://chat.deepseek.com`, log in, press **F12**:

1. **Token** — Application → Local Storage → `https://chat.deepseek.com`
   → key **`userToken`** → copy its `value` (the inner string).
   Console shortcut:
   ```js
   JSON.parse(localStorage.getItem("userToken")).value
   ```
2. **Cookie** — Network tab → click any `api/v0/...` request → Request
   Headers → copy the **entire** `cookie:` value. It must contain
   `ds_session_id` **and** `aws-waf-token`.

---

## 3. The exact edits (5 files + 2 new files)

### File 1 — `proxy/.env` (and `.env.example`)

```ini
# DeepSeek OAuth Web (chat.deepseek.com — TEXT ONLY)
# TOKEN:  chat.deepseek.com → F12 → Application → Local Storage → userToken → "value"
# COOKIE: F12 → Network → any api/v0 request → Request Headers → full "cookie:" value
DEEPSEEK_OAUTH_WEB_TOKEN=<your userToken value>
DEEPSEEK_OAUTH_WEB_MODEL=deepseek-v4-pro
DEEPSEEK_OAUTH_WEB_COOKIE=aws-waf-token=...; ds_session_id=...
```

> The default model is **`deepseek-v4-pro`** (the expert model). Reasoning
> ("thinking") mode is **ON by default**; set `DEEPSEEK_OAUTH_WEB_THINKING=0`
> to turn it off. Injected `/model` entries advertise DeepSeek V4's full
> **1M-token context window** (`maxTokens: 1048576`).

### File 2 — `proxy/start-proxy.js`

**(a)** Point the backend at the **web host** in `BACKEND_DEFS`:

```js
deepseekOauthWeb: {
    urlDefault:   'https://chat.deepseek.com',
    keyEnv:       'DEEPSEEK_OAUTH_WEB_TOKEN',
    modelEnv:     'DEEPSEEK_OAUTH_WEB_MODEL',
    modelDefault: 'deepseek-v4-pro',
},
```

**(b)** Add aliases in `canonicalize()`:

```js
case 'ds': case 'deepseek':   return 'deepseekOauthWeb';
```

**(c)** Plumb the cookie into the proxy `opts` (the extra secret no other
backend needs):

```js
const { port: actualPort, caPath } = await startProxy({
    port, bindAddr, backend, upstreamUrl, upstreamKey, targetModel,
    cookie: process.env.DEEPSEEK_OAUTH_WEB_COOKIE || '',   // ← NEW
});
```

### File 3 — `proxy/deepseek-pow.js` (NEW — the PoW solver)

This is a Node port of the site's WASM-based sha3 solver. **No npm deps** —
it uses Node's built-in `WebAssembly`.

```js
/**
 * deepseek-pow.js — solves the sha3 proof-of-work that chat.deepseek.com
 * requires before every /chat/completion, using the site's own WASM.
 * Returns the base64 string for the `x-ds-pow-response` header.
 */
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = join(__dirname, 'wasm', 'sha3_wasm_bg.7b9ca65ddd.wasm');

let _exports = null;
async function loadWasm() {
    if (_exports) return _exports;
    const mod = await WebAssembly.compile(readFileSync(WASM_PATH));
    const inst = await WebAssembly.instantiate(mod, {});
    _exports = inst.exports;
    return _exports;
}

function writeString(ex, text) {
    const bytes = Buffer.from(text, 'utf8');
    const ptr = ex.__wbindgen_export_0(bytes.length, 1);     // malloc
    new Uint8Array(ex.memory.buffer).set(bytes, ptr);        // re-acquire view (heap may grow)
    return [ptr, bytes.length];
}

function calculateHash(ex, challenge, salt, difficulty, expireAt) {
    const prefix = `${salt}_${expireAt}_`;
    const retptr = ex.__wbindgen_add_to_stack_pointer(-16);
    try {
        const [cPtr, cLen] = writeString(ex, challenge);
        const [pPtr, pLen] = writeString(ex, prefix);
        ex.wasm_solve(retptr, cPtr, cLen, pPtr, pLen, Number(difficulty));
        const view = new DataView(ex.memory.buffer);
        const status = view.getInt32(retptr, true);
        if (status === 0) return null;                       // no solution
        return Math.floor(view.getFloat64(retptr + 8, true));// the answer
    } finally {
        ex.__wbindgen_add_to_stack_pointer(16);
    }
}

export async function solvePowChallenge(c) {
    const ex = await loadWasm();
    const answer = calculateHash(ex, c.challenge, c.salt, c.difficulty, c.expire_at);
    if (answer === null) throw new Error('PoW solve failed (wasm returned null)');
    const result = {
        algorithm: c.algorithm, challenge: c.challenge, salt: c.salt,
        answer, signature: c.signature, target_path: c.target_path,
    };
    return Buffer.from(JSON.stringify(result), 'utf8').toString('base64');
}
```

**Gotchas that will cost you hours:**
- Re-acquire the `Uint8Array`/`DataView` **after** `__wbindgen_export_0`
  (malloc) — the WASM heap can grow and invalidate the old buffer.
- The `prefix` is exactly `` `${salt}_${expire_at}_` `` (underscores).
- `status === 0` means *no solution found* — with a **real** server
  challenge it returns a number; a fabricated test challenge legitimately
  returns null.

### File 4 — `proxy/wasm/sha3_wasm_bg.7b9ca65ddd.wasm` (NEW — vendored)

The site's PoW module (~26 KB). Fetch it once:

```bash
mkdir -p proxy/wasm
curl -fsSL -o proxy/wasm/sha3_wasm_bg.7b9ca65ddd.wasm \
  https://raw.githubusercontent.com/xtekky/deepseek4free/main/dsk/wasm/sha3_wasm_bg.7b9ca65ddd.wasm
```

It has **no imports** and exports `memory`, `wasm_solve`,
`__wbindgen_add_to_stack_pointer`, and `__wbindgen_export_0` — which is why
`WebAssembly.instantiate(mod, {})` (empty imports) just works.

### File 5 — `proxy/model-proxy.js`

**(a)** Import the solver (top of file):

```js
import { solvePowChallenge } from './deepseek-pow.js';
```

**(b)** Give it its own protocol set (next to the other two):

```js
const ANTHROPIC_NATIVE = new Set(['kimi']);
const OPENAI_COMPAT    = new Set(['nvidia']);
const DEEPSEEK_WEB     = new Set(['deepseekOauthWeb']);   // ← NEW
```

**(c)** Dispatch to it in `handleGenerate()`:

```js
if (ANTHROPIC_NATIVE.has(effectiveOpts.backend)) {
    await forwardAnthropic(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
} else if (OPENAI_COMPAT.has(effectiveOpts.backend)) {
    await forwardOpenAI(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
} else if (DEEPSEEK_WEB.has(effectiveOpts.backend)) {              // ← NEW
    await forwardDeepSeekWeb(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
} else {
    /* unsupported */
}
```

**(d)** Advertise the 1M context + thinking in the `/model` picker. Inside
`forwardAndRewriteModels()`, where each injected model entry is built from
the template, set them explicitly for this backend so agy sizes context
correctly regardless of which Google template is cloned:

```js
entry.displayName = `★ ${modelId}  (${opts.backend})`;
entry.recommended = false;
delete entry.tagTitle;
delete entry.tagDescription;
if (opts.backend === 'deepseekOauthWeb') {     // ← NEW
    entry.maxTokens = 1048576;                 // DeepSeek V4 = 1M context
    entry.supportsThinking = true;             // reasoning mode
}
models[key] = entry;
```

Also put `deepseek-v4-pro` first in `selectableModels()`'s default list so
the expert model leads the picker.

**(e)** Add the forwarder and its helpers. This is the complete code:

```js
const DS_WEB_HOST = 'chat.deepseek.com';
const DS_WEB_BASE = '/api/v0';

// Browser headers — DeepSeek's WAF checks these. The cookie carries the
// session + aws-waf token; without it you get blocked / 401.
function dsWebHeaders(opts, extra = {}) {
    return {
        'accept': '*/*',
        'authorization': `Bearer ${opts.upstreamKey}`,
        'content-type': 'application/json',
        'origin': 'https://chat.deepseek.com',
        'referer': 'https://chat.deepseek.com/',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
        'x-app-version': '20241129.1',
        'x-client-locale': 'en_US',
        'x-client-platform': 'web',
        'x-client-version': '1.0.0-always',
        ...(opts.cookie ? { cookie: opts.cookie } : {}),
        ...extra,
    };
}

// Small JSON POST helper for the session + challenge calls.
function dsWebPostJson(opts, path, payload) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(payload);
        const req = httpsRequest({
            host: DS_WEB_HOST, port: 443, method: 'POST', path: DS_WEB_BASE + path,
            headers: dsWebHeaders(opts, { 'content-length': Buffer.byteLength(body) }),
            timeout: REQUEST_TIMEOUT_MS, family: 4,
        }, (r) => {
            let buf = '';
            r.on('data', c => buf += c);
            r.on('end', () => {
                if (r.statusCode !== 200) return reject(new Error(`${path} → HTTP ${r.statusCode}: ${buf.slice(0, 300)}`));
                try { resolve(JSON.parse(buf)); } catch { reject(new Error(`${path} → invalid JSON: ${buf.slice(0, 200)}`)); }
            });
        });
        req.on('error', reject);
        req.on('timeout', () => req.destroy(new Error(`${path} timed out`)));
        req.write(body); req.end();
    });
}

// The web endpoint takes ONE prompt — no roles array, no tools. Collapse
// the whole Anthropic conversation (incl. tool blocks) into plain text.
function flattenAnthToPrompt(anthBody) {
    const lines = [];
    if (anthBody.system) lines.push(anthBody.system);
    for (const m of (anthBody.messages || [])) {
        const role = m.role === 'assistant' ? 'Assistant' : 'User';
        let text;
        if (typeof m.content === 'string') {
            text = m.content;
        } else {
            text = (m.content || []).map(b => {
                if (b.type === 'text') return b.text;
                if (b.type === 'thinking') return b.thinking;
                if (b.type === 'tool_use') return `[tool_call ${b.name}: ${JSON.stringify(b.input)}]`;
                if (b.type === 'tool_result') return `[tool_result: ${typeof b.content === 'string' ? b.content : JSON.stringify(b.content)}]`;
                return '';
            }).filter(Boolean).join('\n');
        }
        if (text) lines.push(`${role}: ${text}`);
    }
    return lines.join('\n\n');
}

async function forwardDeepSeekWeb(res, anthBody, opts, geminiModel, onUsage) {
    const prompt = flattenAnthToPrompt(anthBody);
    // Thinking ON by default; disable with DEEPSEEK_OAUTH_WEB_THINKING=0.
    const thinking = process.env.DEEPSEEK_OAUTH_WEB_THINKING !== '0';
    try {
        // 1. session
        const sess = await dsWebPostJson(opts, '/chat_session/create', { character_id: null });
        const sid = sess?.data?.biz_data?.id;
        if (!sid) throw new Error('no session id in chat_session/create response');

        // 2. challenge → solve
        const chResp = await dsWebPostJson(opts, '/chat/create_pow_challenge', { target_path: '/api/v0/chat/completion' });
        const challenge = chResp?.data?.biz_data?.challenge;
        if (!challenge) throw new Error('no challenge in create_pow_challenge response');
        const pow = await solvePowChallenge(challenge);

        // 3. completion (streaming)
        const body = JSON.stringify({
            chat_session_id: sid, parent_message_id: null, prompt,
            ref_file_ids: [], thinking_enabled: thinking, search_enabled: false,
        });
        const headers = dsWebHeaders(opts, {
            accept: 'text/event-stream', 'x-ds-pow-response': pow,
            'content-length': Buffer.byteLength(body),
        });

        const upstream = httpsRequest({
            host: DS_WEB_HOST, port: 443, method: 'POST', path: DS_WEB_BASE + '/chat/completion',
            headers, timeout: REQUEST_TIMEOUT_MS, family: 4,
        }, (upRes) => {
            if (upRes.statusCode !== 200) {
                res.writeHead(upRes.statusCode, { 'content-type': 'application/json' });
                let errBody = '';
                upRes.on('data', c => errBody += c.toString());
                upRes.on('end', () => res.end(errBody));
                return;
            }
            res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
            if (opts._setLastModel) opts._setLastModel(opts.targetModel);

            // 4. translate web SSE → synthetic Anthropic SSE → Gemini SSE
            const tx = new AnthropicToGeminiStream({ originalGeminiModel: geminiModel });
            tx.pipe(res);
            tx.write(`data: ${JSON.stringify({ type: 'message_start', message: { model: opts.targetModel || 'deepseek-web', usage: { input_tokens: 0, output_tokens: 0 } } })}\n\n`);

            let buf = '', curPath = null, done = false;
            const finish = () => {
                if (done) return;
                done = true;
                tx.write(`data: ${JSON.stringify({ type: 'message_delta', delta: { stop_reason: 'end_turn' } })}\n\n`);
                tx.write(`data: ${JSON.stringify({ type: 'message_stop' })}\n\n`);
                tx.end();
                onUsage(0, 0);
            };
            const onData = (s) => {
                if (done) return;
                let d; try { d = JSON.parse(s); } catch { return; }
                if (typeof d.p === 'string') curPath = d.p;   // sticky path cursor
                const v = d.v;
                if (curPath === 'response/content' && typeof v === 'string') {
                    tx.write(`data: ${JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: v } })}\n\n`);
                } else if (curPath === 'response/thinking_content' && typeof v === 'string') {
                    tx.write(`data: ${JSON.stringify({ type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: v } })}\n\n`);
                } else if (curPath === 'response/status' && v === 'FINISHED') {
                    finish();
                }
            };
            upRes.on('data', (c) => {
                buf += c.toString();
                let idx;
                while ((idx = buf.indexOf('\n\n')) !== -1) {
                    const block = buf.slice(0, idx); buf = buf.slice(idx + 2);
                    for (const line of block.split('\n')) {
                        if (line.startsWith('data:')) onData(line.slice(5).replace(/^ /, ''));
                    }
                }
            });
            upRes.on('end', finish);
            upRes.on('error', (e) => console.error(`[deepantigravity]     deepseek web stream error: ${e.message}`));
        });

        upstream.on('error', (e) => {
            if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ error: { code: 502, message: e.message } }));
        });
        upstream.on('timeout', () => upstream.destroy(new Error(`deepseek web timeout after ${REQUEST_TIMEOUT_MS}ms`)));
        upstream.write(body); upstream.end();
    } catch (e) {
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 502, message: String(e.message || e) } }));
    }
}
```

### File 6 — `deepantigravity.sh` (Linux/macOS launcher)

**(a)** aliases in `canonicalize_backend()`:

```bash
ds|deepseek|deepseekOauthWeb) echo "deepseekOauthWeb" ;;
```

**(b)** a **unique** loopback IP in `backend_ip()` (Linux parallel sessions):

```bash
deepseekOauthWeb) echo "127.0.30.1" ;;   # must differ from kimi/nvidia
```

(The status display already masks `DEEPSEEK_OAUTH_WEB_TOKEN`; no key-format
validation is enforced because a session token has no fixed prefix.)

---

## 4. The wire protocol, by example

These are **real** captured exchanges (values shortened).

### 4.1 Create session

```http
POST /api/v0/chat_session/create
{ "character_id": null }
```
```json
{ "data": { "biz_data": { "id": "144d04d7-3f8f-4008-8dbb-ada64b46ebed" } } }
```

### 4.2 Create + solve PoW

```http
POST /api/v0/chat/create_pow_challenge
{ "target_path": "/api/v0/chat/completion" }
```
```json
{ "data": { "biz_data": { "challenge": {
    "algorithm": "DeepSeekHashV1",
    "challenge": "5cba2ce8…829a",
    "salt": "70769ee1e152378a9705",
    "difficulty": 144000,
    "expire_at": 1780103696156,
    "signature": "d643771a…3bba",
    "target_path": "/api/v0/chat/completion"
} } } }
```

`solvePowChallenge(challenge)` → base64 of
`{algorithm,challenge,salt,answer,signature,target_path}` → goes in the
`x-ds-pow-response` header. (Solves in ~40 ms.)

### 4.3 Completion stream (the JSON-patch delta protocol)

```http
POST /api/v0/chat/completion        (header: x-ds-pow-response: <base64>)
{ "chat_session_id": "144d…", "parent_message_id": null,
  "prompt": "User: what is 6*7? reply with just the number",
  "ref_file_ids": [], "thinking_enabled": false, "search_enabled": false }
```

```
event: ready
data: {"request_message_id":1,"response_message_id":2,...}

data: {"v":{"response":{...,"content":"",...}}}            ← initial object
data: {"p":"response/content","o":"APPEND","v":"42"}        ← set path + append "42"
data: {"p":"response/status","v":"FINISHED"}                ← end

event: finish
data: {}
```

The cursor rules the parser relies on:
- A frame with `"p"` **sets the current path** (and may also carry `"v"`).
- A bare `{"v":"…"}` frame **appends to the current path** (no `p`).
- `response/content` → assistant text; `response/thinking_content` →
  reasoning; `response/status == "FINISHED"` → done.

For a longer answer you see many bare append frames:

```
data: {"p":"response/content","o":"APPEND","v":"1"}
data: {"v":", "}
data: {"v":"2"}
data: {"v":", "}
data: {"v":"3"}
...
```

---

## 5. Test & verify

### 5.1 Solver unit-check (against a live challenge)

```bash
TOKEN=$(grep -E '^DEEPSEEK_OAUTH_WEB_TOKEN=' proxy/.env | cut -d= -f2-)
COOKIE=$(grep -E '^DEEPSEEK_OAUTH_WEB_COOKIE=' proxy/.env | cut -d= -f2-)
curl -sS -X POST 'https://chat.deepseek.com/api/v0/chat/create_pow_challenge' \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -H 'x-app-version: 20241129.1' -H 'x-client-platform: web' \
  -H 'x-client-version: 1.0.0-always' -H 'origin: https://chat.deepseek.com' \
  -H "cookie: $COOKIE" --data '{"target_path":"/api/v0/chat/completion"}' \
| node --input-type=module -e \
  'import{solvePowChallenge}from"./proxy/deepseek-pow.js";let s="";process.stdin.on("data",d=>s+=d).on("end",async()=>{const c=JSON.parse(s).data.biz_data.challenge;console.log("x-ds-pow-response:",await solvePowChallenge(c));})'
```

A non-empty base64 string = solver + auth + cookie all good.

### 5.2 Syntax check

```bash
node --check proxy/deepseek-pow.js
node --check proxy/model-proxy.js
node --check proxy/start-proxy.js
bash -n deepantigravity.sh
```

### 5.3 Full end-to-end

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b deepseek -- --print "what is 6*7?"
#   Starting deepseekOauthWeb proxy on 127.0.30.1:443 ...
#   6 × 7 = 42
```

Proof it really hit the web backend (there's no API key to attribute the
answer, so use the log):

```bash
grep -E "deepseek web replied|POST https://chat.deepseek.com" \
    proxy/.cache/last-proxy-deepseekOauthWeb.log
#   POST https://chat.deepseek.com/api/v0/chat/completion (session=…, prompt=45b, thinking=false)
#   deepseek web replied: 200 OK
```

### 5.4 Tool-emulation diagnostics

With `DEEPANTIGRAVITY_DEBUG=1`, the proxy logs the full tool round-trip to
the **session** log (not `last-proxy-*.log`):

```bash
grep "\[tools\]" proxy/.cache/sessions/deepseekOauthWeb/proxy.log
```

You'll see, per turn:

```
[tools] offered 19: ask_permission, …, write_to_file     ← tools agy sent
[tools] raw model content (158b):                          ← exactly what the model emitted
<tool_call>{"name":"view_file","arguments":{…}}</tool_call>
[tools] parsed call #1: name=view_file args={…}
[tools] valid calls=1
emulated tool_use: view_file                               ← re-emitted as a real functionCall
```

This is the fastest way to diagnose a stalled agentic turn. The key line
is **`valid calls=N`**:

- `valid calls=0` **and** the raw content is plain prose → the model
  *described* the action instead of emitting a marker (emulation miss).
  Re-run; a stronger prompt usually fixes it.
- `valid calls=0` **and** `content looks tool-ish but NO calls extracted`
  → the model used an unhandled format. The extractor already handles the
  marker, fenced-in-marker, bare-fenced, and bare-`{"name":…}` shapes; if
  you hit a new one, extend `extractToolCalls()`.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` / `Authentication Fails` | token expired or wrong value (used API `sk-` key instead of `userToken`) | re-copy `userToken` from Local Storage |
| HTML "Just a moment" / `403` | WAF blocked you — cookie missing/expired | re-copy the full `cookie:` (needs `aws-waf-token` + `ds_session_id`) |
| `create_pow_challenge → HTTP 4xx` | cookie/token mismatch | refresh **both** secrets together from one browser session |
| `PoW solve failed (wasm returned null)` on real challenges | wrong call convention or stale heap view | re-acquire memory view after malloc; check prefix `` `${salt}_${expire_at}_` `` |
| answer streams but agy shows nothing | missing Gemini wrapper | ensure you feed synthetic Anthropic SSE through `AnthropicToGeminiStream`, don't hand-roll Gemini frames |
| agentic tasks fail / agy aborts | web backend has no tool-calling | expected — use an API-key backend for agentic work |

---

## 7. File checklist

| File | Change |
|---|---|
| `proxy/.env` / `.env.example` | `DEEPSEEK_OAUTH_WEB_TOKEN`, `_MODEL`, `_COOKIE` |
| `proxy/start-proxy.js` | `BACKEND_DEFS.deepseekOauthWeb` → web host; `canonicalize()` aliases; pass `cookie:` to `startProxy` |
| `proxy/deepseek-pow.js` | **new** — WASM sha3 PoW solver |
| `proxy/wasm/sha3_wasm_bg.7b9ca65ddd.wasm` | **new** — vendored PoW module |
| `proxy/model-proxy.js` | import solver; `DEEPSEEK_WEB` set; dispatch; `forwardDeepSeekWeb()` + helpers |
| `deepantigravity.sh` | `canonicalize_backend()` aliases; `backend_ip()` → `127.0.30.1` |

That's the entire surface. The reusable lesson: for any non-API web chat
backend, write a thin forwarder that (1) handles the site's auth +
anti-abuse, (2) flattens to a prompt, and (3) re-emits the stream as
synthetic Anthropic SSE so the existing `AnthropicToGeminiStream` does the
final Gemini formatting for free.
