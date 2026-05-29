/**
 * openai-translator.js
 * =====================
 * Bidirectional translator between Anthropic Messages API format
 * and OpenAI Chat Completions API format.
 *
 * Claude Code speaks Anthropic protocol. OpenAI-compatible providers
 * (Nvidia, Doubleword, etc.) speak OpenAI protocol. This module sits
 * in the proxy and translates:
 *
 *   Anthropic Request  →  OpenAI Request   (outbound)
 *   OpenAI Response    →  Anthropic Response (inbound)
 *   OpenAI SSE Stream  →  Anthropic SSE Stream (inbound streaming)
 */

import { Transform } from 'stream';

// ─────────────────────────────────────────────────────────────────
// REQUEST: Anthropic → OpenAI
// ─────────────────────────────────────────────────────────────────

/**
 * Convert an Anthropic Messages API request body to an OpenAI
 * Chat Completions request body.
 */
export function anthropicToOpenAI(body, targetModel) {
    const messages = [];

    // System prompt → OpenAI system message
    if (body.system) {
        if (typeof body.system === 'string') {
            messages.push({ role: 'system', content: body.system });
        } else if (Array.isArray(body.system)) {
            // Anthropic allows system as array of content blocks
            const text = body.system
                .filter(b => b.type === 'text')
                .map(b => b.text)
                .join('\n');
            if (text) messages.push({ role: 'system', content: text });
        }
    }

    // Convert each Anthropic message
    for (const msg of (body.messages || [])) {
        const converted = convertAnthropicMessage(msg);
        if (converted) {
            if (Array.isArray(converted)) {
                messages.push(...converted);
            } else {
                messages.push(converted);
            }
        }
    }

    // Normalize so the sequence satisfies OpenAI-compat chat-template
    // rules (qwen, mistral, etc. are strict and 400 otherwise).
    const normalized = normalizeForOpenAI(messages);

    // OpenAI-compat servers build the next-turn prompt with
    // `add_generation_prompt=True`, which REQUIRES the last message to
    // NOT be an assistant message — otherwise they 400 with "Cannot set
    // add_generation_prompt to True when the last message is from the
    // assistant". agy's history can end on an assistant turn, so append
    // a minimal user nudge to give the server a turn to generate from.
    if (normalized.length > 0 && normalized[normalized.length - 1].role === 'assistant') {
        normalized.push({ role: 'user', content: 'Continue.' });
    }

    const result = {
        model: targetModel || body.model,
        messages: normalized,
        stream: body.stream !== false,  // default to streaming
    };

    // Max tokens
    if (body.max_tokens) {
        result.max_tokens = body.max_tokens;
    }

    // Temperature
    if (body.temperature !== undefined) {
        result.temperature = body.temperature;
    }

    // Top-p
    if (body.top_p !== undefined) {
        result.top_p = body.top_p;
    }

    // Stop sequences
    if (body.stop_sequences && body.stop_sequences.length > 0) {
        result.stop = body.stop_sequences;
    }

    // Tools → OpenAI function calling format
    if (body.tools && body.tools.length > 0) {
        result.tools = body.tools.map(tool => ({
            type: 'function',
            function: {
                name: tool.name,
                description: tool.description || '',
                parameters: tool.input_schema || { type: 'object', properties: {} },
            },
        }));
        // tool_choice
        if (body.tool_choice) {
            if (body.tool_choice.type === 'auto') {
                result.tool_choice = 'auto';
            } else if (body.tool_choice.type === 'any') {
                result.tool_choice = 'required';
            } else if (body.tool_choice.type === 'tool') {
                result.tool_choice = {
                    type: 'function',
                    function: { name: body.tool_choice.name },
                };
            }
        }
    }

    // Stream options for usage in streaming mode
    if (result.stream) {
        result.stream_options = { include_usage: true };
    }

    return result;
}

/**
 * Make a flat OpenAI message list satisfy the strict chat-template rules
 * that OpenAI-compatible servers (qwen, mistral, etc.) enforce:
 *
 *   1. Every `assistant` message that has `tool_calls` must be followed
 *      by EXACTLY one `tool` message per tool_call id (same count, same
 *      ids). agy histories can have partial results (model called 2
 *      tools, only 1 result present yet) → "Not the same number of
 *      function calls and responses". We synthesize a placeholder result
 *      for any missing id and drop `tool` messages that reference an id
 *      not present in the immediately-preceding assistant turn.
 *   2. No two `assistant` messages back-to-back (consecutive model turns
 *      from Gemini). We merge them so tool_calls stay attached to their
 *      results.
 */
function normalizeForOpenAI(msgs) {
    // Pass 1: merge consecutive assistant messages.
    const merged = [];
    for (const m of msgs) {
        const prev = merged[merged.length - 1];
        if (m.role === 'assistant' && prev && prev.role === 'assistant') {
            // Concatenate text content and tool_calls.
            const txt = [prev.content, m.content].filter(Boolean).join('');
            prev.content = txt || null;
            const tc = [...(prev.tool_calls || []), ...(m.tool_calls || [])];
            if (tc.length) prev.tool_calls = tc;
            continue;
        }
        merged.push({ ...m });
    }

    // Pass 2: reconcile tool_calls with following tool messages.
    const out = [];
    for (let i = 0; i < merged.length; i++) {
        const m = merged[i];
        out.push(m);
        if (m.role !== 'assistant' || !m.tool_calls || m.tool_calls.length === 0) continue;

        // Collect the contiguous tool messages that follow.
        const provided = new Map();   // id → tool message
        let j = i + 1;
        while (j < merged.length && merged[j].role === 'tool') {
            provided.set(merged[j].tool_call_id, merged[j]);
            j++;
        }
        // Emit exactly one tool message per call id, in call order.
        for (const call of m.tool_calls) {
            if (provided.has(call.id)) {
                out.push(provided.get(call.id));
            } else {
                // Missing result → synthesize a neutral placeholder so the
                // counts match (the model called it but no result arrived).
                out.push({ role: 'tool', tool_call_id: call.id, content: '' });
            }
        }
        i = j - 1;   // skip the tool messages we just consumed (orphans dropped)
    }
    return out;
}

/**
 * Convert a single Anthropic message to OpenAI message(s).
 */
function convertAnthropicMessage(msg) {
    if (msg.role === 'user') {
        return convertUserMessage(msg);
    }
    if (msg.role === 'assistant') {
        return convertAssistantMessage(msg);
    }
    return null;
}

function convertUserMessage(msg) {
    // Simple string content
    if (typeof msg.content === 'string') {
        return { role: 'user', content: msg.content };
    }

    // Array of content blocks
    if (Array.isArray(msg.content)) {
        // Check for tool_result blocks (these become separate messages in OpenAI)
        const toolResults = msg.content.filter(b => b.type === 'tool_result');
        const otherBlocks = msg.content.filter(b => b.type !== 'tool_result');

        const results = [];

        // IMPORTANT: emit tool messages FIRST. OpenAI-compat servers
        // require every assistant(tool_calls) message to be immediately
        // followed by its tool message(s); a user/text message in between
        // is a 400. A single Gemini `user` turn can carry BOTH a
        // functionResponse and extra text, so order tools before text.
        for (const tr of toolResults) {
            let content = '';
            if (typeof tr.content === 'string') {
                content = tr.content;
            } else if (Array.isArray(tr.content)) {
                content = tr.content
                    .filter(b => b.type === 'text')
                    .map(b => b.text)
                    .join('\n');
            }
            results.push({
                role: 'tool',
                tool_call_id: tr.tool_use_id,
                content: content || '',
            });
        }

        // Non-tool blocks become a user message (after the tool messages)
        if (otherBlocks.length > 0) {
            const parts = [];
            for (const block of otherBlocks) {
                if (block.type === 'text') {
                    parts.push({ type: 'text', text: block.text });
                } else if (block.type === 'image') {
                    // Anthropic image → OpenAI image_url
                    if (block.source?.type === 'base64') {
                        parts.push({
                            type: 'image_url',
                            image_url: {
                                url: `data:${block.source.media_type};base64,${block.source.data}`,
                            },
                        });
                    } else if (block.source?.type === 'url') {
                        parts.push({
                            type: 'image_url',
                            image_url: { url: block.source.url },
                        });
                    }
                }
            }
            if (parts.length === 1 && parts[0].type === 'text') {
                results.push({ role: 'user', content: parts[0].text });
            } else if (parts.length > 0) {
                results.push({ role: 'user', content: parts });
            }
        }

        return results.length === 1 ? results[0] : results;
    }

    return { role: 'user', content: String(msg.content) };
}

function convertAssistantMessage(msg) {
    if (typeof msg.content === 'string') {
        return { role: 'assistant', content: msg.content };
    }

    if (Array.isArray(msg.content)) {
        const textParts = [];
        const toolCalls = [];

        for (const block of msg.content) {
            if (block.type === 'text') {
                textParts.push(block.text);
            } else if (block.type === 'tool_use') {
                toolCalls.push({
                    id: block.id,
                    type: 'function',
                    function: {
                        name: block.name,
                        arguments: typeof block.input === 'string'
                            ? block.input
                            : JSON.stringify(block.input),
                    },
                });
            }
            // Skip 'thinking' blocks — already stripped by the proxy
        }

        const result = { role: 'assistant' };
        if (textParts.length > 0) {
            result.content = textParts.join('');
        } else {
            result.content = null;
        }
        if (toolCalls.length > 0) {
            result.tool_calls = toolCalls;
        }
        return result;
    }

    return { role: 'assistant', content: String(msg.content) };
}


// ─────────────────────────────────────────────────────────────────
// RESPONSE: OpenAI → Anthropic (non-streaming)
// ─────────────────────────────────────────────────────────────────

/**
 * Convert an OpenAI Chat Completions response to an Anthropic
 * Messages API response.
 */
export function openAIToAnthropic(openaiResp, requestModel) {
    const choice = openaiResp.choices?.[0];
    if (!choice) {
        return {
            id: openaiResp.id || `msg_${Date.now()}`,
            type: 'message',
            role: 'assistant',
            content: [],
            model: requestModel || openaiResp.model,
            stop_reason: 'end_turn',
            stop_sequence: null,
            usage: {
                input_tokens: openaiResp.usage?.prompt_tokens || 0,
                output_tokens: openaiResp.usage?.completion_tokens || 0,
            },
        };
    }

    const content = [];
    const message = choice.message;

    // Text content — check both content and reasoning fields
    // Doubleword/some providers return reasoning in a separate field
    // when content is null
    if (message.content) {
        content.push({ type: 'text', text: message.content });
    } else if (message.reasoning) {
        // Doubleword returns reasoning text when content is null
        content.push({ type: 'text', text: message.reasoning });
    }

    // Tool calls → Anthropic tool_use blocks
    if (message.tool_calls) {
        for (const tc of message.tool_calls) {
            let input;
            try {
                input = JSON.parse(tc.function.arguments);
            } catch {
                input = { raw: tc.function.arguments };
            }
            content.push({
                type: 'tool_use',
                id: tc.id,
                name: tc.function.name,
                input,
            });
        }
    }

    // If no content at all, add empty text
    if (content.length === 0) {
        content.push({ type: 'text', text: '' });
    }

    // Map finish_reason to stop_reason
    let stopReason = 'end_turn';
    if (choice.finish_reason === 'tool_calls' || choice.finish_reason === 'function_call') {
        stopReason = 'tool_use';
    } else if (choice.finish_reason === 'length') {
        stopReason = 'max_tokens';
    } else if (choice.finish_reason === 'stop') {
        stopReason = 'end_turn';
    }

    return {
        id: openaiResp.id || `msg_${Date.now()}`,
        type: 'message',
        role: 'assistant',
        content,
        model: requestModel || openaiResp.model,
        stop_reason: stopReason,
        stop_sequence: null,
        usage: {
            input_tokens: openaiResp.usage?.prompt_tokens || 0,
            output_tokens: openaiResp.usage?.completion_tokens || 0,
        },
    };
}


// ─────────────────────────────────────────────────────────────────
// STREAMING: OpenAI SSE → Anthropic SSE
// ─────────────────────────────────────────────────────────────────

/**
 * Transform stream that converts OpenAI streaming SSE chunks
 * into Anthropic streaming SSE events.
 *
 * OpenAI emits: data: {"choices":[{"delta":{"content":"..."}}]}
 * Anthropic expects:
 *   event: message_start       → {type:"message_start", message:{...}}
 *   event: content_block_start → {type:"content_block_start", index:0, content_block:{type:"text",text:""}}
 *   event: content_block_delta → {type:"content_block_delta", index:0, delta:{type:"text_delta",text:"..."}}
 *   event: content_block_stop  → {type:"content_block_stop", index:0}
 *   event: message_delta       → {type:"message_delta", delta:{stop_reason:"end_turn"}, usage:{output_tokens:N}}
 *   event: message_stop        → {type:"message_stop"}
 */
export class OpenAIToAnthropicStream extends Transform {
    constructor(requestModel, onUsage) {
        super();
        this._buf = '';
        this._requestModel = requestModel;
        this._onUsage = onUsage;
        this._started = false;
        this._currentBlockIndex = -1;
        this._currentBlockType = null;  // 'text' | 'tool_use' | 'thinking'
        this._inputTokens = 0;
        this._outputTokens = 0;
        this._toolCallBuffers = {};     // id → {id, name, arguments}
        this._textStarted = false;
        this._thinkingStarted = false;  // for reasoning_content (Nvidia gpt-oss-*, Doubleword, etc.)
        this._messageId = `msg_${Date.now()}`;
    }

    _transform(chunk, _enc, cb) {
        this._buf += chunk.toString();
        const parts = this._buf.split('\n');
        // Keep the last incomplete line in the buffer
        this._buf = parts.pop();

        for (const line of parts) {
            this._processLine(line.trim());
        }
        cb();
    }

    _flush(cb) {
        // Process any remaining data
        if (this._buf.trim()) {
            this._processLine(this._buf.trim());
        }

        // Only emit closing events if we haven't already finished
        if (!this._finished) {
            // Close any open blocks
            if (this._currentBlockIndex >= 0 && this._currentBlockType !== null) {
                this._emitEvent('content_block_stop', { type: 'content_block_stop', index: this._currentBlockIndex });
            }

            // Emit message_delta and message_stop if we started
            if (this._started) {
                this._emitEvent('message_delta', {
                    type: 'message_delta',
                    delta: { stop_reason: 'end_turn', stop_sequence: null },
                    usage: { output_tokens: this._outputTokens },
                });
                this._emitEvent('message_stop', { type: 'message_stop' });
            }
        }

        if (this._onUsage) {
            this._onUsage(this._inputTokens, this._outputTokens);
        }
        cb();
    }

    _processLine(line) {
        if (!line.startsWith('data: ')) return;
        const data = line.slice(6);
        if (data === '[DONE]') {
            // Stream finished — handled in _flush
            return;
        }

        let parsed;
        try {
            parsed = JSON.parse(data);
        } catch {
            return; // Not valid JSON
        }

        // Emit message_start on first chunk
        if (!this._started && !this._finished) {
            this._started = true;
            // PROOF: prefer the model the UPSTREAM SERVER echoes back
            // (parsed.model) over the model we requested. Nvidia/OpenAI-
            // compat servers return the real model id they served in
            // every chunk's `model` field — this is server-authoritative
            // evidence of which backend actually answered.
            const upstreamModel = parsed.model || this._requestModel || 'unknown';
            this._upstreamModel = upstreamModel;
            this._emitEvent('message_start', {
                type: 'message_start',
                message: {
                    id: parsed.id || this._messageId,
                    type: 'message',
                    role: 'assistant',
                    content: [],
                    model: upstreamModel,
                    stop_reason: null,
                    stop_sequence: null,
                    usage: { input_tokens: 0, output_tokens: 0 },
                },
            });
        }

        // Track usage from stream_options (even after finished)
        if (parsed.usage) {
            this._inputTokens = parsed.usage.prompt_tokens || this._inputTokens;
            this._outputTokens = parsed.usage.completion_tokens || this._outputTokens;
        }

        // After we've finished, only capture usage — don't emit more events
        if (this._finished) return;

        const choice = parsed.choices?.[0];
        if (!choice) return;

        const delta = choice.delta || {};
        const finishReason = choice.finish_reason;

        // ── reasoning_content (Nvidia gpt-oss-*, DeepSeek, Doubleword) ──
        // These providers stream the model's chain-of-thought in
        // delta.reasoning_content before any delta.content. We surface
        // it as an Anthropic `thinking` block so our downstream
        // gemini-translator emits it as `thought:true` Gemini parts.
        // Without this, agy sees no output at all during a long reasoning
        // phase and may time out.
        const reasoningChunk = delta.reasoning_content || delta.reasoning;
        if (reasoningChunk) {
            if (!this._thinkingStarted) {
                // Close any prior block (shouldn't happen, but defensive)
                if (this._currentBlockIndex >= 0 && this._currentBlockType !== null) {
                    this._emitEvent('content_block_stop', {
                        type: 'content_block_stop',
                        index: this._currentBlockIndex,
                    });
                }
                this._thinkingStarted = true;
                this._currentBlockIndex++;
                this._currentBlockType = 'thinking';
                this._emitEvent('content_block_start', {
                    type: 'content_block_start',
                    index: this._currentBlockIndex,
                    content_block: { type: 'thinking', thinking: '' },
                });
            }
            this._emitEvent('content_block_delta', {
                type: 'content_block_delta',
                index: this._currentBlockIndex,
                delta: { type: 'thinking_delta', thinking: reasoningChunk },
            });
        }

        // Handle text content from delta.content
        // Doubleword sends content: "" (empty) + reasoning: "..." during thinking.
        // We SKIP reasoning-only chunks — they're internal thinking, not output.
        // Only emit when content has actual text (non-empty string).
        const hasContent = delta.content !== undefined && delta.content !== null;
        const hasActualContent = hasContent && delta.content !== '';

        if (hasActualContent) {
            // If a thinking block is open, close it first — text and
            // thinking are separate blocks in Anthropic's protocol.
            if (this._thinkingStarted && this._currentBlockType === 'thinking') {
                this._emitEvent('content_block_stop', {
                    type: 'content_block_stop',
                    index: this._currentBlockIndex,
                });
                this._currentBlockType = null;
            }

            if (!this._textStarted) {
                this._textStarted = true;
                this._currentBlockIndex++;
                this._currentBlockType = 'text';
                this._emitEvent('content_block_start', {
                    type: 'content_block_start',
                    index: this._currentBlockIndex,
                    content_block: { type: 'text', text: '' },
                });
            }
            this._emitEvent('content_block_delta', {
                type: 'content_block_delta',
                index: this._currentBlockIndex,
                delta: { type: 'text_delta', text: delta.content },
            });
        }

        // Handle tool calls
        if (delta.tool_calls) {
            for (const tc of delta.tool_calls) {
                const tcIndex = tc.index !== undefined ? tc.index : 0;
                const tcKey = `tc_${tcIndex}`;

                if (!this._toolCallBuffers[tcKey]) {
                    // Close any previous block
                    if (this._currentBlockIndex >= 0 && this._currentBlockType !== null) {
                        this._emitEvent('content_block_stop', {
                            type: 'content_block_stop',
                            index: this._currentBlockIndex,
                        });
                    }

                    // New tool call
                    this._currentBlockIndex++;
                    this._currentBlockType = 'tool_use';
                    this._toolCallBuffers[tcKey] = {
                        id: tc.id || `toolu_${Date.now()}_${tcIndex}`,
                        name: tc.function?.name || '',
                        arguments: '',
                        blockIndex: this._currentBlockIndex,
                    };

                    this._emitEvent('content_block_start', {
                        type: 'content_block_start',
                        index: this._currentBlockIndex,
                        content_block: {
                            type: 'tool_use',
                            id: this._toolCallBuffers[tcKey].id,
                            name: this._toolCallBuffers[tcKey].name,
                            input: {},
                        },
                    });
                }

                // Accumulate tool call arguments
                if (tc.function?.arguments) {
                    this._toolCallBuffers[tcKey].arguments += tc.function.arguments;
                    this._emitEvent('content_block_delta', {
                        type: 'content_block_delta',
                        index: this._toolCallBuffers[tcKey].blockIndex,
                        delta: {
                            type: 'input_json_delta',
                            partial_json: tc.function.arguments,
                        },
                    });
                }

                // Update name if provided
                if (tc.function?.name) {
                    this._toolCallBuffers[tcKey].name = tc.function.name;
                }
            }
        }

        // Handle finish_reason
        // Doubleword sends TWO chunks with finish_reason (one without usage,
        // one with usage). Only emit message end events once.
        if (finishReason && !this._finished) {
            this._finished = true;

            // Close open block
            if (this._currentBlockIndex >= 0 && this._currentBlockType !== null) {
                this._emitEvent('content_block_stop', {
                    type: 'content_block_stop',
                    index: this._currentBlockIndex,
                });
                this._currentBlockType = null;
            }

            // Map finish reason
            let stopReason = 'end_turn';
            if (finishReason === 'tool_calls' || finishReason === 'function_call') {
                stopReason = 'tool_use';
            } else if (finishReason === 'length') {
                stopReason = 'max_tokens';
            }

            this._emitEvent('message_delta', {
                type: 'message_delta',
                delta: { stop_reason: stopReason, stop_sequence: null },
                usage: { output_tokens: this._outputTokens },
            });
            this._emitEvent('message_stop', { type: 'message_stop' });
            this._started = false; // Prevent _flush from double-emitting
        }
    }

    _emitEvent(eventType, data) {
        this.push(`event: ${eventType}\ndata: ${JSON.stringify(data)}\n\n`);
    }
}


// ─────────────────────────────────────────────────────────────────
// RESPONSE HEADERS: Fix content-type for translated responses
// ─────────────────────────────────────────────────────────────────

/**
 * Fix upstream response headers for Anthropic format.
 * OpenAI returns application/json or text/event-stream;
 * Claude Code expects the same content types.
 */
export function fixResponseHeaders(headers, isStreaming) {
    const fixed = { ...headers };
    if (isStreaming) {
        fixed['content-type'] = 'text/event-stream';
    } else {
        fixed['content-type'] = 'application/json';
    }
    // Remove transfer-encoding since we may modify content
    delete fixed['content-length'];
    delete fixed['transfer-encoding'];
    return fixed;
}
