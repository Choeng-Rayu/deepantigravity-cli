# DeepSeek OAuth Testing Guide

This document outlines the capabilities and testing procedures for integrating DeepSeek's API with OAuth authentication in the `deepantigravity-cli` project.

## Overview

DeepSeek provides OAuth-based authentication for accessing its language model APIs. This test file serves as a reference for:
- Validating OAuth token acquisition and refresh flows
- Testing authenticated API requests to DeepSeek endpoints
- Troubleshooting common authentication errors

## Prerequisites

- DeepSeek developer account with API credentials
- OAuth client ID and client secret
- Redirect URI configured in DeepSeek developer dashboard
- `curl`, `httpie`, or Python for manual tests

## OAuth Flow Capabilities

### 1. Authorization Code Grant
```bash
# Step 1: Redirect user to authorization endpoint
https://api.deepseek.com/v1/oauth/authorize?
  response_type=code&
  client_id=YOUR_CLIENT_ID&
  redirect_uri=YOUR_REDIRECT_URI&
  scope=openid offline_access

# Step 2: Exchange code for tokens
POST /v1/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&
code=AUTH_CODE&
client_id=YOUR_CLIENT_ID&
client_secret=YOUR_CLIENT_SECRET&
redirect_uri=YOUR_REDIRECT_URI
```

### 2. Token Refresh
```bash
POST /v1/oauth/token

grant_type=refresh_token&
refresh_token=YOUR_REFRESH_TOKEN&
client_id=YOUR_CLIENT_ID&
client_secret=YOUR_CLIENT_SECRET
```

### 3. Authenticated API Call
```bash
curl -X POST https://api.deepseek.com/v1/chat/completions \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-coder",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## What You Can Test in This File

- **Token lifecycle**: Obtain, use, refresh, and revoke tokens
- **Scope validation**: Request minimal scopes (`openid`, `profile`, `offline_access`)
- **Error handling**: Simulate expired tokens, invalid grants, and network failures
- **Rate limiting**: Observe headers and implement backoff strategies
- **PKCE flow** (if applicable): Use code verifier/challenge for public clients
- **Client credentials flow** (server-to-server): Direct token acquisition without user interaction

## Example Python Test Script

```python
import requests
import time

class DeepSeekOAuthTester:
    def __init__(self, client_id, client_secret, redirect_uri):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.token_url = "https://api.deepseek.com/v1/oauth/token"
        self.api_url = "https://api.deepseek.com/v1/chat/completions"

    def get_tokens_from_code(self, auth_code):
        data = {
            "grant_type": "authorization_code",
            "code": auth_code,
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "redirect_uri": self.redirect_uri
        }
        resp = requests.post(self.token_url, data=data)
        resp.raise_for_status()
        return resp.json()

    def refresh_access_token(self, refresh_token):
        data = {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": self.client_id,
            "client_secret": self.client_secret
        }
        resp = requests.post(self.token_url, data=data)
        resp.raise_for_status()
        return resp.json()

    def call_api(self, access_token, prompt):
        headers = {"Authorization": f"Bearer {access_token}"}
        payload = {
            "model": "deepseek-coder",
            "messages": [{"role": "user", "content": prompt}]
        }
        resp = requests.post(self.api_url, json=payload, headers=headers)
        resp.raise_for_status()
        return resp.json()

# Usage example
if __name__ == "__main__":
    tester = DeepSeekOAuthTester(
        client_id="YOUR_CLIENT_ID",
        client_secret="YOUR_CLIENT_SECRET",
        redirect_uri="http://localhost:8080/callback"
    )
    # tokens = tester.get_tokens_from_code("authorization_code")
    # print(tester.call_api(tokens["access_token"], "Write a recursive factorial in Python"))
```

## Common Test Scenarios

| Scenario | Expected Behavior | Verification |
|----------|------------------|--------------|
| Missing authorization header | HTTP 401 Unauthorized | Check error message |
| Expired access token | HTTP 401 + `invalid_token` | Attempt refresh |
| Invalid client credentials | HTTP 401 | Verify secret encoding |
| Malformed redirect URI | HTTP 400 | Match exact registered URI |
| Missing `offline_access` scope | No refresh token in response | Add scope parameter |

## Debugging Tools

- **JWT debugger**: Decode access token (if JWT) to inspect claims
- **OAuth 2.0 Playground**: Validate flow with DeepSeek endpoints
- **Local log capture**: Save request/response traces for audit

## Next Steps

After successful OAuth testing, integrate the flow into `deepantigravity-cli`:
- Store tokens securely (OS keyring, encrypted config)
- Implement automatic token refresh before expiry
- Add `--auth` flag to CLI commands
- Provide `deepseek auth login` / `logout` subcommands

---

*Last updated: 2026-05-30*
