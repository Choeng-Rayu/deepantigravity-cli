# Proxy Architecture

## Request flow

```
agy (Go binary)
  │
  │  DNS: cloudcode-pa.googleapis.com → 127.0.0.1 (via /etc/hosts)
  │  TLS: connects to 127.0.0.1:443
  ▼
model-proxy.js (HTTPS server)
  │
  │  Presents leaf cert signed by local CA
  │  agy trusts it via SSL_CERT_FILE=ca-bundle.pem
  │
  ├─► Bootstrap calls (loadCodeAssist, fetchAvailableModels)
  │     → Forwarded to real Google IP (captured at launch)
  │
  └─► Model calls (/v1internal:streamGenerateContent)
        │
        ▼
      gemini-translator.js
        │  Gemini request → Anthropic messages format
        │
        ├─► Kimi Code (api.kimi.com/coding/v1/messages)
        │     Direct Anthropic-native call
        │
        └─► openai-translator.js
              │  Anthropic → OpenAI chat/completions format
              ▼
            Nvidia NIM (integrate.api.nvidia.com/v1/chat/completions)
```

## Key files

| File | Role |
|---|---|
| `start-proxy.js` | Entry point. Loads env, starts server. |
| `model-proxy.js` | HTTPS server. Routes bootstrap vs model calls. |
| `gemini-translator.js` | Converts Gemini ↔ Anthropic streaming format. |
| `openai-translator.js` | Converts Anthropic ↔ OpenAI for Nvidia. |
| `cert.js` | Generates CA + leaf cert on first run. |

## Translation layers

- **Gemini → Anthropic**: Maps `contents[]` to `messages[]`, `tools[]` to Anthropic tool format, streaming SSE chunks back to Gemini format.
- **Anthropic → OpenAI**: Maps `messages[]` with content blocks to OpenAI `messages[]`, tool calls to function calls.

## TLS setup

1. `cert.js` generates a self-signed CA (stored in `.cache/ca.pem` + `ca-key.pem`)
2. On each launch, a leaf cert for `cloudcode-pa.googleapis.com` is minted
3. A combined bundle (`ca-bundle.pem`) = our CA + system CAs
4. `SSL_CERT_FILE` points to this bundle so agy trusts both
