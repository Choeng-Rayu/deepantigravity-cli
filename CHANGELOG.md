# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Kimi Code backend support (`-b kimi`)
- Nvidia NIM backend support (`-b nv`)
- Automatic `/etc/hosts` management (add on launch, remove on exit)
- Local CA + leaf cert generation for TLS interception
- Gemini ↔ Anthropic API translation with streaming
- Anthropic ↔ OpenAI API translation for Nvidia
- One-time `--setup` for passwordless daily use
- `--teardown` to cleanly uninstall
- `--status` to check setup and running state
- Single-session lock with PID file
- Debug mode (`DEEPANTIGRAVITY_DEBUG=1`)
- Windows support via `deepantigravity.ps1`

### Security
- Helper script restricted to add/remove hosts entry only
- Sudoers rule locked to specific helper commands
- CA key stored with mode 0600
- Only `cloudcode-pa.googleapis.com` traffic redirected
