#!/usr/bin/env node
/**
 * Translation-pipeline test. Runs every captured real agy request through
 * geminiToAnthropic → anthropicToOpenAI and asserts the invariants that
 * OpenAI-compat backends (qwen, mistral, deepseek, etc.) require:
 *
 *   I1. Every assistant tool_call has a matching following tool result.
 *   I2. Every tool result references an id that was actually called.
 *   I3. No two tool_calls share the same id (parallel/same-name safety).
 *   I4. Tool schemas: types lowercased, required ⊆ properties, type=object.
 *   I5. Message role order is valid (no tool msg without preceding call).
 *   I6. Synthetic crafted shapes: image, thinking, system, parallel calls.
 *
 * Run: node proxy/test-translation.mjs
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { geminiToAnthropic } from './gemini-translator.js';
import { anthropicToOpenAI } from './openai-translator.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REQ_DIR = path.join(__dirname, '.cache', 'requests');
const MODEL = 'qwen/qwen3-coder-480b-a35b-instruct';

let failed = 0;
function check(name, cond, extra = '') {
    if (!cond) { console.log(`✗ FAIL  ${name}${extra ? '  — ' + extra : ''}`); failed++; }
    else console.log(`✓  ${name}${extra ? '  — ' + extra : ''}`);
}

// Validate the OpenAI message array invariants.
function validateOpenAI(oai, label) {
    const msgs = oai.messages || [];
    const calledIds = new Set();
    const seenCallIds = new Set();
    let dupId = null, orphanResult = null;
    for (const m of msgs) {
        if (m.role === 'assistant' && Array.isArray(m.tool_calls)) {
            for (const tc of m.tool_calls) {
                if (seenCallIds.has(tc.id)) dupId = tc.id;   // I3
                seenCallIds.add(tc.id);
                calledIds.add(tc.id);
            }
        }
        if (m.role === 'tool') {
            if (!calledIds.has(m.tool_call_id)) orphanResult = m.tool_call_id; // I2
        }
    }
    // I1: every call id must be answered by some tool msg
    const answered = new Set(msgs.filter(m => m.role === 'tool').map(m => m.tool_call_id));
    const unanswered = [...calledIds].filter(id => !answered.has(id));
    check(`${label}: no duplicate tool_call ids (I3)`, !dupId, dupId ? `dup=${dupId}` : '');
    check(`${label}: no orphan tool result (I2)`, !orphanResult, orphanResult ? `orphan=${orphanResult}` : '');
    check(`${label}: every tool_call answered (I1)`, unanswered.length === 0, unanswered.length ? `unanswered=${unanswered.length}` : '');
    return { calledCount: calledIds.size, answered: answered.size };
}

function validateTools(oai, label) {
    let bad = 0, detail = '';
    for (const t of (oai.tools || [])) {
        const p = t.function?.parameters || {};
        const s = JSON.stringify(p);
        if (/"type":"(OBJECT|STRING|INTEGER|BOOLEAN|ARRAY|NUMBER)"/.test(s)) { bad++; detail = `${t.function.name}:uppercase`; }
        const props = Object.keys(p.properties || {});
        for (const r of (p.required || [])) if (!props.includes(r)) { bad++; detail = `${t.function.name}:req '${r}' not in props`; }
    }
    check(`${label}: tool schemas valid (I4)`, bad === 0, detail);
}

// ── Real captured requests ──
const files = fs.existsSync(REQ_DIR)
    ? fs.readdirSync(REQ_DIR).filter(f => f.includes('streamGenerateContent')).map(f => path.join(REQ_DIR, f))
    : [];

console.log(`\n=== REAL CAPTURED REQUESTS (${files.length}) ===`);
let withTools = 0;
for (const f of files) {
    let raw = fs.readFileSync(f, 'utf8'), j;
    try { j = JSON.parse(raw); } catch { const s = raw.indexOf('{'); if (s < 0) continue; try { j = JSON.parse(raw.slice(s)); } catch { continue; } }
    const label = path.basename(f).slice(0, 24);
    let anth, oai;
    try {
        anth = geminiToAnthropic(j, MODEL);
        oai = anthropicToOpenAI(anth, MODEL);
    } catch (e) {
        check(`${label}: translates without throwing`, false, e.message);
        continue;
    }
    const r = validateOpenAI(oai, label);
    if ((oai.tools || []).length) { validateTools(oai, label); withTools++; }
}
console.log(`(captures with tools: ${withTools})`);

// ── Synthetic shapes not present in captures: image, thinking, parallel same-name, system ──
console.log('\n=== SYNTHETIC MESSAGE SHAPES ===');
function gem(contents, opts = {}) {
    return { request: { contents, systemInstruction: opts.sys ? { parts: [{ text: opts.sys }] } : undefined,
        tools: opts.tools, generationConfig: { temperature: 0.6 } } };
}
const declTools = [{ functionDeclarations: [
    { name: 'read_file', description: 'read', parameters: { type: 'OBJECT', properties: { path: { type: 'STRING' } }, required: ['path'] } },
] }];

// system + text
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([{ role: 'user', parts: [{ text: 'hello' }] }], { sys: 'You are helpful' }), MODEL), MODEL);
    check('system instruction → system message', oai.messages.some(m => m.role === 'system' && /helpful/.test(typeof m.content === 'string' ? m.content : JSON.stringify(m.content))));
}
// image (inlineData)
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([{ role: 'user', parts: [
        { text: 'what is this' }, { inlineData: { mimeType: 'image/png', data: 'aGVsbG8=' } }] }]), MODEL), MODEL);
    const u = oai.messages.find(m => m.role === 'user');
    const hasImg = Array.isArray(u.content) && u.content.some(p => p.type === 'image_url' && /data:image\/png;base64,/.test(p.image_url?.url || ''));
    check('inlineData image → OpenAI image_url data URI', hasImg, hasImg ? '' : `content=${JSON.stringify(u.content).slice(0,120)}`);
}
// thinking part
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([
        { role: 'model', parts: [{ text: 'let me think', thought: true }, { text: 'answer' }] },
        { role: 'user', parts: [{ text: 'next' }] }]), MODEL), MODEL);
    check('thinking part does not crash & yields assistant msg', oai.messages.some(m => m.role === 'assistant'));
}
// thinking-ONLY assistant turn must NOT leave an empty assistant message
// (content:null + no tool_calls) — strict backends 400 on it.
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([
        { role: 'user', parts: [{ text: 'hi' }] },
        { role: 'model', parts: [{ text: 'internal reasoning only', thought: true }] },
        { role: 'user', parts: [{ text: 'continue' }] }]), MODEL), MODEL);
    const emptyAsst = oai.messages.some(m => m.role === 'assistant'
        && (m.content === null || m.content === undefined || m.content === '')
        && (!m.tool_calls || m.tool_calls.length === 0));
    check('thinking-only assistant produces NO empty assistant message', !emptyAsst);
}
// thinking + tool_call: assistant(content:null) WITH tool_calls must be KEPT
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([
        { role: 'user', parts: [{ text: 'read a' }] },
        { role: 'model', parts: [{ text: 'reasoning', thought: true }, { functionCall: { name: 'read_file', args: { path: 'a' } } }] },
        { role: 'user', parts: [{ functionResponse: { name: 'read_file', response: { content: 'X' } } }] }]), MODEL), MODEL);
    const keptCall = oai.messages.some(m => m.role === 'assistant' && m.tool_calls && m.tool_calls.length === 1);
    check('thinking+toolcall keeps the assistant tool_call', keptCall);
}
// functionResponse under role:'model' (agy quirk) must still become a
// TOOL message carrying the real result content, not an empty placeholder.
{
    const oai = anthropicToOpenAI(geminiToAnthropic(gem([
        { role: 'user', parts: [{ text: 'read a' }] },
        { role: 'model', parts: [{ functionCall: { name: 'read_file', args: { path: 'a' } } }] },
        { role: 'model', parts: [{ functionResponse: { name: 'read_file', response: { output: 'FILE_BODY_123' } } }] }]), MODEL), MODEL);
    const tool = oai.messages.find(m => m.role === 'tool');
    check('functionResponse under role:model → tool msg with real content',
        !!tool && /FILE_BODY_123/.test(String(tool.content)),
        tool ? `len=${String(tool.content).length}` : 'NO TOOL MSG');
}
// parallel SAME-NAME tool calls then two responses (the README risk case)
{
    const contents = [
        { role: 'user', parts: [{ text: 'read two files' }] },
        { role: 'model', parts: [
            { functionCall: { name: 'read_file', args: { path: 'a' } } },
            { functionCall: { name: 'read_file', args: { path: 'b' } } } ] },
        { role: 'user', parts: [
            { functionResponse: { name: 'read_file', response: { content: 'AAA' } } },
            { functionResponse: { name: 'read_file', response: { content: 'BBB' } } } ] },
    ];
    const oai = anthropicToOpenAI(geminiToAnthropic(gem(contents, { tools: declTools }), MODEL), MODEL);
    validateOpenAI(oai, 'parallel-same-name');
    // Each result must map to a DISTINCT call id, content order preserved
    const calls = oai.messages.find(m => m.role === 'assistant' && m.tool_calls)?.tool_calls || [];
    const results = oai.messages.filter(m => m.role === 'tool');
    const ids = new Set(calls.map(c => c.id));
    const resIds = results.map(r => r.tool_call_id);
    check('parallel same-name: 2 calls, 2 results, distinct ids', calls.length === 2 && results.length === 2 && ids.size === 2 && new Set(resIds).size === 2,
        `calls=${calls.length} results=${results.length} callIds=${ids.size} resIds=${new Set(resIds).size}`);
    check('parallel same-name: result contents preserved', results.map(r=>r.content).join(',').includes('AAA') && results.map(r=>r.content).join(',').includes('BBB'));
}

console.log(failed === 0 ? '\nALL TRANSLATION TESTS PASSED' : `\n${failed} TEST(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
