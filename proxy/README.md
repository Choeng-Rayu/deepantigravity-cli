# proxy — technical notes

This directory contains the HTTPS-MITM proxy that intercepts `agy`'s
calls to `cloudcode-pa.googleapis.com` and rewrites them to other LLM
backends.

```
proxy/
├── start-proxy.js         entry point — picks backend from CLI/env, boots model-proxy
├── model-proxy.js         HTTPS server: CONNECT handler, leaf-cert minting, request router
├── gemini-translator.js   Gemini API ↔ Anthropic Messages translator (this is the brains)
├── openai-translator.js   Anthropic ↔ OpenAI translator (for Nvidia/Doubleword backends)
├── cert.js                node-forge based CA + leaf cert generator
├── package.json           dependency manifest (node-forge)
├── .env.example           template for proxy/.env
└── .cache/                generated CA + leaf certs (gitignored)
    ├── ca.pem             root CA cert (passed to agy via SSL_CERT_FILE)
    ├── ca-key.pem         root CA private key (mode 0600, never sent anywhere)
    └── requests/          (only when DEEPANTIGRAVITY_DEBUG=1) raw request bodies
```

---

## How a single `agy` request flows through the proxy

```
agy (Go HTTP/2)
  │
  ├──── CONNECT cloudcode-pa.googleapis.com:443 ─────────────┐
  │                                                          │
  │                                                          ▼
  │                                              model-proxy.js
  │                                              .on('connect', ...)
  │                                                          │
  │                                                          │ if hostname is in TARGET_HOSTS:
  │                                                          │   write 200 Connection Established
  │                                                          │   mint leaf cert via cert.js
  │                                                          │   handshake TLS on the same socket
  │                                                          │
  ├──── (TLS handshake completes) ──────────────────────────┤
  │                                                          │
  ├──── POST /v1internal:streamGenerateContent ─────────────►│
  │     {"model": "models/gemini-2.5-pro",                   │
  │      "request": { "contents": [...], ... }}              │
  │                                                          │
  │                                                          │ handleGenerate(req, res, body)
  │                                                          │   geminiToAnthropic(...)
  │                                                          │   ───────────────────►
  │                                                          │   POST /v1/messages on chosen backend
  │                                                          │   ◄───────────────────
  │                                                          │   AnthropicToGeminiStream pipe
  │                                                          │
  ◄──── data: {"candidates":[{"content":{"role":"model","parts":[{"text":"..."}]}}]}
  ◄──── data: {"candidates":[..., "finishReason": "STOP"], "usageMetadata":{...}}
        \n\n
```

---

## What `agy` actually sends (from the binary)

Symbol-table archaeology on the `agy` binary (1.0.1) reveals these
endpoints under `cloudcode-pa.googleapis.com`:

| Path | What it does | Our handler |
|---|---|---|
| `POST /v1internal:streamGenerateContent` | Main agentic chat (streaming Gemini API) | **translate** |
| `POST /v1internal:internalAtomicAgenticChat` | Planner / inner loop chat | **translate** |
| `POST /v1internal:fetchAvailableModels` | Bootstrap: which models are available | **synthesize** |
| `POST /v1internal:loadCodeAssist` | Bootstrap: load user tier + project | **stub** |
| `POST /v1internal:onboardUser` | Bootstrap: create CAIC project | **stub** |
| `POST /v1internal:fetchCodeCustomizationState` | Read team customization settings | **stub** |
| `POST /v1internal:setCodeAssistGlobalUserSetting` | Save global setting | **stub** |
| Anything else | Various telemetry/eval endpoints | **passthrough-200** |

For non-`cloudcode-pa.googleapis.com` traffic (OAuth on
`accounts.google.com`, telemetry on `play.googleapis.com`, browser
launchers, etc.), the proxy acts as a transparent CONNECT tunnel — it
just pipes bytes between the client and the real upstream without
touching TLS.

---

## Translation reference: Gemini → Anthropic

| Gemini concept | Anthropic equivalent | Notes |
|---|---|---|
| `request.contents[].role: "user"` | `messages[].role: "user"` | direct |
| `request.contents[].role: "model"` | `messages[].role: "assistant"` | direct |
| `parts[].text` | `content[]: {type:"text", text}` | direct |
| `parts[].text` + `thought:true` | `content[]: {type:"thinking", thinking}` | extended thinking block |
| `parts[].inlineData` (mimeType + base64 data) | `content[]: {type:"image", source:{type:"base64", media_type, data}}` | image input |
| `parts[].functionCall: {name, args, id}` | `content[]: {type:"tool_use", id, name, input}` | tool call |
| `parts[].functionResponse: {name, response, id}` | `content[]: {type:"tool_result", tool_use_id, content}` | tool result. Falls back to name-matching if `id` is missing. |
| `request.systemInstruction.parts[].text` | top-level `system: "..."` | system prompt |
| `request.tools[].functionDeclarations[]` | top-level `tools[]` | each declaration → one Anthropic tool |
| `request.generationConfig.temperature` | `temperature` | passthrough |
| `request.generationConfig.topP` | `top_p` | passthrough |
| `request.generationConfig.maxOutputTokens` | `max_tokens` | passthrough; defaults to 8192 if missing |
| `request.generationConfig.stopSequences` | `stop_sequences` | passthrough |
| `request.generationConfig.thinkingConfig.includeThoughts` | (no direct flag) | thinking blocks always emitted; up to backend whether to populate |

## Translation reference: Anthropic SSE → Gemini SSE

| Anthropic event | Action on Gemini stream |
|---|---|
| `message_start` | Capture `usage.input_tokens`. No output emitted. |
| `content_block_start` (text) | Track current block index. |
| `content_block_start` (tool_use) | Track + start accumulating `partial_json`. |
| `content_block_delta` (`text_delta`) | Emit `data: {candidates:[{content:{parts:[{text}]}}]}` |
| `content_block_delta` (`thinking_delta`) | Same, but with `thought: true` on the part. |
| `content_block_delta` (`input_json_delta`) | Append to current tool_use's `partial`. |
| `content_block_stop` (after tool_use) | Parse accumulated JSON, emit `data: {candidates:[{content:{parts:[{functionCall:{name,id,args}}]}}]}` |
| `message_delta` | Capture `stop_reason` (mapped: `end_turn|tool_use → STOP`, `max_tokens → MAX_TOKENS`) and `usage.output_tokens`. |
| `message_stop` | Emit final chunk with `finishReason` and `usageMetadata`. |

Both directions are implemented as `Transform` streams so streaming
latency stays low and we don't buffer entire responses.

---

## Why HTTPS_PROXY + SSL_CERT_FILE works

`agy` is a stripped Go binary. Go's standard library `net/http`:

- Honors `HTTPS_PROXY` (and `HTTP_PROXY`, `NO_PROXY`) via
  `http.ProxyFromEnvironment`. Setting `HTTPS_PROXY=http://127.0.0.1:8443`
  causes Go's transport to route TLS-over-CONNECT through us.
- Honors `SSL_CERT_FILE` via `crypto/x509.systemRootsPool` when loading
  the system root CAs. If the env var is set, that file is used as the
  trust store INSTEAD of the system one.

Both behaviors are documented in the Go standard library and have been
stable since at least Go 1.14. `agy` does not appear to override either
behavior (no calls to `http.Transport{Proxy: nil}` or custom
`tls.Config.RootCAs` based on the disassembly).

This means MITM works without modifying `agy` and without root/admin.
The only persistent state we leave on disk is `proxy/.cache/`. You can
delete it any time and the next launch regenerates a fresh CA.

---

## Adding a new backend

The pattern is:

1. Add an entry to `BACKEND_DEFS` in `start-proxy.js` (env var names + defaults).
2. Add the canonical name to `ANTHROPIC_NATIVE` or `OPENAI_COMPAT` in
   `model-proxy.js`. If the backend speaks a third protocol (Bedrock-style
   binary streams, gRPC, etc.) you'll also need a new translator module
   in the spirit of `gemini-translator.js` and `openai-translator.js`.
3. Add the env vars and a section in `proxy/.env.example`.
4. Add the backend to `canonicalize_backend()` in `deepantigravity.sh`
   and `Convert-Backend` in `deepantigravity.ps1`.
5. Add the row to the table in the root `README.md`.

If the backend speaks the **Anthropic Messages API directly**, that's
all you need — `forwardAnthropic` in `model-proxy.js` handles it.

If the backend speaks the **OpenAI Chat Completions API**, add it to
`OPENAI_COMPAT` and `forwardOpenAI` will route through
`openai-translator.js` (Anthropic → OpenAI on outbound, OpenAI SSE →
Anthropic SSE → Gemini SSE on inbound).

If the backend speaks something else (gRPC, AWS Event Stream, etc.),
write a new translator module + a `forwardXyz` function.

---

## Debugging

```bash
# Capture every request body for inspection
DEEPANTIGRAVITY_DEBUG=1 deepantigravity -b ds

# Each request lands in proxy/.cache/requests/<timestamp>__<METHOD>__<path>.json
ls proxy/.cache/requests/

# Test the proxy alone (no agy) — useful for unit-style debugging:
node proxy/start-proxy.js deepseek 8443 &
curl -k --proxy http://127.0.0.1:8443 \
  https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels \
  -H 'content-type: application/json' \
  -d '{}'
# (the fakeAvailableModels response should come back)
```

---

## Limitations of this proxy specifically

- **HTTP/1.1 only inside the MITM tunnel.** We force `ALPNProtocols: ['http/1.1']` on the leaf TLS server. Go retries on h2 negotiation failure, so this is fine, but if a future `agy` rev requires HTTP/2 framing (rare for JSON APIs), we'd need to wire `http2.createSecureServer` into the MITM path.
- **Bedrock event-stream is not yet decoded.** The hooks are in place but the binary AWS Event Stream parser hasn't been ported from `deepclaude-cli/proxy/model-proxy.js`. AWS users today should keep using `deepclaude-cli`.
- **Tool-call IDs are best-effort.** Gemini's `functionResponse` parts often lack `id`, so we match by tool name against the most recent assistant `tool_use`. Two parallel calls of the same tool can collide. (Real fix: maintain an explicit ID map per request.)
- **Heuristic synthetic models.** `fetchAvailableModels` returns a hardcoded list of three Gemini IDs. `agy` may also call experiment-flag endpoints (`/v1internal:fetchFromTrawlerCache`, `/v1internal:recordCodeAssistMetrics`, etc.) which we currently stub with `{}`. So far `agy` has tolerated empty responses; if not, the symbol table will tell you what shape they expect.
