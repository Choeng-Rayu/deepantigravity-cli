/**
 * cert.js
 * =======
 * Generates a local CA and a leaf certificate for `cloudcode-pa.googleapis.com`,
 * `daily-cloudcode-pa.googleapis.com`, `localhost`, and 127.0.0.1.
 *
 * Why we need this:
 *   `agy` (Antigravity CLI) is a Go binary that connects to
 *   https://cloudcode-pa.googleapis.com over TLS. It has no documented
 *   way to override that endpoint. To redirect traffic to our local
 *   proxy, we run an HTTPS-MITM server, route `agy` through it via
 *   HTTPS_PROXY=http://127.0.0.1:PORT, and present a leaf cert signed
 *   by a CA that `agy`'s Go HTTP client trusts via SSL_CERT_FILE.
 *
 * Output: a single PEM bundle at <cacheDir>/ca.pem (CA only, what we
 * pass to SSL_CERT_FILE) plus an in-memory key+cert per host (what we
 * present to clients during MITM). The CA private key never leaves
 * memory unless --persist is set.
 *
 * Implementation: uses `node-forge` (pure JS, no native deps).
 */

import { existsSync, readFileSync, writeFileSync, mkdirSync, chmodSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);

let forge;
try {
    forge = require('node-forge');
} catch (e) {
    // node-forge isn't required for the proxy to *parse* this file —
    // it's only required at certificate generation time. We let
    // installation surface a friendlier error.
    forge = null;
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Default cache directory under the proxy folder. */
const DEFAULT_CACHE_DIR = join(__dirname, '.cache');

const CA_SUBJECT = [
    { name: 'commonName',          value: 'deepantigravity Local Root CA' },
    { name: 'organizationName',    value: 'deepantigravity' },
    { name: 'organizationalUnitName', value: 'agy interception' },
    { name: 'countryName',         value: 'US' },
];

const CA_VALIDITY_YEARS = 10;
const LEAF_VALIDITY_DAYS = 365;

const DEFAULT_HOSTS = [
    'cloudcode-pa.googleapis.com',
    'daily-cloudcode-pa.googleapis.com',
    'localhost',
];

/**
 * Ensure the CA exists at the given path. If not, generate one.
 * Returns { caPemPath, caCertPem, caKeyPem, ca }.
 */
export function ensureCA(cacheDir = DEFAULT_CACHE_DIR) {
    if (!forge) {
        throw new Error(
            'node-forge is required for HTTPS interception. Install with: ' +
            '  cd proxy && npm install node-forge'
        );
    }

    if (!existsSync(cacheDir)) {
        mkdirSync(cacheDir, { recursive: true });
    }

    const caCertPath = join(cacheDir, 'ca.pem');
    const caKeyPath  = join(cacheDir, 'ca-key.pem');

    if (existsSync(caCertPath) && existsSync(caKeyPath)) {
        const caCertPem = readFileSync(caCertPath, 'utf8');
        const caKeyPem  = readFileSync(caKeyPath,  'utf8');
        return {
            caPemPath: caCertPath,
            caCertPem,
            caKeyPem,
            ca: {
                cert: forge.pki.certificateFromPem(caCertPem),
                key:  forge.pki.privateKeyFromPem(caKeyPem),
            },
        };
    }

    // Generate new CA
    const keys = forge.pki.rsa.generateKeyPair(2048);
    const cert = forge.pki.createCertificate();
    cert.publicKey = keys.publicKey;
    cert.serialNumber = randomSerial();
    cert.validity.notBefore = new Date();
    cert.validity.notAfter  = new Date();
    cert.validity.notAfter.setFullYear(
        cert.validity.notBefore.getFullYear() + CA_VALIDITY_YEARS
    );
    cert.setSubject(CA_SUBJECT);
    cert.setIssuer(CA_SUBJECT);
    cert.setExtensions([
        { name: 'basicConstraints',     cA: true, critical: true },
        { name: 'keyUsage',             keyCertSign: true, cRLSign: true, critical: true },
        { name: 'subjectKeyIdentifier' },
    ]);
    cert.sign(keys.privateKey, forge.md.sha256.create());

    const caCertPem = forge.pki.certificateToPem(cert);
    const caKeyPem  = forge.pki.privateKeyToPem(keys.privateKey);

    writeFileSync(caCertPath, caCertPem);
    writeFileSync(caKeyPath,  caKeyPem);
    chmodSync(caKeyPath, 0o600);

    return {
        caPemPath: caCertPath,
        caCertPem,
        caKeyPem,
        ca: { cert, key: keys.privateKey },
    };
}

/**
 * Generate a leaf certificate signed by the given CA, valid for the
 * specified hostnames. Returns { keyPem, certPem }.
 *
 * Caches per-host so we don't regenerate on every connection.
 */
const _leafCache = new Map();

export function makeLeafCert(ca, hosts = DEFAULT_HOSTS) {
    if (!forge) {
        throw new Error('node-forge is required to mint leaf certificates.');
    }

    const cacheKey = [...hosts].sort().join('|');
    const hit = _leafCache.get(cacheKey);
    if (hit) return hit;

    const keys = forge.pki.rsa.generateKeyPair(2048);
    const cert = forge.pki.createCertificate();
    cert.publicKey = keys.publicKey;
    cert.serialNumber = randomSerial();
    cert.validity.notBefore = new Date();
    cert.validity.notAfter  = new Date();
    cert.validity.notAfter.setDate(
        cert.validity.notBefore.getDate() + LEAF_VALIDITY_DAYS
    );

    cert.setSubject([{ name: 'commonName', value: hosts[0] }]);
    cert.setIssuer(ca.cert.subject.attributes);

    const altNames = hosts.map(h => {
        // Type 2 = DNS, Type 7 = IP
        if (/^[\d.]+$/.test(h) || h.includes(':')) {
            return { type: 7, ip: h };
        }
        return { type: 2, value: h };
    });

    cert.setExtensions([
        { name: 'basicConstraints',     cA: false },
        { name: 'keyUsage',             digitalSignature: true, keyEncipherment: true, critical: true },
        { name: 'extKeyUsage',          serverAuth: true, clientAuth: true },
        { name: 'subjectAltName',       altNames },
        { name: 'subjectKeyIdentifier' },
    ]);

    cert.sign(ca.key, forge.md.sha256.create());

    const result = {
        keyPem:  forge.pki.privateKeyToPem(keys.privateKey),
        certPem: forge.pki.certificateToPem(cert),
    };
    _leafCache.set(cacheKey, result);
    return result;
}

/**
 * Mint a leaf cert for a single hostname (the common case during MITM,
 * where the SNI tells us what cert to present). Caches per-host.
 */
export function makeLeafCertForHost(ca, host) {
    return makeLeafCert(ca, [host]);
}

function randomSerial() {
    // 16 hex chars; node-forge expects a hex string for serialNumber
    const buf = Buffer.allocUnsafe(8);
    for (let i = 0; i < 8; i++) buf[i] = Math.floor(Math.random() * 256);
    // Strip the leading bit to make sure it stays positive when parsed
    buf[0] &= 0x7f;
    return buf.toString('hex');
}

// CLI entrypoint: `node cert.js` regenerates the CA and prints the path.
if (process.argv[1] === __filename) {
    try {
        const { caPemPath } = ensureCA();
        // Use process.stdout.write to avoid color codes when FORCE_COLOR is set
        process.stdout.write(caPemPath + '\n');
    } catch (e) {
        console.error('cert.js: ' + e.message);
        process.exit(1);
    }
}
