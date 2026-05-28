# deepantigravity.ps1 — Use Google's Antigravity CLI (`agy`) with cheap LLM backends
#
# DESIGN GOAL (Windows mirror of deepantigravity.sh):
#   When this launcher is NOT running, `agy` works completely normally
#   (real Google Gemini). When it IS running, `agy` is transparently
#   routed through our local proxy to a different backend.
#
# KEY DIFFERENCE FROM LINUX:
#   Windows has no setcap and no clean passwordless-sudo equivalent.
#   So each launch DOES require Administrator (the script auto-elevates).
#   The hosts-file edit happens at launch and is reverted on exit, so
#   plain `agy` still works correctly when this launcher isn't running.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('b')][string]$Backend,
    [switch]$Setup,
    [switch]$Teardown,
    [switch]$Status,
    [switch]$Cost,
    [switch]$CaPath,
    [switch]$InstallCa,
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgyArgs
)

$ErrorActionPreference = 'Stop'

# ── Resolve symlinks ──
$_scriptPath = $MyInvocation.MyCommand.Path
while ($_scriptPath) {
    $_item = Get-Item -LiteralPath $_scriptPath -ErrorAction SilentlyContinue
    if (-not $_item -or $_item.LinkType -ne 'SymbolicLink') { break }
    $_target = $_item.Target
    if ($_target -is [array]) { $_target = $_target[0] }
    if (-not [System.IO.Path]::IsPathRooted($_target)) {
        $_target = Join-Path (Split-Path -Parent $_scriptPath) $_target
    }
    $_scriptPath = $_target
}
$ScriptDir = Split-Path -Parent $_scriptPath
Remove-Variable _scriptPath, _item, _target -ErrorAction SilentlyContinue

# ── Load .env ──
$EnvFile = Join-Path $ScriptDir 'proxy\.env'
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $line = ($line -split '#', 2)[0].Trim()
        if ($line -eq '') { return }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { return }
        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1).Trim()
        if (-not [Environment]::GetEnvironmentVariable($k)) {
            [Environment]::SetEnvironmentVariable($k, $v)
        }
    }
}

# ── Defaults ──
$DeepantigravityPort = if ($env:DEEPANTIGRAVITY_PORT) { $env:DEEPANTIGRAVITY_PORT } else { '443' }
$DefaultBackend = if ($env:API_PROVIDER) { $env:API_PROVIDER } else { 'kimi' }
if (-not $Backend) { $Backend = $DefaultBackend }

$HostsFile          = "$env:WINDIR\System32\drivers\etc\hosts"
$HostsSentinelBegin = '# >>> deepantigravity BEGIN <<<'
$HostsSentinelEnd   = '# >>> deepantigravity END <<<'
$HijackedHosts      = @('cloudcode-pa.googleapis.com', 'daily-cloudcode-pa.googleapis.com')

$script:HostsHijackedByUs = $false

# ── Helpers ──
function Convert-Backend([string]$name) {
    switch ($name) {
        'nv'         { 'nvidia' }
        'nvidia'     { 'nvidia' }
        'kimi'       { 'kimi' }
        default      { $name }
    }
}

function Hide-Key($v) {
    if (-not $v) { return 'MISSING' }
    return "set (****$($v.Substring([Math]::Max(0, $v.Length - 4))))"
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HostsHijacked {
    if (-not (Test-Path $HostsFile)) { return $false }
    Select-String -Path $HostsFile -Pattern ([regex]::Escape($HostsSentinelBegin)) -Quiet
}

function Add-HostsHijack {
    if (Test-HostsHijacked) {
        $script:HostsHijackedByUs = $true   # treat stale entries as ours so we clean up
        return
    }
    $block  = "`r`n" + $HostsSentinelBegin + "`r`n"
    foreach ($h in $HijackedHosts) { $block += "127.0.0.1 $h`r`n" }
    $block += $HostsSentinelEnd + "`r`n"
    Add-Content -Path $HostsFile -Value $block -Encoding ASCII
    $script:HostsHijackedByUs = $true
}

function Remove-HostsHijack {
    if (-not (Test-HostsHijacked)) { return }
    $content = Get-Content $HostsFile -Raw
    $pattern = [regex]::Escape($HostsSentinelBegin) + '[\s\S]*?' + [regex]::Escape($HostsSentinelEnd) + '\r?\n?'
    $clean = [regex]::Replace($content, $pattern, '')
    # Drop trailing blank lines
    $clean = $clean -replace '(\r?\n)+\Z', "`r`n"
    Set-Content -Path $HostsFile -Value $clean -Encoding ASCII -NoNewline
}

function Show-Help {
@"
deepantigravity — Use ``agy`` (Antigravity CLI) with Kimi or Nvidia NIM

USAGE
  .\deepantigravity.ps1 -Setup                     one-time, requires admin
  .\deepantigravity.ps1 [-b BACKEND] [agy-args]    each run requires admin (Windows)
  .\deepantigravity.ps1 -Teardown                  requires admin
  .\deepantigravity.ps1 -Status

To use real Google Gemini just run ``agy`` directly — deepantigravity adds
the hosts-file redirect only WHILE running, and removes it on exit.

BACKENDS
  -Backend kimi                   Kimi Code             (Anthropic-native upstream)
  -Backend nv | nvidia            Nvidia NIM            (OpenAI-compat upstream)

PREREQUISITES
  * agy (Antigravity CLI)              https://antigravity.google/download
  * Node.js >= 18 and npm
  * Administrator (each run, since Windows binds :443 + edits hosts file)

CONFIG
  Edit proxy\.env. Set API_PROVIDER and at least one of KIMI_API_KEY,
  NVIDIA_API_KEY.
"@
}

function Show-Status {
    $agy   = Get-Command agy   -ErrorAction SilentlyContinue
    $node  = Get-Command node  -ErrorAction SilentlyContinue
    $caPemPath = Join-Path $ScriptDir 'proxy\.cache\ca.pem'
    Write-Host ''
    Write-Host '  deepantigravity — Status'
    Write-Host '  ========================'
    Write-Host ''
    Write-Host "  agy:                 $(if ($agy) { $agy.Source } else { 'NOT FOUND' })"
    Write-Host "  node:                $(if ($node) { $node.Source } else { 'NOT FOUND' })"
    Write-Host "  CA cert:             $(if (Test-Path $caPemPath) { '✓ ' + $caPemPath } else { '✗ not yet generated (run -Setup)' })"
    Write-Host ''
    Write-Host '  Live state:'
    Write-Host "    hosts file:        $(if (Test-HostsHijacked) { 'PRESENT (a session is in progress, OR cleanup failed)' } else { 'absent (correct — agy alone uses real Google)' })"
    Write-Host ''
    Write-Host '  Keys:'
    Write-Host "    KIMI_API_KEY:      $(Hide-Key $env:KIMI_API_KEY)"
    Write-Host "    NVIDIA_API_KEY:    $(Hide-Key $env:NVIDIA_API_KEY)"
    Write-Host ''
    Write-Host "  Default backend:    $DefaultBackend"
    Write-Host "  Proxy port:         $DeepantigravityPort"
    Write-Host ''
}

function Show-Cost {
@"

  deepantigravity Provider Pricing
  =================================

  Provider        Input/M    Output/M   Notes
  ----------      --------   --------   -----------
  Kimi Code       subscription          Anthropic-native, kimi-for-coding
  Nvidia NIM      `$0.44      `$0.87      OpenAI-compat (default kimi-k2.6)

"@
}

function Get-CaPath {
    $ca = Join-Path $ScriptDir 'proxy\.cache\ca.pem'
    if (-not (Test-Path $ca)) {
        Write-Host "Generating CA..."
        Push-Location (Join-Path $ScriptDir 'proxy')
        try {
            if (-not (Test-Path 'node_modules\node-forge')) {
                & npm install --silent --no-audit --no-fund | Out-Null
            }
            & node 'cert.js' | Out-Null
        } finally { Pop-Location }
    }
    return $ca
}

function Show-InstallCa {
    $ca = Get-CaPath
@"

  How to install the deepantigravity CA into Windows trust store
  ===============================================================

  Note: deepantigravity does NOT need this for agy to work — agy honors
        SSL_CERT_FILE, which the launcher sets to our CA.

  Run as Administrator:
     Import-Certificate -FilePath '$ca' \``
       -CertStoreLocation Cert:\LocalMachine\Root

"@
}

function Resolve-Backend {
    $b = Convert-Backend $Backend
    switch ($b) {
        'kimi'       { if (-not $env:KIMI_API_KEY -or $env:KIMI_API_KEY.StartsWith('sk-your'))      { throw 'KIMI_API_KEY not set in proxy/.env' } }
        'nvidia'     { if (-not $env:NVIDIA_API_KEY -or $env:NVIDIA_API_KEY.StartsWith('nvapi-your')){ throw 'NVIDIA_API_KEY not set in proxy/.env' } }
        default      { throw "Unknown backend: $b (only kimi and nvidia are supported)" }
    }
    return $b
}

function Ensure-NodeModules {
    $nm = Join-Path $ScriptDir 'proxy\node_modules\node-forge'
    if (-not (Test-Path $nm)) {
        Write-Host "  First-run setup: installing proxy dependencies..."
        Push-Location (Join-Path $ScriptDir 'proxy')
        try {
            & npm install --silent --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
        } finally { Pop-Location }
    }
}

function Do-Setup {
    if (-not (Test-Admin)) {
        Write-Host "  -Setup needs Administrator. Re-launching elevated..."
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Setup')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs -Wait
        return
    }
    Write-Host ''
    Write-Host '  deepantigravity — one-time setup (Windows)'
    Write-Host '  =========================================='
    Write-Host '  Setup just regenerates the CA. Each launch needs admin'
    Write-Host '  on Windows because we modify the hosts file and bind :443.'
    Write-Host ''
    Ensure-NodeModules
    & node (Join-Path $ScriptDir 'proxy\cert.js') | Out-Null
    Write-Host ''
    Write-Host '  ✓ Setup complete. Launch with admin PowerShell:'
    Write-Host '      .\deepantigravity.ps1 -Backend kiro'
    Write-Host ''
}

function Do-Teardown {
    if (-not (Test-Admin)) {
        Write-Host "  -Teardown needs Administrator. Re-launching elevated..."
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Teardown')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs -Wait
        return
    }
    Remove-HostsHijack
    Write-Host '  ✓ /etc/hosts (hosts file) cleaned. agy is back to normal.'
}

$ProxyProcess = $null
function Cleanup-OnExit {
    if ($script:ProxyProcess -and -not $script:ProxyProcess.HasExited) {
        Stop-Process -Id $script:ProxyProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($script:HostsHijackedByUs) {
        if (Test-Admin) {
            try { Remove-HostsHijack } catch {}
        } else {
            Write-Warning "Cannot remove hosts entries without admin. Run -Teardown later."
        }
    }
}

function Launch-Agy {
    if (-not (Test-Admin)) {
        throw "Each launch needs Administrator on Windows. Open an elevated PowerShell, then re-run."
    }

    $resolved = Resolve-Backend
    Ensure-NodeModules

    Write-Host "  Adding hosts file redirect for cloudcode-pa.googleapis.com..."
    Add-HostsHijack

    Write-Host "  Starting deepantigravity TLS server → $resolved ..."

    $stale = Get-NetTCPConnection -LocalPort $DeepantigravityPort -State Listen -ErrorAction SilentlyContinue
    if ($stale) {
        $stale | ForEach-Object {
            try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()

    $script:ProxyProcess = Start-Process -FilePath 'node' `
        -ArgumentList @((Join-Path $ScriptDir 'proxy\start-proxy.js'), $resolved, $DeepantigravityPort) `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

    $port = $null; $caPath = $null
    $tries = 0
    while ($tries -lt 60) {
        if (Test-Path $stdoutFile) {
            $lines = Get-Content $stdoutFile -ErrorAction SilentlyContinue
            $port  = $lines | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
            $caPath = $lines | Where-Object { $_ -match '^[A-Z]:|^/' } | Select-Object -First 1
            if ($port -and $caPath -and (Test-Path $caPath)) { break }
        }
        if ($script:ProxyProcess.HasExited) {
            Write-Host "ERROR: proxy died on startup" -ForegroundColor Red
            if (Test-Path $stderrFile) { Get-Content $stderrFile | Write-Host -ForegroundColor DarkGray }
            Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
            throw "proxy failed"
        }
        Start-Sleep -Milliseconds 100
        $tries++
    }
    if (-not $port -or -not $caPath -or -not (Test-Path $caPath)) {
        if (Test-Path $stderrFile) { Get-Content $stderrFile | Write-Host -ForegroundColor DarkGray }
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        throw "proxy startup output unexpected"
    }

    Write-Host "  TLS server on 127.0.0.1:$port  → $resolved"
    Write-Host "  CA: $caPath"
    Write-Host ''
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

    # Build a combined trust bundle: our CA + system roots.
    # Go's SSL_CERT_FILE REPLACES the system trust pool — pointing agy
    # at our CA alone makes non-cloudcode-pa traffic (oauth2 userinfo,
    # accounts.google.com, etc.) fail with "certificate signed by unknown
    # authority". On Windows there is no canonical PEM trust file, so we
    # export the LocalMachine\Root store on the fly.
    $bundlePath = Join-Path (Split-Path -Parent $caPath) 'ca-bundle.pem'
    try {
        $sb = [System.Text.StringBuilder]::new()
        # Our CA first (so it takes precedence for cloudcode-pa.googleapis.com)
        $sb.AppendLine((Get-Content $caPath -Raw)) | Out-Null
        # Append every cert from the user+machine Root stores
        foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\LocalMachine\Root')) {
            try {
                Get-ChildItem $store | ForEach-Object {
                    $bytes = $_.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
                    $b64 = [Convert]::ToBase64String($bytes, 'InsertLineBreaks')
                    $sb.AppendLine("-----BEGIN CERTIFICATE-----") | Out-Null
                    $sb.AppendLine($b64) | Out-Null
                    $sb.AppendLine("-----END CERTIFICATE-----") | Out-Null
                }
            } catch { }
        }
        Set-Content -Path $bundlePath -Value $sb.ToString() -Encoding ASCII -NoNewline
    } catch {
        # Fall back to our CA alone
        Copy-Item $caPath $bundlePath -Force
        Write-Warning "Could not build combined trust bundle; non-Google TLS may fail."
    }

    $env:SSL_CERT_FILE = $bundlePath
    $env:SSL_CERT_DIR  = (Split-Path -Parent $bundlePath)

    & agy @AgyArgs
}

# ── Main ──
try {
    if ($Help)        { Show-Help; return }
    if ($Setup)       { Do-Setup; return }
    if ($Teardown)    { Do-Teardown; return }
    if ($Status)      { Show-Status; return }
    if ($Cost)        { Show-Cost; return }
    if ($CaPath)      { Get-CaPath; return }
    if ($InstallCa)   { Show-InstallCa; return }
    Launch-Agy
} finally {
    Cleanup-OnExit
}
