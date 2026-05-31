#!/usr/bin/env node
/**
 * Retry-logic test for forwardOpenAI. Drives the REAL function against a
 * local mock HTTP upstream and a fake res object, asserting:
 *   1. transient 500 → retried → 200 success streamed
 *   2. 400 (non-transient) → NOT retried
 *   3. upstream timeout → NOT retried (M1 fix), returns 502
 *   4. connection drop (ECONNRESET) → retried → success
 *
 * Run: node proxy/test-retry.mjs
 */
import http from 'http';
import { once } from 'events';

// Must be set BEFORE importing model-proxy: REQUEST_TIMEOUT_MS is read at
// module load. Keep it short so the timeout test runs fast.
process.env.DEEPANTIGRAVITY_TIMEOUT_MS = '700';
process.env.DEEPANTIGRAVITY_RETRIES = '2'; // → MAX_ATTEMPTS = 3

const { __test } = await import('./model-proxy.js');
const { forwardOpenAI } = __test;

function fakeRes() {
    return {
        headersSent: false,
        statusCode: null,
        _body: '',
        writeHead(code) { this.headersSent = true; this.statusCode = code; },
        write(c) { this._body += c.toString(); },
        end(c) { if (c) this._body += c.toString(); this.finished = true; this._resolve && this._resolve(); },
        on() {}, once() {}, emit() {},
    };
}

async function withUpstream(handler, fn) {
    let attempt = 0;
    const server = http.createServer((req, res) => { attempt++; handler(attempt, req, res); });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    try { return await fn(port, () => attempt); }
    finally { server.close(); }
}

function run(port, res) {
    const opts = {
        backend: 'nvidia',
        upstreamUrl: `http://127.0.0.1:${port}/v1`,
        upstreamKey: 'test',
        targetModel: 'test-model',
    };
    const anthBody = { model: 'test-model', messages: [{ role: 'user', content: 'hi' }], max_tokens: 16, stream: true };
    res._wait = new Promise(r => { res._resolve = r; });
    forwardOpenAI(res, anthBody, opts, 'gemini-2.5-pro', null);
    return res._wait;
}

const sseOk = 'data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}],"model":"test-model"}\n\ndata: [DONE]\n\n';

let failed = 0;
function check(name, cond, extra = '') {
    console.log(`${cond ? '✓' : '✗ FAIL'}  ${name}${extra ? '  — ' + extra : ''}`);
    if (!cond) failed++;
}

// ── Test 1: transient 500 then 200 ──
await withUpstream((attempt, req, res) => {
    if (attempt === 1) { res.writeHead(500, { 'content-type': 'application/json' }); res.end('{"error":"dynamo instance_id not found"}'); }
    else { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(sseOk); }
}, async (port, getAttempt) => {
    const res = fakeRes();
    await run(port, res);
    check('transient 500 is retried then succeeds', getAttempt() === 2 && res.statusCode === 200, `attempts=${getAttempt()}, status=${res.statusCode}`);
    check('  success body streamed (gemini candidates)', res._body.includes('candidates'), `bodylen=${res._body.length}`);
});

// ── Test 2: 400 not retried ──
await withUpstream((attempt, req, res) => {
    res.writeHead(400, { 'content-type': 'application/json' }); res.end('{"error":"bad request"}');
}, async (port, getAttempt) => {
    const res = fakeRes();
    await run(port, res);
    check('400 is NOT retried', getAttempt() === 1 && res.statusCode === 400, `attempts=${getAttempt()}, status=${res.statusCode}`);
});

// ── Test 3: timeout NOT retried (M1 fix) ──
await withUpstream((attempt, req, res) => {
    /* never respond → triggers REQUEST_TIMEOUT_MS (700ms) */
}, async (port, getAttempt) => {
    const res = fakeRes();
    await run(port, res);
    check('timeout is NOT retried (single attempt)', getAttempt() === 1, `attempts=${getAttempt()}`);
    check('  timeout returns 502 to client', res.statusCode === 502, `status=${res.statusCode}`);
});

// ── Test 4: connection drop (ECONNRESET) retried then success ──
await withUpstream((attempt, req, res) => {
    if (attempt === 1) { req.destroy(); res.destroy(); }
    else { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(sseOk); }
}, async (port, getAttempt) => {
    const res = fakeRes();
    await run(port, res);
    check('connection drop is retried then succeeds', getAttempt() === 2 && res.statusCode === 200, `attempts=${getAttempt()}, status=${res.statusCode}`);
});

console.log(failed === 0 ? '\nALL RETRY TESTS PASSED' : `\n${failed} TEST(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
