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
import { createRequire } from 'module';

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
            totalForwarded++;
            await forwardToRealGoogle(req, res, body, upstreamHost);
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
    const realIp = await getRealIp(upstreamHost);

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

    const upstream = httpsRequest({
        host: realIp,
        port: 443,
        method: req.method,
        path: req.url,
        headers: fwdHeaders,
        servername: upstreamHost,    // SNI must be the real hostname
        timeout: REQUEST_TIMEOUT_MS,
        // Use the OS's default trust store (Google's real CA chain)
    }, (upRes) => {
        const respHeaders = { ...upRes.headers };
        delete respHeaders['transfer-encoding']; // node re-chunks
        res.writeHead(upRes.statusCode, upRes.statusMessage, respHeaders);
        upRes.pipe(res);
    });

    upstream.on('error', (e) => {
        console.error(`[deepantigravity] forward error to ${upstreamHost} (${realIp}): ${e.message}`);
        if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'application/json' });
        }
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

    console.error(`[deepantigravity] >>> streamGenerateContent: model=${originalGeminiModel}, ` +
        `contents=${geminiBody.request?.contents?.length || 0}, ` +
        `tools=${geminiBody.request?.tools?.length || 0}`);

    let anthBody;
    try {
        anthBody = geminiToAnthropic(geminiBody, opts.targetModel);
        console.error(`[deepantigravity]     translated → ${opts.backend}: ` +
            `model=${anthBody.model}, messages=${anthBody.messages?.length || 0}, ` +
            `tools=${anthBody.tools?.length || 0}, max_tokens=${anthBody.max_tokens}`);
    } catch (e) {
        console.error(`[deepantigravity]     translation FAILED: ${e.stack || e.message}`);
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 500, message: e.message }}));
        return;
    }

    if (ANTHROPIC_NATIVE.has(opts.backend)) {
        await forwardAnthropic(res, anthBody, opts, originalGeminiModel, onUsage);
    } else if (OPENAI_COMPAT.has(opts.backend)) {
        await forwardOpenAI(res, anthBody, opts, originalGeminiModel, onUsage);
    } else {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { code: 500, message: `unsupported backend: ${opts.backend}` }}));
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
    }, (upRes) => {
        console.error(`[deepantigravity]     upstream replied: ${upRes.statusCode} ${upRes.statusMessage}`);
        if (upRes.statusCode !== 200) {
            res.writeHead(upRes.statusCode, { 'content-type': 'application/json' });
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
