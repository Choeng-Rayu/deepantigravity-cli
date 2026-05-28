# Troubleshooting

## Quick diagnosis

```bash
./deepantigravity.sh --status
```

This shows whether setup is complete and if a session is running.

---

## Common issues

### agy returns real Gemini answers (proxy not intercepting)

**Cause:** Setup incomplete or session not running.

```bash
./deepantigravity.sh --status     # look for ✗ marks
./deepantigravity.sh --setup      # fix missing components
```

### `agy` alone gives "connection refused"

**Cause:** Previous session crashed without removing `/etc/hosts` entry.

```bash
./deepantigravity.sh --teardown
agy                                # works again
```

### x509: certificate signed by unknown authority

**Cause:** CA bundle missing or stale.

```bash
./deepantigravity.sh --setup      # rebuilds CA + bundle
```

### EACCES: permission denied, bind port 443

**Cause:** Node lost `CAP_NET_BIND_SERVICE`.

```bash
./deepantigravity.sh --setup      # re-grants capability
```

### "another deepantigravity session is already running"

**Cause:** Only one session can run at a time.

```bash
./deepantigravity.sh --status     # shows PID of running session
kill <PID>                         # or Ctrl-C in its terminal
```

### agy hangs with no output

**Cause:** Backend rejected the request (bad API key, rate limit, etc.)

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi -- --print "test"
# Look for "upstream replied: 4XX" in output
```

### Proxy starts but agy still uses Gemini

**Cause:** `/etc/hosts` entry not added. Check helper permissions:

```bash
ls -la /usr/local/bin/deepantigravity-helper
cat /etc/sudoers.d/deepantigravity
```

Re-run `--setup` if either is missing.

---

## Debug mode

```bash
DEEPANTIGRAVITY_DEBUG=1 ./deepantigravity.sh -b kimi
```

Logs all request/response bodies to:
- `proxy/.cache/requests/` — what agy sent
- `proxy/.cache/responses/` — what we sent back

---

## Nuclear reset

If everything is broken:

```bash
./deepantigravity.sh --teardown
rm -rf proxy/.cache
./deepantigravity.sh --setup
```
