/**
 * gemini-translator.js
 * ====================
 * Bidirectional translator between Google's Cloud Code Companion Gemini
 * API (what `agy` speaks) and the Anthropic Messages API (what most
 * cheap backends speak natively).
 *
 *   agy outbound (Gemini)   →  Anthropic Messages   (we forward this upstream)
 *   Anthropic SSE response  →  Gemini SSE response  (we hand this back to agy)
 *
 * SCHEMA REFERENCE
 * ----------------
 * Gemini request body shape used by `agy`:
 *
 *   {
 *     "model":  "models/gemini-2.5-pro",
 *     "request": {
 *        "contents": [
 *           { "role": "user",  "parts": [ {"text": "..."} ] },
 *           { "role": "model", "parts": [ {"text": "..."},
 *                                         {"functionCall": {"name":"X","args":{...}}} ] },
 *           { "role": "user",  "parts": [ {"functionResponse": {"name":"X","response":{...}}} ] }
 *        ],
 *        "systemInstruction": { "parts": [ {"text": "..."} ] },
 *        "tools": [ { "functionDeclarations": [ { "name":"X", "description":"...",
 *                                                  "parameters": {<JSON Schema>} } ] } ],
 *        "generationConfig": {
 *            "temperature": 0.7, "topP": 0.95,
 *            "maxOutputTokens": 8192,
 *            "stopSequences": ["..."],
 *            "thinkingConfig": { "includeThoughts": true }
 *        }
 *     }
 *   }
 *
 * Gemini streaming response chunk shape (one JSON object per SSE `data:`):
 *
 *   {
 *     "candidates": [{
 *        "content": { "role": "model", "parts": [ {"text":"..."} ] },
 *        "finishReason": "STOP" | "MAX_TOKENS" | "SAFETY" | ...
 *     }],
 *     "usageMetadata": { "promptTokenCount": 123, "candidatesTokenCount": 45 }
 *   }
 *
 * Notes:
 *   - Roles: Gemini uses "user" + "model" (NOT "assistant").
 *   - Tool use: Gemini parts include `functionCall` and `functionResponse`,
 *     not Anthropic's tool_use/tool_result block types.
 *   - Streaming: Gemini's stream is *also* JSON-array-of-chunks under
 *     `?alt=sse`, but `agy` opens it with `?alt=sse` so each chunk is
 *     wrapped as `data: {...}\n\n`. We mirror that.
 *   - "Thinking": Gemini parts can have `thought: true` for reasoning
 *     blocks. We pass these as Anthropic `thinking` blocks downstream.
 */

import { Transform } from 'stream';

// ─────────────────────────────────────────────────────────────────
// REQUEST: Gemini → Anthropic
// ─────────────────────────────────────────────────────────────────

/**
 * Convert a Gemini Cloud Code Companion request body to an Anthropic
 * Messages API request body.
 *
 * @param {object} geminiBody — the parsed Gemini request body. Note that
 *   `agy` wraps the actual GenerateContent payload under `request:`, so
 *   callers should pass `body.request || body`.
 * @param {string} targetModel — the upstream model name to substitute.
 * @returns {object} an Anthropic Messages API request body.
 */
export function geminiToAnthropic(geminiBody, targetModel) {
    const inner = geminiBody.request || geminiBody;
    const contents = inner.contents || [];
    const sysInstr = inner.systemInstruction;
    const tools    = inner.tools;
    const genCfg   = inner.generationConfig || {};

    const messages = [];
    let systemText = null;

    // System instruction → Anthropic `system`
    if (sysInstr) {
        systemText = extractText(sysInstr.parts || []);
    }

    // Convert each content turn
    for (const c of contents) {
        const role = c.role === 'model' ? 'assistant' : 'user';
        const parts = c.parts || [];
        const blocks = [];

        for (const p of parts) {
            if (p.text !== undefined) {
                if (p.thought) {
                    // Gemini "thinking" part → Anthropic thinking block
                    blocks.push({ type: 'thinking', thinking: p.text });
                } else {
                    blocks.push({ type: 'text', text: p.text });
                }
            } else if (p.inlineData) {
                // Gemini inline image → Anthropic image
                blocks.push({
                    type: 'image',
                    source: {
                        type: 'base64',
                        media_type: p.inlineData.mimeType,
                        data: p.inlineData.data,
                    },
                });
            } else if (p.functionCall) {
                blocks.push({
                    type:  'tool_use',
                    id:    p.functionCall.id || `toolu_${randHex(12)}`,
                    name:  p.functionCall.name,
                    input: p.functionCall.args || {},
                });
            } else if (p.functionResponse) {
                blocks.push({
                    type: 'tool_result',
                    tool_use_id: p.functionResponse.id || _matchToolUseId(messages, p.functionResponse.name),
                    content: stringifyForToolResult(p.functionResponse.response),
                });
            }
        }

        if (blocks.length === 0) continue;

        // Collapse a single text block to a string content for Anthropic compactness
        const content = blocks.length === 1 && blocks[0].type === 'text'
            ? blocks[0].text
            : blocks;
        messages.push({ role, content });
    }

    const result = {
        model: targetModel || stripModelPrefix(inner.model || geminiBody.model || 'unknown'),
        messages,
        max_tokens: genCfg.maxOutputTokens || 8192,
        stream: true, // agy always streams
    };

    if (systemText) result.system = systemText;
    if (genCfg.temperature !== undefined) result.temperature = genCfg.temperature;
    if (genCfg.topP !== undefined) result.top_p = genCfg.topP;
    if (genCfg.stopSequences && genCfg.stopSequences.length > 0) {
        result.stop_sequences = genCfg.stopSequences;
    }

    // Tools
    if (tools && tools.length > 0) {
        const anth = [];
        for (const tool of tools) {
            const decls = tool.functionDeclarations || [];
            for (const d of decls) {
                anth.push({
                    name: d.name,
                    description: d.description || '',
                    input_schema: normalizeJsonSchema(
                        d.parameters || { type: 'object', properties: {} }
                    ),
                });
            }
        }
        if (anth.length > 0) result.tools = anth;
    }

    return result;
}

/**
 * Gemini's tool parameter schemas use uppercase JSON Schema types
 * ("OBJECT", "STRING", "ARRAY", "NUMBER", "INTEGER", "BOOLEAN") because
 * they're really protobuf enum names. Anthropic's tools API only accepts
 * lowercase JSON Schema types ("object", "string", etc.). Walk the
 * schema and lowercase every `type` field. Also normalize the format
 * field where it matters.
 */
function normalizeJsonSchema(schema) {
    if (!schema || typeof schema !== 'object') return schema;
    if (Array.isArray(schema)) return schema.map(normalizeJsonSchema);

    const out = {};
    for (const [k, v] of Object.entries(schema)) {
        if (k === 'type' && typeof v === 'string') {
            out[k] = v.toLowerCase();
        } else if (k === 'format' && typeof v === 'string') {
            // Gemini uses "STRING_FORMAT_DATE_TIME" etc. — keep simple ones,
            // strip Gemini-internal prefixes.
            out[k] = v.toLowerCase().replace(/^string_format_/, '');
        } else if (k === 'properties' && v && typeof v === 'object') {
            // Recurse into each property
            const props = {};
            for (const [pk, pv] of Object.entries(v)) {
                props[pk] = normalizeJsonSchema(pv);
            }
            out[k] = props;
        } else if (k === 'items' || k === 'additionalProperties') {
            out[k] = normalizeJsonSchema(v);
        } else if ((k === 'allOf' || k === 'anyOf' || k === 'oneOf') && Array.isArray(v)) {
            out[k] = v.map(normalizeJsonSchema);
        } else {
            out[k] = v;
        }
    }
    return out;
}

function extractText(parts) {
    return parts.filter(p => p.text !== undefined).map(p => p.text).join('\n');
}

function stripModelPrefix(name) {
    // "models/gemini-2.5-pro" → "gemini-2.5-pro"
    return name.replace(/^models\//, '');
}

function stringifyForToolResult(v) {
    if (typeof v === 'string') return v;
    return JSON.stringify(v);
}

/**
 * Best-effort: find the most recent assistant tool_use block whose name
 * matches, and return its id. Used when Gemini's functionResponse parts
 * lack an explicit `id` field (which is common from `agy`).
 */
function _matchToolUseId(messages, name) {
    for (let i = messages.length - 1; i >= 0; i--) {
        const m = messages[i];
        if (m.role !== 'assistant' || !Array.isArray(m.content)) continue;
        for (const b of m.content) {
            if (b.type === 'tool_use' && b.name === name) return b.id;
        }
    }
    return `toolu_${randHex(12)}`;
}


// ─────────────────────────────────────────────────────────────────
// RESPONSE: Anthropic → Gemini  (non-streaming)
// ─────────────────────────────────────────────────────────────────

/**
 * Convert an Anthropic Messages response to a Gemini
 * GenerateContentResponse. Used only when the proxy needs to return
 * a non-streaming response (rare — `agy` always streams).
 */
export function anthropicToGemini(anth, originalGeminiModel) {
    const parts = [];
    for (const block of (anth.content || [])) {
        if (block.type === 'text') {
            parts.push({ text: block.text });
        } else if (block.type === 'thinking') {
            parts.push({ text: block.thinking, thought: true });
        } else if (block.type === 'tool_use') {
            parts.push({
                functionCall: {
                    id: block.id,
                    name: block.name,
                    args: block.input || {},
                },
            });
        }
    }
    if (parts.length === 0) parts.push({ text: '' });

    return {
        candidates: [{
            content: { role: 'model', parts },
            finishReason: mapStopReason(anth.stop_reason),
            index: 0,
        }],
        usageMetadata: {
            promptTokenCount:     anth.usage?.input_tokens  || 0,
            candidatesTokenCount: anth.usage?.output_tokens || 0,
            totalTokenCount: (anth.usage?.input_tokens || 0)
                            + (anth.usage?.output_tokens || 0),
        },
        modelVersion: stripModelPrefix(originalGeminiModel || anth.model || 'unknown'),
    };
}

function mapStopReason(s) {
    switch (s) {
        case 'end_turn':   return 'STOP';
        case 'tool_use':   return 'STOP';   // Gemini doesn't have a tool stop reason
        case 'max_tokens': return 'MAX_TOKENS';
        case 'stop_sequence': return 'STOP';
        default: return 'STOP';
    }
}


// ─────────────────────────────────────────────────────────────────
// STREAMING: Anthropic SSE → Gemini SSE
// ─────────────────────────────────────────────────────────────────

/**
 * Transform stream that converts Anthropic SSE (Messages streaming)
 * into Gemini's `?alt=sse` streaming response.
 *
 * Anthropic emits typed SSE events:
 *   event: message_start         {message:{...}}
 *   event: content_block_start   {index, content_block:{type, ...}}
 *   event: content_block_delta   {index, delta:{type, text|partial_json}}
 *   event: content_block_stop    {index}
 *   event: message_delta         {delta:{stop_reason, stop_sequence}, usage:{output_tokens}}
 *   event: message_stop          {}
 *
 * Gemini streaming uses simple `data: {<chunk JSON>}\n\n` — every chunk
 * is a partial GenerateContentResponse with `candidates[0].content.parts[].text`
 * accumulating, plus `finishReason` + `usageMetadata` on the last chunk.
 *
 * Tool call deltas in Anthropic stream as `input_json_delta`. We
 * accumulate the partial JSON until block_stop, parse it, then emit
 * one Gemini chunk with `functionCall: {name, args}`.
 */
export class AnthropicToGeminiStream extends Transform {
    constructor({ originalGeminiModel } = {}) {
        super();
        this._buf = '';
        this._modelVersion = stripModelPrefix(originalGeminiModel || 'unknown');
        this._currentBlock = null; // { type, index, name?, id?, partial? }
        this._inputTokens = 0;
        this._outputTokens = 0;
        this._stopReason = 'STOP';
        this._stoppedEmitted = false;
        // Real Gemini emits a stable `responseId` on every chunk in a
        // streaming response. agy uses this to correlate chunks. Without
        // it, `agy --print` may discard the response.
        this._responseId = 'rid-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
        // Real Gemini also includes a traceId on every chunk (16 hex chars).
        this._traceId = randHex(16);
    }

    _transform(chunk, _enc, cb) {
        this._buf += chunk.toString();
        // SSE events are separated by blank lines
        let idx;
        while ((idx = this._buf.indexOf('\n\n')) !== -1) {
            const event = this._buf.slice(0, idx);
            this._buf = this._buf.slice(idx + 2);
            this._handleEvent(event);
        }
        cb();
    }

    _flush(cb) {
        if (this._buf.trim()) this._handleEvent(this._buf);
        if (!this._stoppedEmitted) this._emitFinal();
        cb();
    }

    _handleEvent(raw) {
        const lines = raw.split('\n');
        let dataStr = '';
        for (const line of lines) {
            // The SSE spec allows either "data:foo" or "data: foo"; strip
            // an optional single leading space after the colon. Kimi's
            // upstream uses no-space ("data:{...}"); Anthropic's spec
            // uses one space ("data: {...}"). Without this, no-space
            // chunks are silently dropped, and we only emit the final
            // usage chunk — which is what was happening for Kimi.
            if (line.startsWith('data:')) {
                dataStr += line.slice(5).replace(/^ /, '');
            }
        }
        if (!dataStr) return;
        let data;
        try { data = JSON.parse(dataStr); } catch { return; }

        switch (data.type) {
            case 'message_start': {
                if (data.message?.usage) {
                    this._inputTokens = data.message.usage.input_tokens || 0;
                    this._outputTokens = data.message.usage.output_tokens || 0;
                }
                // PROOF OF BACKEND: the upstream (Kimi / Nvidia) echoes the
                // real model name it served in `message.model`. We surface
                // it as Gemini's `modelVersion` so `agy` displays the
                // ACTUAL model (e.g. "stepfun-ai/step-3.7-flash") instead
                // of the Gemini name agy requested. This is how you can
                // verify the response really came from the chosen backend.
                if (data.message?.model) {
                    this._modelVersion = data.message.model;
                }
                break;
            }
            case 'content_block_start': {
                const cb = data.content_block || {};
                this._currentBlock = {
                    type: cb.type,
                    index: data.index,
                    name: cb.name,
                    id: cb.id,
                    partial: '',
                };
                break;
            }
            case 'content_block_delta': {
                const d = data.delta || {};
                if (d.type === 'text_delta' && d.text) {
                    this._emitTextChunk(d.text);
                } else if (d.type === 'thinking_delta' && d.thinking) {
                    this._emitTextChunk(d.thinking, /*thought=*/true);
                } else if (d.type === 'input_json_delta' && d.partial_json) {
                    if (this._currentBlock) this._currentBlock.partial += d.partial_json;
                }
                break;
            }
            case 'content_block_stop': {
                const blk = this._currentBlock;
                if (blk && blk.type === 'tool_use') {
                    let args = {};
                    try { args = blk.partial ? JSON.parse(blk.partial) : {}; }
                    catch { args = { _raw: blk.partial }; }
                    this._emitFunctionCall(blk.name, blk.id, args);
                }
                this._currentBlock = null;
                break;
            }
            case 'message_delta': {
                if (data.delta?.stop_reason) {
                    this._stopReason = mapStopReason(data.delta.stop_reason);
                }
                if (data.usage?.output_tokens !== undefined) {
                    this._outputTokens = data.usage.output_tokens;
                }
                break;
            }
            case 'message_stop': {
                this._emitFinal();
                break;
            }
        }
    }

    _emitTextChunk(text, thought = false) {
        const part = thought ? { text, thought: true } : { text };
        // Real Gemini wraps each chunk in { response: {...}, traceId,
        // metadata }. agy parses `data.response.candidates`; we were
        // sending unwrapped candidates which caused a nil-pointer panic
        // in third_party/.../generation.go:541. The wrapper is required.
        const chunk = {
            response: {
                candidates: [{
                    content: { role: 'model', parts: [ part ] },
                }],
                modelVersion: this._modelVersion,
                responseId: this._responseId,
            },
            traceId: this._traceId,
            metadata: {},
        };
        this.push(`data: ${JSON.stringify(chunk)}\n\n`);
    }

    _emitFunctionCall(name, id, args) {
        const chunk = {
            response: {
                candidates: [{
                    content: {
                        role: 'model',
                        parts: [{ functionCall: { id, name, args } }],
                    },
                }],
                modelVersion: this._modelVersion,
                responseId: this._responseId,
            },
            traceId: this._traceId,
            metadata: {},
        };
        this.push(`data: ${JSON.stringify(chunk)}\n\n`);
    }

    _emitFinal() {
        if (this._stoppedEmitted) return;
        this._stoppedEmitted = true;
        const chunk = {
            response: {
                candidates: [{
                    content: { role: 'model', parts: [{ text: '' }] },
                    finishReason: this._stopReason,
                }],
                usageMetadata: {
                    promptTokenCount:     this._inputTokens,
                    candidatesTokenCount: this._outputTokens,
                    totalTokenCount:      this._inputTokens + this._outputTokens,
                },
                modelVersion: this._modelVersion,
                responseId: this._responseId,
            },
            traceId: this._traceId,
            metadata: {},
        };
        this.push(`data: ${JSON.stringify(chunk)}\n\n`);
    }
}


// ─────────────────────────────────────────────────────────────────
// fetchAvailableModels response — agy calls this on startup
// ─────────────────────────────────────────────────────────────────

/**
 * Synthesize a FetchAvailableModelsResponse so `agy` can boot. We
 * advertise a small set of "Gemini" model IDs that we'll route to
 * whatever upstream backend the user picked.
 */
export function fakeAvailableModels() {
    const make = (id, displayName, contextWindow = 1000000) => ({
        id,
        displayName,
        contextWindow,
        capabilities: { agent: true, command: true, tab: true, mquery: true, webSearch: true },
    });
    return {
        models: [
            make('gemini-2.5-pro',          'Gemini 2.5 Pro (deepantigravity)', 2000000),
            make('gemini-2.5-flash',        'Gemini 2.5 Flash (deepantigravity)'),
            make('gemini-3-flash-preview',  'Gemini 3 Flash (deepantigravity)'),
        ],
        defaultAgentModelId: 'gemini-2.5-pro',
        commandModelIds:          ['gemini-2.5-flash'],
        tabModelIds:              ['gemini-2.5-flash'],
        mqueryModelIds:           ['gemini-2.5-flash'],
        webSearchModelIds:        ['gemini-2.5-flash'],
        commitMessageModelIds:    ['gemini-2.5-flash'],
        audioTranscriptionModelIds: [],
    };
}


// ─────────────────────────────────────────────────────────────────
// Misc helpers
// ─────────────────────────────────────────────────────────────────

function randHex(n) {
    const buf = Buffer.allocUnsafe(Math.ceil(n / 2));
    for (let i = 0; i < buf.length; i++) buf[i] = Math.floor(Math.random() * 256);
    return buf.toString('hex').slice(0, n);
}
