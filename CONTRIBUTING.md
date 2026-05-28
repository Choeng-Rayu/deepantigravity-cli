# Contributing to deepantigravity

## Getting started

1. Fork and clone the repo
2. `cd proxy && npm install && cd ..`
3. Copy `proxy/.env.example` to `proxy/.env` and add your keys
4. Run `./deepantigravity.sh --setup`

## Making changes

- Keep commits small and focused
- Test with both backends (`-b kimi` and `-b nv`) if your change affects translation
- Run with `DEEPANTIGRAVITY_DEBUG=1` to verify request/response flow

## Code structure

| File | Purpose |
|---|---|
| `deepantigravity.sh` | Main launcher — handles setup, teardown, hosts management |
| `proxy/start-proxy.js` | Entry point for the proxy server |
| `proxy/model-proxy.js` | HTTPS server, request routing |
| `proxy/gemini-translator.js` | Gemini ↔ Anthropic format translation |
| `proxy/openai-translator.js` | Anthropic ↔ OpenAI format translation |
| `proxy/cert.js` | CA and leaf certificate generation |

## Adding a new backend

1. Create a new translator in `proxy/` (e.g., `newbackend-translator.js`)
2. Add the provider case in `proxy/model-proxy.js`
3. Add env vars to `proxy/.env.example`
4. Update `deepantigravity.sh` to accept the new `-b` flag
5. Document in README.md

## Reporting issues

Include:
- Output of `./deepantigravity.sh --status`
- Node.js version (`node --version`)
- OS and version
- Debug output (`DEEPANTIGRAVITY_DEBUG=1`)
