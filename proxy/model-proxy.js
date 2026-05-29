/**
 * model-proxy.js
 * ==============
 * HTTPS server that impersonates `cloudcode-pa.googleapis.com` to
 * intercept ONLY the model-generation calls, and transparently
 * forwards every other endpoint to the real Google upstream.
 *
 * WHY THIS DESIGN
 * ---------------
 * `agy` does NOT honor HTTPS_PROXY (verified by strace) and does NOT
 * honor LD_PRELOAD libc hooks (verified — Go uses raw syscalls). The
 * only interception that works is `/etc/hosts` redirection plus
 * `SSL_CERT_FILE` for TLS trust.
 *
 * agy's bootstrap flow makes ~6 different `/v1internal:*` calls
 * (loadCodeAssist, fetchAdminControls, fetchAvailableModels,
 * fetchUserInfo, setUserSettings, listExperiments, etc.) which all
 * carry the user's OAuth bearer token and rely on the user's real
 * Google account state (tier, project, settings, experiments). Rather
 * than reimplementing all that, we forward those calls to real Google
 * and rewrite ONLY the model-generation endpoints:
 *
 *   POST /v1internal:streamGenerateContent      → translate
 *   POST /v1internal:internalAtomicAgenticChat  → translate
 *   *                                           → forward to real Google
 *
 * Real Google's IP is discovered via `dns.resolve4()`, which queries
 * DNS directly and bypasses our `/etc/hosts` hijack. The first call
 * resolves the IP; we cache it for the rest of the session.
 */

import { createServer as createTlsServer } from 'tls';
import { request as httpRequest } from 'http';
import { request as httpsRequest } from 'https';
import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { resolve4 } from 'dns/promises';
import { setDefaultResultOrder } from 'dns';
import { createRequire } from 'module';

// Prefer IPv4 globally. On Windows, Node's getaddrinfo often returns an
// IPv6 (AAAA) address first; when the host's IPv6 routing is incomplete
// this surfaces as ENOTFOUND / EHOSTUNREACH on outbound connections
// (e.g. integrate.api.nvidia.com, googleapis.com). Forcing IPv4-first
// resolution avoids that. Harmless on Linux/macOS.
try { setDefaultResultOrder('ipv4first'); } catch { /* older node */ }

import { ensureCA, makeLeafCertForHost } from './cert.js';
import {
    geminiToAnthropic,
    AnthropicToGeminiStream,
} from './gemini-translator.js';
import {
    anthropicToOpenAI,
    OpenAIToAnthropicStream,
} from './openai-translator.js';

const require = createRequire(import.meta.url);
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REQUEST_TIMEOUT_MS = 5 * 60 * 1000;

const ANTHROPIC_NATIVE = new Set(['kimi']);
const OPENAI_COMPAT = new Set(['nvidia']);

const TARGET_HOSTS = new Set([
    'cloudcode-pa.googleapis.com',
    'daily-cloudcode-pa.googleapis.com',
]);

// Endpoints we INTERCEPT and translate. Everything else is forwarded
// to real Google so the user's tier / project / experiments / etc.
// continue to work with their actual account.
const TRANSLATED_PATHS = [
    '/v1internal:streamGenerateContent',
    '/v1internal:internalAtomicAgenticChat',
];

// ── Phase 2: selectable backend models in agy's /model picker ──
// We inject extra entries into the fetchAvailableModels map, one per
// model in this list. agy sends the map KEY back in streamGenerateContent,
// so we prefix keys with DEEPANTIGRAVITY_KEY_PREFIX to recognise + route
// them to the specific upstream model.
const DEEPANTIGRAVITY_KEY_PREFIX = 'dag-';

// Default curated Nvidia coding models. Override via NVIDIA_MODELS in
// proxy/.env (comma-separated upstream model ids).
// Ordered FAST → SLOW. The first few stream quickly enough for agentic
// tool loops and `--print`; the trailing 250B–675B models are capable
// but slow and may time out on large agentic payloads.
const DEFAULT_NVIDIA_MODELS = [
    // ── fast & reliable for agentic/tool use (recommended) ──
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
    'stepfun-ai/step-3.7-flash',
    'deepseek-ai/deepseek-v4-flash',
    'meta/llama-3.3-70b-instruct',
    // ── strong but slower ──
    'moonshotai/kimi-k2.6',
    'deepseek-ai/deepseek-v4-pro',
    'qwen/qwen3-coder-480b-a35b-instruct',
    // ── very large / slow (may time out on big tool payloads) ──
    'qwen/qwen3.5-397b-a17b',
    'nvidia/nemotron-3-super-120b-a12b',
    'mistralai/mistral-large-3-675b-instruct-2512',
];

// Map an upstream model id to a stable agy map key (alnum + dash only).
function modelToKey(modelId) {
    return DEEPANTIGRAVITY_KEY_PREFIX + modelId.replace(/[^a-zA-Z0-9]+/g, '-');
}

// Strip a leading "models/" prefix agy sometimes prepends to the key.
function stripModelsPrefix(name) {
    return String(name || '').replace(/^models\//, '');
}

// Reverse: given a map key agy sent back, return the upstream model id
// (or null if it isn't one of ours). Built from the configured list.
function keyToModel(key, modelList) {
    for (const m of modelList) {
        if (modelToKey(m) === key) return m;
    }
    return null;
}

// The selectable model list for the active backend (nvidia only for now).
function selectableModels(opts) {
    if (opts.backend !== 'nvidia') return [];
    const fromEnv = (process.env.NVIDIA_MODELS || '').split(',')
        .map(s => s.trim()).filter(Boolean);
    const list = fromEnv.length > 0 ? fromEnv : DEFAULT_NVIDIA_MODELS;
    // Always include the configured default target so it's pickable too.
    if (opts.targetModel && !list.includes(opts.targetModel)) {
        list.unshift(opts.targetModel);
    }
    return list;
}

// Cache real IPs of upstream hosts. Populated from env vars set by the
// launcher (which resolves them BEFORE adding /etc/hosts entries —
// systemd-resolved serves /etc/hosts even for direct DNS queries, so
// the proxy itself can't resolve them once the hijack is active).
const _realIpCache = new Map();
{
    const fromEnv = {
        'cloudcode-pa.googleapis.com':       process.env.DEEPANTIGRAVITY_REAL_IP_CLOUDCODE,
        'daily-cloudcode-pa.googleapis.com': process.env.DEEPANTIGRAVITY_REAL_IP_DAILY,
    };
    for (const [host, ip] of Object.entries(fromEnv)) {
        if (ip && ip !== '127.0.0.1') _realIpCache.set(host, ip);
    }
}

async function getRealIp(host) {
    if (_realIpCache.has(host)) return _realIpCache.get(host);
    // Last-resort fallback: dns.resolve4. This may return 127.0.0.1 if
    // the hijack is active — caller should treat that as a failure.
    const addrs = await resolve4(host);
    if (!addrs || addrs.length === 0) {
        throw new Error(`could not resolve ${host} via direct DNS`);
    }
    const ip = addrs[0];
    if (ip === '127.0.0.1') {
        throw new Error(`DNS for ${host} returned 127.0.0.1 (the launcher should set DEEPANTIGRAVITY_REAL_IP_CLOUDCODE before hijacking /etc/hosts)`);
    }
    _realIpCache.set(host, ip);
    return ip;
}

// Return ALL candidate IPv4 addresses for a host, preferring the cached
// one first. dns.resolve4 queries DNS servers directly (it does NOT read
// the hosts file), so it works even with our cloudcode-pa hijack active.
// Used to retry a different IP when the first is unroutable (Windows
// sometimes gets EHOSTUNREACH on a specific Google front-end IP).
async function getRealIpCandidates(host) {
    const out = [];
    const cached = _realIpCache.get(host);
    if (cached && cached !== '127.0.0.1') out.push(cached);
    try {
        const addrs = await resolve4(host);
        for (const a of (addrs || [])) {
            if (a && a !== '127.0.0.1' && !out.includes(a)) out.push(a);
        }
    } catch { /* DNS may fail; cached entry (if any) still tried */ }
    return out;
}

// ════════════════════════════════════════════════════════════════
// startProxy(opts)
// ════════════════════════════════════════════════════════════════
export async function startProxy(opts) {
    const port     = opts.port || parseInt(process.env.DEEPANTIGRAVITY_PORT || '443', 10);
    const bindAddr = opts.bindAddr || '127.0.0.1';
    const cacheDir = opts.cacheDir || join(__dirname, '.cache');
    const debug    = opts.debug || process.env.DEEPANTIGRAVITY_DEBUG === '1';
    const debugDir = join(cacheDir, 'requests');
    if (debug && !existsSync(debugDir)) mkdirSync(debugDir, { recursive: true });

    const ca = ensureCA(cacheDir);

    // Pre-flight: confirm we have real IPs for the target hosts. The
    // launcher should have populated DEEPANTIGRAVITY_REAL_IP_CLOUDCODE
    // before adding the /etc/hosts hijack.
    for (const host of TARGET_HOSTS) {
        try {
            const ip = await getRealIp(host);
            console.error(`[deepantigravity] upstream ${host} → ${ip} (real Google)`);
        } catch (e) {
            console.error(`[deepantigravity] WARNING: ${e.message}`);
        }
    }

    // Pre-mint leaf certs for the hostnames we expect in SNI.
    const leafByHost = {};
    for (const h of TARGET_HOSTS) {
        leafByHost[h] = makeLeafCertForHost(ca.ca, h);
    }
    const defaultLeaf = leafByHost['cloudcode-pa.googleapis.com'];

    let totalRequests   = 0;
    let totalTranslated = 0;
    let totalForwarded  = 0;
    let totalErrors     = 0;
    let inputTokens     = 0;
    let outputTokens    = 0;
    // PROOF tracker: the last model name the UPSTREAM SERVER reported.
    // Populated by forwardOpenAI/forwardAnthropic via opts._setLastModel.
    let lastUpstreamModel = null;
    opts._setLastModel = (m) => { if (m) lastUpstreamModel = m; };

    const handleRequest = async (req, res, sniHost) => {
        const path = req.url || '';
        const upstreamHost = sniHost || 'cloudcode-pa.googleapis.com';
        totalRequests++;

        if (path === '/_proxy/status' || path === '/_proxy/health') {
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({
                backend: opts.backend,
                upstreamUrl: opts.upstreamUrl,
                targetModel: opts.targetModel,
                lastUpstreamModel,
                totalRequests, totalTranslated, totalForwarded, totalErrors,
                inputTokens, outputTokens,
            }, null, 2));
            return;
        }

        // Loopback-only shutdown. macOS runs the proxy as root (to bind
        // :443), so the non-root launcher can't `kill` it on exit. It
        // instead POSTs here over 127.0.0.1 to ask the proxy to exit.
        if (path === '/_proxy/shutdown') {
            const ra = req.socket && req.socket.remoteAddress || '';
            const isLoopback = ra === '127.0.0.1' || ra === '::1' || ra === '::ffff:127.0.0.1';
            if (!isLoopback) {
                res.writeHead(403, { 'content-type': 'application/json' });
                res.end(JSON.stringify({ error: 'shutdown allowed from loopback only' }));
                return;
            }
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ ok: true }));
            console.error('[deepantigravity] shutdown requested via /_proxy/shutdown — exiting');
            setTimeout(() => process.exit(0), 50);
            return;
        }

        const body = await readBody(req);
        if (debug) saveDebugRequest(debugDir, req.method, path, body);

        try {
            // Translate model-generation calls
            const isTranslated = TRANSLATED_PATHS.some(p => path.startsWith(p));
            if (isTranslated) {
                totalTranslated++;
                await handleGenerate(req, res, body, opts, (i, o) => {
                    inputTokens += i;
                    outputTokens += o;
                });
                return;
            }

            // Everything else: forward transparently to real Google.
            // EXCEPT fetchAvailableModels — we forward it, then rewrite
            // the model display names so agy's `/model` picker shows the
            // ACTUAL backend model the user is routed to.
            totalForwarded++;
            if (path.startsWith('/v1internal:fetchAvailableModels')) {
                await forwardAndRewriteModels(req, res, body, upstreamHost, opts);
            } else {
                await forwardToRealGoogle(req, res, body, upstreamHost);
            }
        } catch (e) {
            totalErrors++;
            console.error(`[deepantigravity] error handling ${path}:`, e.stack || e.message);
            if (!res.headersSent) {
                res.writeHead(502, { 'content-type': 'application/json' });
            }
            res.end(JSON.stringify({ error: { code: 502, message: String(e.message || e) } }));
        }
    };

    const server = createTlsServer({
        key:  defaultLeaf.keyPem,
        cert: defaultLeaf.certPem,
        SNICallback: (servername, callback) => {
            const leaf = leafByHost[servername]
                || makeLeafCertForHost(ca.ca, servername);
            const ctx = require('tls').createSecureContext({
                key:  leaf.keyPem,
                cert: leaf.certPem,
            });
            callback(null, ctx);
        },
        ALPNProtocols: ['http/1.1'],
    });

    // Run a per-connection HTTP/1.1 parser on each TLS socket.
    server.on('secureConnection', (tlsSocket) => {
        const sni = tlsSocket.servername || 'cloudcode-pa.googleapis.com';
        const innerHttp = require('http').createServer((req, res) =>
            handleRequest(req, res, sni));
        innerHttp.emit('connection', tlsSocket);
    });

    server.on('error', (e) => {
        console.error('[deepantigravity] server error:', e.message);
    });

    return new Promise((resolve, reject) => {
        server.listen(port, bindAddr, () => {
            const actualPort = server.address().port;
            resolve({
                port: actualPort,
                caPath: ca.caPemPath,
                stop: () => new Promise(r => server.close(() => r())),
            });
        });
        server.on('error', reject);
    });
}


// ════════════════════════════════════════════════════════════════
// Forward non-translated requests to real Google
// ════════════════════════════════════════════════════════════════
/**
 * Forward an incoming request (already received by us) to real Google
 * by connecting directly to its IP (which we resolved via dns.resolve4
 * to bypass /etc/hosts).
 */
async function forwardToRealGoogle(req, res, body, upstreamHost) {
    // Strip hop-by-hop headers; preserve Authorization (the OAuth Bearer
    // token agy is sending).
    const fwdHeaders = { ...req.headers };
    delete fwdHeaders['host'];
    delete fwdHeaders['connection'];
    delete fwdHeaders['proxy-connection'];
    fwdHeaders.host = upstreamHost;
    if (body && body.length) {
        fwdHeaders['content-length'] = String(body.length);
    }

    // Try each candidate IP in turn. On Windows a specific Google
    // front-end IP can be unroutable (EHOSTUNREACH); the next one
    // usually works. Cache the IP that succeeds for next time.
    let candidates = await getRealIpCandidates(upstreamHost);
    if (candidates.length === 0) {
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 502, message: `could not resolve ${upstreamHost}` } }));
        return;
    }

    const tryIp = (idx) => {
        const realIp = candidates[idx];
        const upstream = httpsRequest({
            host: realIp,
            port: 443,
            method: req.method,
            path: req.url,
            headers: fwdHeaders,
            servername: upstreamHost,    // SNI must be the real hostname
            timeout: REQUEST_TIMEOUT_MS,
            family: 4,
        }, (upRes) => {
            _realIpCache.set(upstreamHost, realIp);   // remember the good IP
            const respHeaders = { ...upRes.headers };
            delete respHeaders['transfer-encoding']; // node re-chunks
            res.writeHead(upRes.statusCode, upRes.statusMessage, respHeaders);
            upRes.pipe(res);
        });

        upstream.on('error', (e) => {
            // Try the next candidate IP on a routing/connection failure.
            if (idx + 1 < candidates.length) {
                if (_realIpCache.get(upstreamHost) === realIp) _realIpCache.delete(upstreamHost);
                console.error(`[deepantigravity] forward ${upstreamHost} via ${realIp} failed (${e.code || e.message}); trying next IP`);
                tryIp(idx + 1);
                return;
            }
            console.error(`[deepantigravity] forward error to ${upstreamHost} (${realIp}): ${e.message}`);
            if (!res.headersSent) {
                res.writeHead(502, { 'content-type': 'application/json' });
                res.end(JSON.stringify({ error: { code: 502, message: e.message } }));
            }
        });

        if (body && body.length) upstream.write(body);
        upstream.end();
    };
    tryIp(0);
}


// ════════════════════════════════════════════════════════════════
// fetchAvailableModels — forward to Google, then rewrite display names
// so agy's `/model` picker shows the REAL backend model.
// ════════════════════════════════════════════════════════════════
async function forwardAndRewriteModels(req, res, body, upstreamHost, opts) {
    const realIp = await getRealIp(upstreamHost);

    const fwdHeaders = { ...req.headers };
    delete fwdHeaders['host'];
    delete fwdHeaders['connection'];
    delete fwdHeaders['proxy-connection'];
    delete fwdHeaders['accept-encoding'];   // ask for identity so we can parse JSON
    fwdHeaders.host = upstreamHost;
    fwdHeaders['accept-encoding'] = 'identity';
    if (body && body.length) fwdHeaders['content-length'] = String(body.length);

    const upstream = httpsRequest({
        host: realIp,
        port: 443,
        method: req.method,
        path: req.url,
        headers: fwdHeaders,
        servername: upstreamHost,
        timeout: REQUEST_TIMEOUT_MS,
        family: 4,
    }, (upRes) => {
        const chunks = [];
        upRes.on('data', (c) => chunks.push(c));
        upRes.on('end', () => {
            let buf = Buffer.concat(chunks);
            const respHeaders = { ...upRes.headers };
            delete respHeaders['transfer-encoding'];
            delete respHeaders['content-encoding'];
            delete respHeaders['content-length'];

            // Only rewrite a 200 JSON body; otherwise pass through.
            if (upRes.statusCode === 200) {
                try {
                    const json = JSON.parse(buf.toString('utf8'));
                    const models = json.models;
                    const list = selectableModels(opts);
                    if (process.env.DEEPANTIGRAVITY_DEBUG === '1') {
                        try {
                            const did = json.defaultAgentModelId;
                            require('fs').writeFileSync(
                                require('path').join(__dirname, '.cache', 'real-agent-entry.json'),
                                JSON.stringify({ defaultAgentModelId: did, entry: models[did] }, null, 2));
                        } catch {}
                    }
                    if (models && typeof models === 'object' && list.length > 0) {
                        // Clone the DEFAULT AGENT model entry as the template.
                        // It carries the modelExperiments (system prompts,
                        // checkpointer config) that agy REQUIRES to run an
                        // agentic turn. Using an arbitrary entry (or stripping
                        // modelExperiments) makes agy abort with "Agent
                        // execution terminated due to error".
                        const did = json.defaultAgentModelId;
                        let template = (did && models[did]) ? models[did] : null;
                        if (!template) {
                            // Fall back to any entry that has modelExperiments.
                            for (const v of Object.values(models)) {
                                if (v && typeof v === 'object' && v.modelExperiments) { template = v; break; }
                            }
                        }
                        // Inject one entry per selectable upstream model.
                        const injectedKeys = [];
                        for (const modelId of list) {
                            const key = modelToKey(modelId);
                            const entry = template ? JSON.parse(JSON.stringify(template)) : {};
                            // Override ONLY the user-facing name. Keep model
                            // proto id, capabilities, and modelExperiments
                            // exactly as the working agent model has them.
                            entry.displayName = `★ ${modelId}  (${opts.backend})`;
                            entry.recommended = false;
                            delete entry.tagTitle;
                            delete entry.tagDescription;
                            models[key] = entry;
                            injectedKeys.push(key);
                        }
                        // The picker reads agentModelSorts[].groups[].modelIds.
                        // Add our keys there as a dedicated group so they show
                        // up in the "Switch Model" list.
                        if (!Array.isArray(json.agentModelSorts)) json.agentModelSorts = [];
                        json.agentModelSorts.unshift({
                            displayName: `${opts.backend} (deepantigravity)`,
                            groups: [{ modelIds: injectedKeys }],
                        });
                        // Also append to every existing group so they appear
                        // regardless of which sort agy renders.
                        for (const sort of json.agentModelSorts) {
                            for (const g of (sort.groups || [])) {
                                if (Array.isArray(g.modelIds)) {
                                    for (const k of injectedKeys) {
                                        if (!g.modelIds.includes(k)) g.modelIds.push(k);
                                    }
                                }
                            }
                        }
                        buf = Buffer.from(JSON.stringify(json), 'utf8');
                        console.error(`[deepantigravity]     fetchAvailableModels: injected ${injectedKeys.length} ${opts.backend} model(s) into /model picker`);
                    }
                } catch (e) {
                    console.error(`[deepantigravity]     fetchAvailableModels rewrite skipped: ${e.message}`);
                }
            }
            respHeaders['content-length'] = String(buf.length);
            res.writeHead(upRes.statusCode, upRes.statusMessage, respHeaders);
            res.end(buf);
        });
    });

    upstream.on('error', (e) => {
        console.error(`[deepantigravity] fetchAvailableModels forward error (${realIp}): ${e.message}`);
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 502, message: e.message } }));
    });

    if (body && body.length) upstream.write(body);
    upstream.end();
}


// ════════════════════════════════════════════════════════════════
// streamGenerateContent — translation pipeline
// ════════════════════════════════════════════════════════════════
async function handleGenerate(req, res, bodyBuf, opts, onUsage) {
    let geminiBody;
    try {
        geminiBody = JSON.parse(bodyBuf.toString('utf8'));
    } catch (e) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 400, message: 'invalid JSON body' }}));
        return;
    }

    const originalGeminiModel = geminiBody.model
        || geminiBody.request?.model
        || 'gemini-2.5-pro';

    // Phase 2: if agy sent one of OUR injected model keys (the user
    // picked a specific backend model via /model), route THIS request
    // to that upstream model instead of the default targetModel.
    const selected = keyToModel(stripModelsPrefix(originalGeminiModel), selectableModels(opts));
    const effectiveOpts = selected
        ? { ...opts, targetModel: selected }
        : opts;
    if (selected) {
        console.error(`[deepantigravity]     /model selection: ${originalGeminiModel} → upstream ${selected}`);
    }

    console.error(`[deepantigravity] >>> streamGenerateContent: model=${originalGeminiModel}, ` +
        `contents=${geminiBody.request?.contents?.length || 0}, ` +
        `tools=${geminiBody.request?.tools?.length || 0}`);

    let anthBody;
    try {
        anthBody = geminiToAnthropic(geminiBody, effectiveOpts.targetModel);
        console.error(`[deepantigravity]     translated → ${effectiveOpts.backend}: ` +
            `model=${anthBody.model}, messages=${anthBody.messages?.length || 0}, ` +
            `tools=${anthBody.tools?.length || 0}, max_tokens=${anthBody.max_tokens}`);
    } catch (e) {
        console.error(`[deepantigravity]     translation FAILED: ${e.stack || e.message}`);
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 500, message: e.message }}));
        return;
    }

    if (ANTHROPIC_NATIVE.has(effectiveOpts.backend)) {
        await forwardAnthropic(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
    } else if (OPENAI_COMPAT.has(effectiveOpts.backend)) {
        await forwardOpenAI(res, anthBody, effectiveOpts, originalGeminiModel, onUsage);
    } else {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 500, message: `unsupported backend: ${effectiveOpts.backend}` }}));
    }
}


async function forwardAnthropic(res, anthBody, opts, geminiModel, onUsage) {
    const upstreamUrl = new URL(opts.upstreamUrl);
    const isHttps = upstreamUrl.protocol === 'https:';
    const reqLib = isHttps ? httpsRequest : httpRequest;

    let messagesPath = '/v1/messages';
    let body = JSON.stringify(anthBody);
    const headers = {
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'anthropic-version': '2023-06-01',
        'content-length': Buffer.byteLength(body),
    };

    // Kimi accepts both `x-api-key` (Anthropic-style) and Bearer; we
    // send both for compatibility.
    headers['x-api-key'] = opts.upstreamKey;
    headers['authorization'] = `Bearer ${opts.upstreamKey}`;

    const upstream = reqLib({
        host: upstreamUrl.hostname,
        port: upstreamUrl.port || (isHttps ? 443 : 80),
        method: 'POST',
        path: rebasePath(upstreamUrl.pathname, messagesPath),
        headers,
        timeout: REQUEST_TIMEOUT_MS,
        family: 4,
    }, (upRes) => {
        console.error(`[deepantigravity]     upstream replied: ${upRes.statusCode} ${upRes.statusMessage}`);
        if (upRes.statusCode !== 200) {
            res.writeHead(upRes.statusCode, { 'content-type': 'application/json' });
            // Capture body for debug
            let errBody = '';
            upRes.on('data', c => { errBody += c.toString(); });
            upRes.on('end', () => {
                console.error(`[deepantigravity]     upstream error body: ${errBody.slice(0, 500)}`);
                res.end(errBody);
            });
            return;
        }
        res.writeHead(200, {
            'content-type': 'text/event-stream',
            'cache-control': 'no-cache',
        });
        const tx = new AnthropicToGeminiStream({ originalGeminiModel: geminiModel });
        let inBytes = 0, outBytes = 0, outChunks = 0;
        // PROOF: sniff the model Kimi reports in its message_start event.
        let sniffed = false, sniffBuf = '';
        upRes.on('data', (c) => {
            inBytes += c.length;
            if (sniffed) return;
            sniffBuf += c.toString();
            const m = sniffBuf.match(/"model"\s*:\s*"([^"]+)"/);
            if (m) {
                sniffed = true;
                console.error(`[deepantigravity]     ✓ UPSTREAM SERVER REPORTS model="${m[1]}"  (host=${upstreamUrl.hostname}, requested=${opts.targetModel})`);
                if (opts._setLastModel) opts._setLastModel(m[1]);
            }
            if (sniffBuf.length > 65536) sniffed = true;
        });
        // Tee outgoing chunks to a debug file for inspection
        let debugFd = null;
        if (process.env.DEEPANTIGRAVITY_DEBUG === '1') {
            const fs = require('fs');
            const debugFile = require('path').join(
                require('path').dirname(require('url').fileURLToPath(import.meta.url)),
                '.cache/responses',
                `${Date.now()}__gemini_response.sse`
            );
            try {
                fs.mkdirSync(require('path').dirname(debugFile), { recursive: true });
                debugFd = fs.openSync(debugFile, 'w');
            } catch {}
        }
        tx.on('data', (c) => {
            outBytes += c.length;
            outChunks++;
            if (debugFd) { try { require('fs').writeSync(debugFd, c); } catch {} }
        });
        upRes.pipe(tx).pipe(res);
        tx.on('end', () => {
            if (debugFd) { try { require('fs').closeSync(debugFd); } catch {} }
            console.error(`[deepantigravity]     stream done: anthropic_in=${inBytes}b, gemini_out=${outBytes}b in ${outChunks} chunks`);
            onUsage(0, 0);
        });
        upRes.on('error', (e) => console.error(`[deepantigravity]     upstream stream error: ${e.message}`));
        tx.on('error', (e) => console.error(`[deepantigravity]     translator error: ${e.message}`));
    });

    upstream.on('error', (e) => {
        console.error(`[deepantigravity]     upstream connection FAILED: ${e.code || ''} ${e.message}`);
        if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'application/json' });
        }
        res.end(JSON.stringify({ error: { code: 502, message: e.message } }));
    });

    console.error(`[deepantigravity]     POST ${upstreamUrl.protocol}//${upstreamUrl.hostname}:${upstreamUrl.port || (isHttps ? 443 : 80)}${rebasePath(upstreamUrl.pathname, messagesPath)} (body=${body.length}b)`);
    upstream.write(body);
    upstream.end();
}


async function forwardOpenAI(res, anthBody, opts, geminiModel, onUsage) {
    const openaiBody = anthropicToOpenAI(anthBody, opts.targetModel);
    const upstreamUrl = new URL(opts.upstreamUrl);
    const isHttps = upstreamUrl.protocol === 'https:';
    const reqLib = isHttps ? httpsRequest : httpRequest;

    const body = JSON.stringify(openaiBody);
    const headers = {
        'content-type': 'application/json',
        'authorization': `Bearer ${opts.upstreamKey}`,
        'accept': 'text/event-stream',
        'content-length': Buffer.byteLength(body),
    };

    const upstream = reqLib({
        host: upstreamUrl.hostname,
        port: upstreamUrl.port || (isHttps ? 443 : 80),
        method: 'POST',
        path: rebasePath(upstreamUrl.pathname, '/chat/completions'),
        headers,
        timeout: REQUEST_TIMEOUT_MS,
        family: 4,
    }, (upRes) => {
        console.error(`[deepantigravity]     upstream replied: ${upRes.statusCode} ${upRes.statusMessage}`);
        if (upRes.statusCode !== 200) {
            res.writeHead(upRes.statusCode, { 'content-type': 'application/json' });
            let errBody = '';
            upRes.on('data', c => { errBody += c.toString(); });
            upRes.on('end', () => {
                console.error(`[deepantigravity]     upstream error body: ${errBody.slice(0, 500)}`);
                // Diagnostic: dump the message-role shape so 400s about
                // tool-call/result pairing or ordering are self-evident.
                try {
                    const seq = (openaiBody.messages || []).map(m =>
                        m.role + (m.tool_calls ? `(calls:${m.tool_calls.length})` : '')
                              + (m.role === 'tool' ? `(id:${String(m.tool_call_id).slice(-6)})` : '')
                    ).join(' → ');
                    console.error(`[deepantigravity]     request msg shape: ${seq}`);
                } catch {}
                res.end(errBody);
            });
            return;
        }
        res.writeHead(200, {
            'content-type': 'text/event-stream',
            'cache-control': 'no-cache',
        });
        const oa2anth = new OpenAIToAnthropicStream(opts.targetModel);
        const anth2gem = new AnthropicToGeminiStream({ originalGeminiModel: geminiModel });
        // PROOF: sniff the model the upstream server reports in its SSE
        // chunks and log it once. This is server-authoritative evidence
        // of which backend actually served the response.
        let sniffed = false;
        let sniffBuf = '';
        upRes.on('data', (c) => {
            if (sniffed) return;
            sniffBuf += c.toString();
            const m = sniffBuf.match(/"model"\s*:\s*"([^"]+)"/);
            if (m) {
                sniffed = true;
                console.error(`[deepantigravity]     ✓ UPSTREAM SERVER REPORTS model="${m[1]}"  (host=${upstreamUrl.hostname}, requested=${opts.targetModel})`);
                if (opts._setLastModel) opts._setLastModel(m[1]);
            }
            if (sniffBuf.length > 65536) sniffed = true; // stop buffering
        });
        upRes.pipe(oa2anth).pipe(anth2gem).pipe(res);
    });

    upstream.on('error', (e) => {
        console.error(`[deepantigravity]     upstream connection FAILED: ${e.code || ''} ${e.message}`);
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 502, message: e.message } }));
    });

    console.error(`[deepantigravity]     POST ${upstreamUrl.protocol}//${upstreamUrl.hostname}:${upstreamUrl.port || (isHttps ? 443 : 80)}${rebasePath(upstreamUrl.pathname, '/chat/completions')} (body=${body.length}b)`);
    upstream.write(body);
    upstream.end();
}


// ════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════
function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end',  () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

function rebasePath(base, suffix) {
    const a = base.replace(/\/+$/, '');
    const b = suffix.startsWith('/') ? suffix : '/' + suffix;
    return (a + b) || '/';
}

function saveDebugRequest(dir, method, path, bodyBuf) {
    try {
        const ts = new Date().toISOString().replace(/[:.]/g, '-');
        const safePath = path.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 60);
        const file = join(dir, `${ts}__${method}__${safePath}.json`);
        writeFileSync(file, bodyBuf);
    } catch { /* best-effort */ }
}
