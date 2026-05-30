#!/usr/bin/env node
/**
 * Standalone terminal chat for chat.deepseek.com (web/OAuth backend).
 * Replicates the proxy flow: session create → PoW challenge → SSE stream.
 *
 * Usage:
 *   DEEPSEEK_OAUTH_WEB_TOKEN=... DEEPSEEK_OAUTH_WEB_COOKIE=... node proxy/test-deepseek-chat.mjs ["one-shot prompt"]
 */
import { request as httpsRequest } from 'https';
import { createInterface } from 'readline';
import { solvePowChallenge } from './deepseek-pow.js';

const TOKEN = process.env.DEEPSEEK_OAUTH_WEB_TOKEN;
const COOKIE = process.env.DEEPSEEK_OAUTH_WEB_COOKIE || '';
const MODEL = process.env.DEEPSEEK_OAUTH_WEB_MODEL || 'deepseek-v4-pro';
const THINKING = /reason|think/i.test(MODEL);
const HOST = 'chat.deepseek.com', BASE = '/api/v0';

if (!TOKEN) { console.error('Set DEEPSEEK_OAUTH_WEB_TOKEN'); process.exit(1); }

const headers = (extra = {}) => ({
    accept: '*/*',
    authorization: `Bearer ${TOKEN}`,
    'content-type': 'application/json',
    origin: 'https://chat.deepseek.com',
    referer: 'https://chat.deepseek.com/',
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
    'x-app-version': '20241129.1', 'x-client-locale': 'en_US',
    'x-client-platform': 'web', 'x-client-version': '1.0.0-always',
    ...(COOKIE ? { cookie: COOKIE } : {}), ...extra,
});

function postJson(path, payload) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(payload);
        const req = httpsRequest({ host: HOST, port: 443, method: 'POST', path: BASE + path,
            headers: headers({ 'content-length': Buffer.byteLength(body) }), family: 4 }, (r) => {
            let buf = ''; r.on('data', c => buf += c);
            r.on('end', () => r.statusCode !== 200
                ? reject(new Error(`${path} → HTTP ${r.statusCode}: ${buf.slice(0, 300)}`))
                : (() => { try { resolve(JSON.parse(buf)); } catch { reject(new Error(`${path} bad JSON`)); } })());
        });
        req.on('error', reject); req.write(body); req.end();
    });
}

async function ask(sid, prompt) {
    const chResp = await postJson('/chat/create_pow_challenge', { target_path: '/api/v0/chat/completion' });
    const challenge = chResp?.data?.biz_data?.challenge;
    if (!challenge) throw new Error('no PoW challenge');
    const pow = await solvePowChallenge(challenge);

    const body = JSON.stringify({ chat_session_id: sid, parent_message_id: null, prompt,
        ref_file_ids: [], thinking_enabled: THINKING, search_enabled: false });

    return new Promise((resolve, reject) => {
        const up = httpsRequest({ host: HOST, port: 443, method: 'POST', path: BASE + '/chat/completion',
            headers: headers({ accept: 'text/event-stream', 'x-ds-pow-response': pow, 'content-length': Buffer.byteLength(body) }),
            family: 4 }, (r) => {
            if (r.statusCode !== 200) { let e = ''; r.on('data', c => e += c); r.on('end', () => reject(new Error(`HTTP ${r.statusCode}: ${e.slice(0, 300)}`))); return; }
            let buf = '', curPath = null, full = '', done = false;
            process.stdout.write('AI: ');
            r.on('data', (c) => {
                buf += c.toString(); let idx;
                while ((idx = buf.indexOf('\n\n')) !== -1) {
                    const block = buf.slice(0, idx); buf = buf.slice(idx + 2);
                    for (const line of block.split('\n')) {
                        if (!line.startsWith('data:')) continue;
                        let d; try { d = JSON.parse(line.slice(5).replace(/^ /, '')); } catch { continue; }
                        if (typeof d.p === 'string') curPath = d.p;
                        if (curPath === 'response/content' && typeof d.v === 'string') { full += d.v; process.stdout.write(d.v); }
                        else if (curPath === 'response/status' && d.v === 'FINISHED' && !done) { done = true; }
                    }
                }
            });
            r.on('end', () => { process.stdout.write('\n'); resolve(full); });
            r.on('error', reject);
        });
        up.on('error', reject); up.write(body); up.end();
    });
}

(async () => {
    const sess = await postJson('/chat_session/create', { character_id: null });
    const sid = sess?.data?.biz_data?.id;
    if (!sid) throw new Error('no session id');
    console.error(`[session ${sid}, model ${MODEL}]`);

    const oneShot = process.argv[2];
    if (oneShot) { await ask(sid, oneShot); process.exit(0); }

    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const loop = () => rl.question('You: ', async (input) => {
        if (!input || input === 'quit') return rl.close();
        try { await ask(sid, input); } catch (e) { console.error('Error:', e.message); }
        loop();
    });
    console.log("Type 'quit' to exit\n---");
    loop();
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
