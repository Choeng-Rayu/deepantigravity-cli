# deepantigravity.ps1 — Use Google's Antigravity CLI (`agy`) with cheap LLM backends
#
# DESIGN GOAL (Windows mirror of deepantigravity.sh):
#   When this launcher is NOT running, `agy` works completely normally
#   (real Google Gemini). When it IS running, `agy` is transparently
#   routed through our local proxy to a different backend.
#
# KEY DIFFERENCES FROM LINUX:
#   * Windows has no setcap, no passwordless-sudo, and no mount namespace
#     (bwrap) equivalent that's available unprivileged. So:
#       - LEADER (first terminal of a backend): needs Administrator to
#         bind :443 and to modify the Windows hosts file. Auto-elevates.
#       - FOLLOWERS (additional terminals using the SAME backend):
#         do NOT need Administrator. They just attach to the existing
#         proxy and run `agy` as a regular user.
#   * Multiple terminals with the SAME backend share one proxy
#     (refcounted, last out tears down).
#   * Different backends in parallel are NOT supported on Windows
#     because there is no per-process hosts-file equivalent without
#     WSL2 or kernel-level DNS hooks. The launcher refuses cleanly.
#   * The proxy is launched detached so it survives the leader's exit.
#     Followers can use it until the last terminal exits.

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
    [switch]$DebugProxy,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgyArgs
)

$ErrorActionPreference = 'Stop'

# Carry DEEPANTIGRAVITY_DEBUG across UAC elevation. The elevated instance
# starts with a fresh environment (the runtime $env: var is lost), so the
# leader forwards -DebugProxy and we re-set it here. The spawned proxy then
# inherits it (parity with deepantigravity.sh, which forwards DEBUG too).
if ($DebugProxy) { $env:DEEPANTIGRAVITY_DEBUG = '1' }

# ── Resolve symlinks so $ScriptDir always points at the real repo ──
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

# ── Load proxy/.env ──
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

# ── Defaults & paths ──
$DeepantigravityPort = if ($env:DEEPANTIGRAVITY_PORT) { $env:DEEPANTIGRAVITY_PORT } else { '443' }
$DefaultBackend      = if ($env:API_PROVIDER) { $env:API_PROVIDER } else { 'kimi' }
if (-not $Backend) { $Backend = $DefaultBackend }

$HostsFile          = "$env:WINDIR\System32\drivers\etc\hosts"
$HostsSentinelBegin = '# >>> deepantigravity BEGIN <<<'
$HostsSentinelEnd   = '# >>> deepantigravity END <<<'
$HijackedHosts      = @('cloudcode-pa.googleapis.com', 'daily-cloudcode-pa.googleapis.com')

# Session state — mirrors deepantigravity.sh's proxy/.cache/session/.
$SessionDir         = Join-Path $ScriptDir 'proxy\.cache\session'
$SessionLockFile    = Join-Path $SessionDir 'lock'
$SessionPidFile     = Join-Path $SessionDir 'proxy.pid'
$SessionBackendFile = Join-Path $SessionDir 'backend'
$SessionBundleFile  = Join-Path $SessionDir 'ca-bundle.pem'
$SessionLogFile     = Join-Path $SessionDir 'proxy.log'
$SessionMembersDir  = Join-Path $SessionDir 'members'
$GlobalMutexName    = 'Global\deepantigravity-session'   # cross-process lock

$script:JoinedSession = $false   # 1 if this PID is registered as a session member

# ── Helpers ──
function Convert-Backend([string]$name) {
    switch ($name) {
        'nv'         { 'nvidia' }
        'nvidia'     { 'nvidia' }
        'kimi'       { 'kimi' }
        'ds'         { 'deepseekOauthWeb' }
        'deepseek'   { 'deepseekOauthWeb' }
        'deepseekOauthWeb' { 'deepseekOauthWeb' }
        default      { $name }
    }
}

function Hide-Key($v) {
    if (-not $v) { return 'MISSING' }
    return "set (****$($v.Substring([Math]::Max(0, $v.Length - 4))))"
}

function Test-Admin {
    # On non-Windows hosts (e.g. PowerShell Core on Linux), the
    # WindowsPrincipal API throws. Treat that as "not admin" so the
    # script can still display status / help without failing.
    if ((Get-Variable IsLinux -ErrorAction SilentlyContinue) -and ($IsLinux -or $IsMacOS)) {
        # Linux/macOS proxy of "is admin" — true iff EUID == 0.
        try { return ((id -u 2>/dev/null) -eq '0') } catch { return $false }
    }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-PidAlive([int]$proc_id) {
    if ($proc_id -le 0) { return $false }
    try {
        $null = Get-Process -Id $proc_id -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-HostsHijacked {
    if (-not (Test-Path $HostsFile)) { return $false }
    Select-String -Path $HostsFile -Pattern ([regex]::Escape($HostsSentinelBegin)) -Quiet
}

function Add-HostsHijack {
    if (Test-HostsHijacked) { return }
    $block  = "`r`n" + $HostsSentinelBegin + "`r`n"
    foreach ($h in $HijackedHosts) { $block += "127.0.0.1 $h`r`n" }
    $block += $HostsSentinelEnd + "`r`n"
    Add-Content -Path $HostsFile -Value $block -Encoding ASCII
}

function Remove-HostsHijack {
    if (-not (Test-HostsHijacked)) { return }
    $content = Get-Content $HostsFile -Raw
    $pattern = [regex]::Escape($HostsSentinelBegin) + '[\s\S]*?' + [regex]::Escape($HostsSentinelEnd) + '\r?\n?'
    $clean   = [regex]::Replace($content, $pattern, '')
    $clean   = $clean -replace '(\r?\n)+\Z', "`r`n"
    Set-Content -Path $HostsFile -Value $clean -Encoding ASCII -NoNewline
}

# Returns the count of alive members and garbage-collects dead PID files.
function Get-SessionActiveMemberCount {
    if (-not (Test-Path $SessionMembersDir)) { return 0 }
    $count = 0
    Get-ChildItem -Path $SessionMembersDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        $mpid = 0
        if ([int]::TryParse($_.Name, [ref]$mpid) -and (Test-PidAlive $mpid)) {
            $count++
        } else {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $count
}

# Resolve the real Google IP for a host BEFORE hijacking the hosts file.
# `Resolve-DnsName -DnsOnly` queries DNS directly and bypasses the local
# hosts file, so we get the upstream address instead of 127.0.0.1.
function Get-RealIp([string]$host_name) {
    try {
        $r = Resolve-DnsName -Name $host_name -Type A -DnsOnly -ErrorAction Stop |
             Where-Object { $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' } |
             Select-Object -First 1
        if ($r) { return $r.IPAddress }
    } catch { }
    return $null
}

# Atomic critical section using a NAMED MUTEX. PowerShell scripts run in
# separate processes; a named mutex (Global\...) is the cleanest way to
# serialise "join existing session OR start a new one" across launches.
function Invoke-WithSessionLock {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutSec = 10)
    $mutex = $null
    $owned = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $GlobalMutexName)
        try {
            $owned = $mutex.WaitOne($TimeoutSec * 1000, $false)
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder died without releasing — we own it now.
            $owned = $true
        }
        if (-not $owned) {
            throw "could not acquire deepantigravity session lock within ${TimeoutSec}s"
        }
        & $Body
    } finally {
        if ($mutex) {
            if ($owned) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Show-Help {
@"
deepantigravity — Use ``agy`` (Antigravity CLI) with cheap LLM backends

USAGE
  .\deepantigravity.ps1 -Setup                     one-time, requires admin
  .\deepantigravity.ps1 [-b BACKEND] [agy-args]    leader needs admin (1st terminal)
  .\deepantigravity.ps1 -Teardown                  requires admin
  .\deepantigravity.ps1 -Status

To use real Google Gemini just run ``agy`` directly — deepantigravity adds
the hosts-file redirect only WHILE running, and removes it on exit.

BACKENDS
  -Backend kimi                     Kimi Code                (Anthropic-native upstream)
  -Backend ds | deepseek            DeepSeek Web OAuth       (chat.deepseek.com web — emulated tools)
  -Backend nv | nvidia              Nvidia NIM               (OpenAI-compat upstream)

CONCURRENT SESSIONS
  * Multiple terminals using the SAME backend share one proxy (refcounted).
    Only the FIRST terminal needs Administrator; the rest run as regular user.
  * DIFFERENT backends in parallel are NOT supported on Windows because
    there is no per-process hosts-file equivalent without WSL2.

PREREQUISITES
  * agy (Antigravity CLI)              https://antigravity.google/download
  * Node.js >= 18 and npm
  * Administrator (first launch only — to bind :443 and edit hosts file)

CONFIG
  Edit proxy\.env. Set API_PROVIDER and at least one of KIMI_API_KEY,
  DEEPSEEK_OAUTH_WEB_TOKEN, or NVIDIA_API_KEY.
  DeepSeek web also needs DEEPSEEK_OAUTH_WEB_COOKIE (browser cookie with
  ds_session_id + aws-waf-token). Thinking is on by default
  (DEEPSEEK_OAUTH_WEB_THINKING=0 to disable).
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
    Write-Host "  Admin (this proc):   $(if (Test-Admin) { 'YES' } else { 'no (only leader needs admin)' })"
    Write-Host ''
    Write-Host '  Live state:'
    Write-Host "    hosts file:        $(if (Test-HostsHijacked) { 'PRESENT (a session is in progress, OR cleanup failed)' } else { 'absent (correct — agy alone uses real Google)' })"
    if (Test-Path $SessionPidFile) {
        $sessionPid = (Get-Content $SessionPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $sessionBackend = (Get-Content $SessionBackendFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($sessionPid -and (Test-PidAlive ([int]$sessionPid))) {
            $n = Get-SessionActiveMemberCount
            Write-Host "    Shared proxy:      PID $sessionPid (backend: $sessionBackend)"
            Write-Host "    Active sessions:   $n"
        } else {
            Write-Host "    Shared proxy:      none (state is stale, will be cleaned on next launch)"
        }
    } else {
        Write-Host "    Shared proxy:      none"
    }
    Write-Host ''
    Write-Host '  Keys:'
    Write-Host "    KIMI_API_KEY:             $(Hide-Key $env:KIMI_API_KEY)"
    Write-Host "    DEEPSEEK_OAUTH_WEB_TOKEN: $(Hide-Key $env:DEEPSEEK_OAUTH_WEB_TOKEN)"
    Write-Host "    NVIDIA_API_KEY:           $(Hide-Key $env:NVIDIA_API_KEY)"
    Write-Host ''
    Write-Host "  Default backend:    $DefaultBackend"
    Write-Host "  Proxy port:         $DeepantigravityPort"
    Write-Host ''
}

function Show-Cost {
@"

  deepantigravity Provider Pricing
  =================================

  Provider           Input/M    Output/M   Notes
  ----------         --------   --------   -----------
  Kimi Code          subscription          Anthropic-native, kimi-for-coding
  DeepSeek Web OAuth free                 chat.deepseek.com web session, emulated tools, deepseek-v4-pro (1M ctx, thinking)
  Nvidia NIM         `$0.44      `$0.87      OpenAI-compat (default kimi-k2.6)

"@
}

function Get-CaPath {
    $ca = Join-Path $ScriptDir 'proxy\.cache\ca.pem'
    if (-not (Test-Path $ca)) {
        Write-Host 'Generating CA...'
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

  How to install the deepantigravity CA into the Windows trust store
  ===================================================================

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
        'deepseekOauthWeb' { if (-not $env:DEEPSEEK_OAUTH_WEB_TOKEN -or $env:DEEPSEEK_OAUTH_WEB_TOKEN.StartsWith('your-deepseek')) { throw 'DEEPSEEK_OAUTH_WEB_TOKEN not set in proxy/.env' } }
        'nvidia'     { if (-not $env:NVIDIA_API_KEY -or $env:NVIDIA_API_KEY.StartsWith('nvapi-your')){ throw 'NVIDIA_API_KEY not set in proxy/.env' } }
        default      { throw "Unknown backend: $b (only kimi, deepseekOauthWeb, and nvidia are supported)" }
    }
    return $b
}

function Confirm-NodeModules {
    $nm = Join-Path $ScriptDir 'proxy\node_modules\node-forge'
    if (-not (Test-Path $nm)) {
        Write-Host '  First-run setup: installing proxy dependencies...'
        Push-Location (Join-Path $ScriptDir 'proxy')
        try {
            & npm install --silent --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
        } finally { Pop-Location }
    }
}

function Build-CaBundle([string]$caPath, [string]$bundlePath) {
    # Combined trust bundle: our CA + the system trust store. Go's
    # SSL_CERT_FILE REPLACES the system trust pool, so without this any
    # non-cloudcode-pa TLS would fail with "certificate signed by
    # unknown authority". On Windows there's no canonical PEM trust file,
    # so we export the LocalMachine\Root + CurrentUser\Root stores.
    try {
        $sb = [System.Text.StringBuilder]::new()
        $sb.AppendLine((Get-Content $caPath -Raw)) | Out-Null
        foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\LocalMachine\Root')) {
            try {
                Get-ChildItem $store -ErrorAction SilentlyContinue | ForEach-Object {
                    $bytes = $_.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
                    $b64 = [Convert]::ToBase64String($bytes, 'InsertLineBreaks')
                    $sb.AppendLine('-----BEGIN CERTIFICATE-----') | Out-Null
                    $sb.AppendLine($b64) | Out-Null
                    $sb.AppendLine('-----END CERTIFICATE-----') | Out-Null
                }
            } catch { }
        }
        Set-Content -Path $bundlePath -Value $sb.ToString() -Encoding ASCII -NoNewline
    } catch {
        Copy-Item $caPath $bundlePath -Force
        Write-Warning 'Could not build combined trust bundle; non-Google TLS may fail.'
    }
}

function Free-Port([int]$port) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $listeners) { return }
    foreach ($c in $listeners) {
        try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Wait until the kernel releases it (max ~3s).
    $n = 0
    while ((Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) -and $n -lt 30) {
        Start-Sleep -Milliseconds 100
        $n++
    }
}

function Do-Setup {
    if (-not (Test-Admin)) {
        Write-Host '  -Setup needs Administrator. Re-launching elevated...'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Setup')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs -Wait
        return
    }
    Write-Host ''
    Write-Host '  deepantigravity — one-time setup (Windows)'
    Write-Host '  =========================================='
    Write-Host '  Setup just regenerates the CA. Each LEADER launch (first'
    Write-Host '  terminal of a backend) needs admin to bind :443 and modify'
    Write-Host '  the hosts file. Subsequent terminals using the same'
    Write-Host '  backend can run as a regular user.'
    Write-Host ''
    Confirm-NodeModules
    & node (Join-Path $ScriptDir 'proxy\cert.js') | Out-Null

    # Auto-import CA into Windows trust store
    $caPemPath = Join-Path $ScriptDir 'proxy\.cache\ca.pem'
    if (Test-Path $caPemPath) {
        Write-Host '  Importing CA certificate into Windows trust store...'
        try {
            Import-Certificate -FilePath $caPemPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
            Write-Host '  ✓ CA certificate trusted by Windows.'
        } catch {
            Write-Warning 'Could not auto-import CA. Run manually: Import-Certificate -FilePath proxy\.cache\ca.pem -CertStoreLocation Cert:\LocalMachine\Root'
        }
    }

    Write-Host ''
    Write-Host '  ✓ Setup complete. Launch with:'
    Write-Host '      .\deepantigravity.ps1 -b kimi      # leader (admin needed)'
    Write-Host '      .\deepantigravity.ps1 -b kimi      # follower (regular user)'
    Write-Host ''
}

function Do-Teardown {
    if (-not (Test-Admin)) {
        Write-Host '  -Teardown needs Administrator. Re-launching elevated...'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Teardown')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs -Wait
        return
    }
    # Kill any running shared proxy
    if (Test-Path $SessionPidFile) {
        $pp = (Get-Content $SessionPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($pp -and (Test-PidAlive ([int]$pp))) {
            Stop-Process -Id ([int]$pp) -Force -ErrorAction SilentlyContinue
            Write-Host "  Stopped shared proxy (PID $pp)"
        }
    }
    if (Test-Path $SessionDir) {
        Remove-Item $SessionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Free :443 if anything else is bound
    Free-Port ([int]$DeepantigravityPort)
    # Clean hosts file
    Remove-HostsHijack
    Write-Host '  ✓ deepantigravity stopped, hosts file cleaned. agy is back to normal.'
}

# ── Cleanup runs on every exit. Refcount-based teardown like the Linux trap. ──
function Invoke-CleanupOnExit {
    if (-not $script:JoinedSession) { return }
    try {
        Invoke-WithSessionLock -TimeoutSec 5 -Body {
            $myFile = Join-Path $SessionMembersDir "$PID"
            Remove-Item -LiteralPath $myFile -Force -ErrorAction SilentlyContinue

            $active = Get-SessionActiveMemberCount
            if ($active -gt 0) { return }

            # We're the last one out — tear down the shared proxy.
            if (Test-Path $SessionPidFile) {
                $pp = (Get-Content $SessionPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($pp -and (Test-PidAlive ([int]$pp))) {
                    Stop-Process -Id ([int]$pp) -Force -ErrorAction SilentlyContinue
                }
            }
            if (Test-Admin) {
                try { Remove-HostsHijack } catch {}
            } else {
                # Followers can't modify hosts file. Leader (still alive)
                # would have done it normally. If we ARE the last out and
                # not admin, log a warning.
                Write-Warning 'Last-out cleanup: cannot remove hosts entries without admin. Run -Teardown.'
            }
            if (Test-Path $SessionDir) {
                # Under DEBUG, keep the proxy log for post-mortem inspection
                # (parity with deepantigravity.sh's last-proxy-<backend>.log).
                if ($env:DEEPANTIGRAVITY_DEBUG -eq '1') {
                    $be = (Get-Content $SessionBackendFile -ErrorAction SilentlyContinue | Select-Object -First 1)
                    if (-not $be) { $be = 'unknown' }
                    $dest = Join-Path $ScriptDir "proxy\.cache\last-proxy-$be.log"
                    foreach ($src in @($SessionLogFile, "$SessionLogFile.err")) {
                        if (Test-Path $src) { Get-Content $src -ErrorAction SilentlyContinue | Add-Content -Path $dest -ErrorAction SilentlyContinue }
                    }
                }
                Remove-Item $SessionDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Best-effort cleanup. Drop our member file even if locking failed.
        try {
            $myFile = Join-Path $SessionMembersDir "$PID"
            Remove-Item -LiteralPath $myFile -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    $script:JoinedSession = $false
}

# ── Re-launch this script as admin and wait for it to finish. ──
function Invoke-AsAdmin {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Backend)       { $argList += @('-Backend', $Backend) }
    if ($env:DEEPANTIGRAVITY_DEBUG -eq '1') { $argList += '-DebugProxy' }
    if ($AgyArgs)       { $argList += '--'; $argList += $AgyArgs }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
}

function Launch-Agy {
    $resolved = Resolve-Backend
    Confirm-NodeModules

    if (-not (Test-Path $SessionDir))        { New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null }
    if (-not (Test-Path $SessionMembersDir)) { New-Item -ItemType Directory -Path $SessionMembersDir -Force | Out-Null }

    # ── Atomic: JOIN existing session, REFUSE if backend differs, or START. ──
    $script:NeedsLeader = $false
    Invoke-WithSessionLock -TimeoutSec 10 -Body {
        $existingPid = $null
        $existingBackend = $null
        if (Test-Path $SessionPidFile) {
            $existingPid = (Get-Content $SessionPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if (Test-Path $SessionBackendFile) {
            $existingBackend = (Get-Content $SessionBackendFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }

        $alive = $existingPid -and (Test-PidAlive ([int]$existingPid))

        if ($alive -and $existingBackend -eq $resolved) {
            # JOIN: just register ourselves and use the existing bundle.
            if (-not (Test-Path $SessionBundleFile)) {
                throw 'session is corrupted (proxy alive but ca-bundle missing). Stop the running session and try again.'
            }
            New-Item -ItemType File -Path (Join-Path $SessionMembersDir "$PID") -Force | Out-Null
            $script:JoinedSession = $true
            $n = Get-SessionActiveMemberCount
            Write-Host "  Joined shared session: backend=$existingBackend, proxy PID=$existingPid ($n session(s) active)"
            $env:SSL_CERT_FILE = $SessionBundleFile
            $env:SSL_CERT_DIR  = (Split-Path -Parent $SessionBundleFile)
        }
        elseif ($alive -and $existingBackend -ne $resolved) {
            # REFUSE: backend mismatch. Windows can't multiplex backends.
            $n = Get-SessionActiveMemberCount
            $msg = @"
another deepantigravity session is running with a DIFFERENT backend
  Running backend: $existingBackend  (proxy PID $existingPid, $n session(s) active)
  Requested:       $resolved

  Windows does not support different backends in parallel because
  there is no per-process hosts-file equivalent. Either re-run with
  -b $existingBackend, or stop the other sessions.
"@
            throw $msg
        }
        else {
            # START: no live proxy — we need to be the leader.
            $script:NeedsLeader = $true
        }
    }

    if (-not $script:NeedsLeader) {
        # We're a follower: just exec agy with the existing bundle.
        & agy @AgyArgs
        return
    }

    # ── Leader path: needs admin (bind :443 + modify hosts file) ──
    if (-not (Test-Admin)) {
        Write-Host '  No active session — starting one. Leader needs Administrator.'
        Write-Host '  Re-launching elevated...'
        Invoke-AsAdmin
        return
    }

    # We are admin. Take the lock again and do the full leader flow.
    Invoke-WithSessionLock -TimeoutSec 10 -Body {
        # Re-check (another launcher may have raced ahead while we elevated)
        $existingPid = $null
        if (Test-Path $SessionPidFile) {
            $existingPid = (Get-Content $SessionPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($existingPid -and (Test-PidAlive ([int]$existingPid))) {
            $existingBackend = (Get-Content $SessionBackendFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($existingBackend -eq $resolved) {
                New-Item -ItemType File -Path (Join-Path $SessionMembersDir "$PID") -Force | Out-Null
                $script:JoinedSession = $true
                Write-Host "  Joined shared session that started while elevating (proxy PID $existingPid)"
                $env:SSL_CERT_FILE = $SessionBundleFile
                $env:SSL_CERT_DIR  = (Split-Path -Parent $SessionBundleFile)
                return
            } else {
                throw "another session started a different backend while we elevated: $existingBackend"
            }
        }

        # Wipe stale state
        Remove-Item $SessionPidFile, $SessionBackendFile, $SessionBundleFile, $SessionLogFile -Force -ErrorAction SilentlyContinue
        Remove-Item $SessionMembersDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $SessionMembersDir -Force | Out-Null

        # Clean any stale hosts hijack from a crashed previous session.
        if (Test-HostsHijacked) {
            Write-Host '  Cleaning stale hosts file entries from a previous session...'
            Remove-HostsHijack
        }

        # Resolve real Google IPs BEFORE hijacking. -DnsOnly bypasses the
        # local hosts file, so we get the upstream address directly.
        $cloudIp = Get-RealIp 'cloudcode-pa.googleapis.com'
        $dailyIp = Get-RealIp 'daily-cloudcode-pa.googleapis.com'
        if (-not $cloudIp) { throw "could not resolve real IP of cloudcode-pa.googleapis.com (Resolve-DnsName -DnsOnly returned nothing)" }
        if (-not $dailyIp) { $dailyIp = $cloudIp }
        Write-Host "  Real IPs: cloudcode-pa → $cloudIp, daily-cloudcode-pa → $dailyIp"

        # Add hosts hijack
        Write-Host '  Adding hosts file redirect for cloudcode-pa.googleapis.com...'
        Add-HostsHijack

        # Free :443 if something else is bound (orphan from earlier crash)
        Free-Port ([int]$DeepantigravityPort)

        # Spawn proxy DETACHED. On Windows, Start-Process without -Wait
        # creates a child that survives this script's exit (no SIGHUP).
        Write-Host "  Starting deepantigravity TLS server → $resolved ..."
        $proxyScript = Join-Path $ScriptDir 'proxy\start-proxy.js'
        # Set REAL_IP env vars for the proxy child (it needs them to forward
        # bootstrap calls to real Google with the hosts file hijacked).
        [Environment]::SetEnvironmentVariable('DEEPANTIGRAVITY_REAL_IP_CLOUDCODE', $cloudIp, 'Process')
        [Environment]::SetEnvironmentVariable('DEEPANTIGRAVITY_REAL_IP_DAILY',     $dailyIp, 'Process')

        $proc = Start-Process -FilePath 'node' `
            -ArgumentList @($proxyScript, $resolved, $DeepantigravityPort) `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $SessionLogFile `
            -RedirectStandardError  "$SessionLogFile.err"

        # Wait for the "port\nca-path" lines.
        $port = $null; $caPath = $null
        $tries = 0
        while ($tries -lt 60) {
            if (Test-Path $SessionLogFile) {
                $lines = Get-Content $SessionLogFile -ErrorAction SilentlyContinue
                $port  = $lines | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
                $caPath = $lines | Where-Object { $_ -match '^[A-Z]:|^/' } | Select-Object -First 1
                if ($port -and $caPath -and (Test-Path $caPath)) { break }
            }
            if ($proc.HasExited) {
                Write-Host 'ERROR: proxy died on startup' -ForegroundColor Red
                if (Test-Path "$SessionLogFile.err") {
                    Get-Content "$SessionLogFile.err" | Write-Host -ForegroundColor DarkGray
                }
                Remove-HostsHijack
                throw 'proxy failed to start'
            }
            Start-Sleep -Milliseconds 100
            $tries++
        }
        if (-not $port -or -not $caPath -or -not (Test-Path $caPath)) {
            if (Test-Path "$SessionLogFile.err") {
                Get-Content "$SessionLogFile.err" | Write-Host -ForegroundColor DarkGray
            }
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            Remove-HostsHijack
            throw 'proxy startup output unexpected'
        }

        # Build the combined CA bundle.
        Build-CaBundle $caPath $SessionBundleFile

        # Record session state and register self as first member.
        Set-Content -Path $SessionPidFile     -Value "$($proc.Id)" -Encoding ASCII
        Set-Content -Path $SessionBackendFile -Value $resolved      -Encoding ASCII
        New-Item -ItemType File -Path (Join-Path $SessionMembersDir "$PID") -Force | Out-Null
        $script:JoinedSession = $true

        Write-Host "  TLS server on 127.0.0.1:$port  → $resolved  (proxy PID $($proc.Id))"
        Write-Host "  CA bundle: $SessionBundleFile"
        Write-Host ''

        $env:SSL_CERT_FILE = $SessionBundleFile
        $env:SSL_CERT_DIR  = (Split-Path -Parent $SessionBundleFile)
    }

    # Run agy in foreground. Cleanup runs in finally{}.
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
    Invoke-CleanupOnExit
}
