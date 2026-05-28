#!/usr/bin/env node
/**
 * start-proxy.js
 * ==============
 * Boot the deepantigravity HTTPS-MITM proxy.
 *
 * Usage:
 *   node start-proxy.js <backend> [port] [bind-ip]
 *
 * Reads the upstream URL/key/model from standard env vars (the launcher
 * exports them after sourcing proxy/.env). On success, prints two lines
 * to stdout:
 *
 *   <listenPort>
 *   <ca-pem-path>
 *
 * The launcher reads these and sets SSL_CERT_FILE=<bundle path> before
 * exec'ing `agy`.
 *
 * Supported backends: kimi (Anthropic-native upstream) and nvidia
 * (OpenAI-compat upstream — translation hops Gemini → Anthropic →
 * OpenAI on outbound and the reverse on inbound).
 */

import { startProxy } from './model-proxy.js';

const BACKEND_DEFS = {
    kimi: {
        urlDefault:   'https://api.kimi.com/coding',
        keyEnv:       'KIMI_API_KEY',
        modelEnv:     'KIMI_MODEL',
        modelDefault: 'kimi-for-coding',
    },
    nvidia: {
        urlDefault:   'https://integrate.api.nvidia.com/v1',
        keyEnv:       'NVIDIA_API_KEY',
        modelEnv:     'NVIDIA_MODEL',
        modelDefault: 'openai/gpt-oss-120b',
    },
};

function die(msg) {
    console.error('[deepantigravity] ' + msg);
    process.exit(1);
}

const [backendArg, portArg, bindIpArg] = process.argv.slice(2);
if (!backendArg) die('usage: node start-proxy.js <backend> [port] [bind-ip]');

const backend = canonicalize(backendArg);
const def = BACKEND_DEFS[backend];
if (!def) die(`unsupported backend: ${backendArg} (only kimi and nvidia are supported)`);

const upstreamKey = process.env[def.keyEnv] || '';
const targetModel = process.env[def.modelEnv] || def.modelDefault;
const upstreamUrl = process.env[def.urlEnv] || def.urlDefault;

if (!upstreamKey) {
    die(`${def.keyEnv} not set. Edit proxy/.env or export it.`);
}

const port = parseInt(portArg || process.env.DEEPANTIGRAVITY_PORT || '443', 10);
const bindAddr = bindIpArg || process.env.DEEPANTIGRAVITY_BIND_IP || '127.0.0.1';

try {
    const { port: actualPort, caPath } = await startProxy({
        port,
        bindAddr,
        backend,
        upstreamUrl,
        upstreamKey,
        targetModel,
    });
    // Two stdout lines: launcher reads them. Use process.stdout.write
    // (NOT console.log) because Node's console.log adds ANSI color codes
    // around numbers when FORCE_COLOR is set, breaking the launcher's
    // "^[0-9]+$" grep.
    process.stdout.write(String(actualPort) + '\n');
    process.stdout.write(String(caPath) + '\n');
    console.error(`[deepantigravity] proxy ready on ${bindAddr}:${actualPort}`);
    console.error(`[deepantigravity] backend=${backend}  upstream=${upstreamUrl}  model=${targetModel}`);
    console.error(`[deepantigravity] CA: ${caPath}`);
} catch (e) {
    die('proxy failed to start: ' + (e.stack || e.message));
}

function canonicalize(name) {
    switch (name) {
        case 'kimi':                  return 'kimi';
        case 'nv': case 'nvidia':     return 'nvidia';
        default:                      return name;
    }
}
