# Embedded into windows_update.ps1 at build time; also usable as a standalone
# function library for deterministic tests. Never changes system proxy settings.
$script:ZigupPreferredRoutes = @{}

function Reset-ZigupProxyState {
    $script:ZigupPreferredRoutes = @{}
}

function ConvertTo-ZigupProxy([string]$Value, [bool]$AllowBare = $true) {
    $value = $Value.Trim()
    if ($value.Length -eq 0 -or $value.Length -gt 4096 -or $value -match '[\x00-\x20\x7f"<>\\]') {
        throw 'invalid proxy address'
    }
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if (-not $AllowBare) { throw 'proxy URL must include its scheme' }
        $value = 'http://' + $value
    }
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h') -or
        [string]::IsNullOrEmpty($uri.Host) -or $uri.AbsolutePath -notin @('', '/') -or
        $uri.Query.Length -ne 0 -or $uri.Fragment.Length -ne 0 -or $uri.Port -eq 0) {
        throw 'invalid or unsupported proxy URL'
    }
    $proxyHost = $uri.DnsSafeHost.Trim('[', ']')
    $proxyIp = $null
    if ([Net.IPAddress]::TryParse($proxyHost, [ref]$proxyIp)) { $proxyHost = $proxyIp.ToString() }
    if ($proxyHost.Contains(':')) { $proxyHost = '[' + $proxyHost + ']' }
    $port = $uri.Port
    if ($port -lt 0) { $port = 1080 }
    $credentials = ''
    if ($uri.UserInfo.Length -ne 0) { $credentials = $uri.UserInfo + '@' }
    return $uri.Scheme + '://' + $credentials + $proxyHost + ':' + $port
}

function Test-ZigupIpNetwork([string]$HostName, [string]$Network) {
    $parts = $Network.Split('/')
    if ($parts.Count -ne 2) { return $false }
    $address = $null
    $base = $null
    $bits = 0
    if (-not [System.Net.IPAddress]::TryParse($HostName.Trim('[', ']'), [ref]$address) -or
        -not [System.Net.IPAddress]::TryParse($parts[0].Trim('[', ']'), [ref]$base) -or
        -not [int]::TryParse($parts[1], [ref]$bits)) { return $false }
    $a = $address.GetAddressBytes()
    $b = $base.GetAddressBytes()
    if ($a.Length -ne $b.Length -or $bits -lt 0 -or $bits -gt $a.Length * 8) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) {
        $remaining = $bits - $i * 8
        if ($remaining -le 0) { return $true }
        $mask = if ($remaining -ge 8) { 255 } else { (255 -shl (8 - $remaining)) -band 255 }
        if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { return $false }
    }
    return $true
}

function Test-ZigupBypass([Uri]$Url, [string]$Bypass, [bool]$System = $false) {
    $targetHost = $Url.DnsSafeHost.Trim('[', ']').TrimEnd('.').ToLowerInvariant()
    $targetIp = $null
    if ([Net.IPAddress]::TryParse($targetHost, [ref]$targetIp)) { $targetHost = $targetIp.ToString() }
    foreach ($item in ($Bypass -split '[,;\s]+')) {
        $pattern = $item.Trim().ToLowerInvariant()
        if ($pattern.Length -eq 0) { continue }
        if ($pattern -eq '*') { return $true }
        if ($pattern -eq '<local>') {
            if ($System -and -not $targetHost.Contains('.') -and -not $targetHost.Contains(':')) { return $true }
            continue
        }
        if ($pattern -match '^(https?)://(.*)$') {
            if ($Matches[1] -ne $Url.Scheme) { continue }
            $pattern = $Matches[2]
        }
        if ($pattern.Contains('/')) {
            if (Test-ZigupIpNetwork $targetHost $pattern) { return $true }
            continue
        }
        if ($pattern -match '^\[([^\]]+)\](?::([0-9]+))?$') {
            $pattern = $Matches[1]
            if ($Matches.ContainsKey(2)) {
                $bypassPort = 0
                if (-not [int]::TryParse($Matches[2], [ref]$bypassPort) -or $bypassPort -ne $Url.Port) { continue }
            }
        }
        elseif ($pattern -match '^([^:]+):([0-9]+)$') {
            $bypassPort = 0
            if (-not [int]::TryParse($Matches[2], [ref]$bypassPort) -or $bypassPort -ne $Url.Port) { continue }
            $pattern = $Matches[1]
        }
        $pattern = $pattern.TrimEnd('.')
        $patternIp = $null
        if ([Net.IPAddress]::TryParse($pattern, [ref]$patternIp)) { $pattern = $patternIp.ToString() }
        if ($System) {
            # Treat only '*' as a wildcard; '[' and '?' remain literal.
            $expression = '^' + [regex]::Escape($pattern).Replace('\*', '.*') + '$'
            if ($targetHost -match $expression) { return $true }
        }
        else {
            $pattern = $pattern.TrimStart('.')
            if ($pattern.StartsWith('*.')) { $pattern = $pattern.Substring(2) }
            if ($targetHost -eq $pattern -or $targetHost.EndsWith('.' + $pattern, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Initialize-ZigupNativeProxy {
    if ('Zigup.NativeProxy' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
namespace Zigup {
    public sealed class ProxySettings {
        public string Proxy = "";
        public string Bypass = "";
        public string AutoConfigUrl = "";
        public bool AutoDetect;
        public bool Direct;
        public bool Enabled = true;
        public string Source;
    }
    public static class NativeProxy {
        // WINHTTP_AUTOPROXY_OPTIONS dwFlags values used by WinHttpGetProxyForUrl.
        private const uint AutoDetectFlag = 0x00000001;
        private const uint ConfigUrlFlag = 0x00000002;
        // WinHTTP caches autoproxy results per host by default, so a PAC that
        // returns different routes for two URLs on one host would leak the first
        // decision to the second. Disable both the client and the out-of-process
        // service result caches so each URL is resolved from the PAC script.
        private const uint NoCacheClient = 0x00080000;
        private const uint NoCacheSvc = 0x00100000;
        private static readonly object ResolveGate = new object();
        private static Task<ProxySettings> pendingResolution;
        [StructLayout(LayoutKind.Sequential)] private struct IEConfig {
            [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
            public IntPtr AutoConfigUrl, Proxy, Bypass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProxyInfo {
            public uint AccessType;
            public IntPtr Proxy, Bypass;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct AutoOptions {
            public uint Flags, DetectFlags;
            [MarshalAs(UnmanagedType.LPWStr)] public string ConfigUrl;
            public IntPtr Reserved;
            public uint ReservedFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool AutoLogon;
        }
        [DllImport("winhttp.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetIEProxyConfigForCurrentUser(out IEConfig config);
        [DllImport("winhttp.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetDefaultProxyConfiguration(out ProxyInfo info);
        [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr WinHttpOpen(string agent, uint access, string proxy, string bypass, uint flags);
        [DllImport("winhttp.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpSetTimeouts(IntPtr session, int resolve, int connect, int send, int receive);
        [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetProxyForUrl(IntPtr session, string url, ref AutoOptions options, out ProxyInfo info);
        [DllImport("winhttp.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpCloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr pointer);
        private static string Read(IntPtr pointer) { return pointer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(pointer); }
        private static void Free(IntPtr pointer) { if (pointer != IntPtr.Zero) GlobalFree(pointer); }
        public static ProxySettings UserSettings() {
            IEConfig config = new IEConfig();
            try {
                if (!WinHttpGetIEProxyConfigForCurrentUser(out config)) return null;
                return new ProxySettings { Proxy = Read(config.Proxy), Bypass = Read(config.Bypass),
                    AutoConfigUrl = Read(config.AutoConfigUrl), AutoDetect = config.AutoDetect, Source = "windows-user" };
            } finally { Free(config.Proxy); Free(config.Bypass); Free(config.AutoConfigUrl); }
        }
        public static ProxySettings MachineSettings() {
            ProxyInfo info = new ProxyInfo();
            try {
                if (!WinHttpGetDefaultProxyConfiguration(out info) || info.AccessType != 3) return null;
                return new ProxySettings { Proxy = Read(info.Proxy), Bypass = Read(info.Bypass), Source = "windows-winhttp" };
            } finally { Free(info.Proxy); Free(info.Bypass); }
        }
        private static ProxySettings ResolveCore(string url, string pac, bool detect) {
            IntPtr session = WinHttpOpen("zigup", 1, null, null, 0);
            if (session == IntPtr.Zero) return null;
            ProxyInfo info = new ProxyInfo();
            try {
                WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000);
                AutoOptions options = new AutoOptions {
                    Flags = (detect ? AutoDetectFlag : 0u) | (String.IsNullOrEmpty(pac) ? 0u : ConfigUrlFlag) |
                        NoCacheClient | NoCacheSvc,
                    DetectFlags = detect ? 3u : 0u, ConfigUrl = String.IsNullOrEmpty(pac) ? null : pac, AutoLogon = false };
                if (!WinHttpGetProxyForUrl(session, url, ref options, out info)) return null;
                return new ProxySettings { Proxy = Read(info.Proxy), Bypass = Read(info.Bypass), Direct = info.AccessType == 1,
                    Source = "windows-auto" };
            } finally { Free(info.Proxy); Free(info.Bypass); WinHttpCloseHandle(session); }
        }
        public static ProxySettings Resolve(string url, string pac, bool detect) {
            // PAC evaluation/WPAD are OS services; bound our wait even if that
            // service ignores session timeouts. The worker owns its native handle.
            lock (ResolveGate) {
                // A timed-out OS operation cannot be safely aborted in-process.
                // Never accumulate workers when a broken WPAD service hangs.
                if (pendingResolution != null && !pendingResolution.IsCompleted) return null;
                pendingResolution = Task.Factory.StartNew(() => ResolveCore(url, pac, detect));
                return pendingResolution.Wait(12000) ? pendingResolution.Result : null;
            }
        }
    }
}
'@
}

function Get-ZigupSystemProxySettings {
    try {
        Initialize-ZigupNativeProxy
        $userSettings = [Zigup.NativeProxy]::UserSettings()
        if ($null -ne $userSettings) { $userSettings }
        $machineSettings = [Zigup.NativeProxy]::MachineSettings()
        if ($null -ne $machineSettings) { $machineSettings }
    }
    catch {
        Write-Host 'zigup: Windows proxy discovery unavailable; trying other routes'
    }
}

function Get-ZigupManualProxyRoutes([Uri]$Url, [string]$Proxy, [string]$Source) {
    $mapped = @()
    $generic = @()
    $socks = @()
    foreach ($entry in ($Proxy -split '[;\s]+')) {
        if ($entry.Length -eq 0) { continue }
        $address = $entry
        $kind = 'generic'
        if ($entry -match '^([a-zA-Z]+)=(.+)$') {
            $scheme = $Matches[1].ToLowerInvariant()
            $address = $Matches[2]
            if ($scheme -eq $Url.Scheme) { $kind = 'mapped' }
            elseif ($scheme -eq 'socks') {
                $kind = 'socks'
                if ($address -notmatch '://') { $address = 'socks4://' + $address }
            }
            else { continue }
        }
        try {
            $route = [pscustomobject]@{ Proxy = (ConvertTo-ZigupProxy $address); Source = $Source }
            switch ($kind) {
                'mapped' { $mapped += $route }
                'socks' { $socks += $route }
                default { $generic += $route }
            }
        }
        catch { Write-Host 'zigup: ignored an invalid system proxy address' }
    }
    # Per-protocol mappings override unqualified fallback proxies for that protocol.
    if ($mapped.Count -ne 0) { $mapped; return }
    if ($generic.Count -ne 0) { $generic; return }
    $socks
}

function Get-ZigupDownloadRoutes(
    [Uri]$Url,
    [System.Collections.IDictionary]$Environment = [Environment]::GetEnvironmentVariables(),
    [object[]]$SystemSettings = $null,
    [scriptblock]$AutoResolver = $null
) {
    $mode = [string]$Environment['ZIGUP_PROXY']
    $mode = $mode.Trim()
    $direct = [pscustomobject]@{ Proxy = ''; Source = 'direct' }
    if ($mode -eq 'direct') { $direct; return }
    if ($mode.Length -ne 0 -and $mode -ne 'auto') {
        try { $address = ConvertTo-ZigupProxy $mode $false }
        catch { throw 'invalid ZIGUP_PROXY: use auto, direct, or an http(s)/socks proxy URL' }
        [pscustomobject]@{ Proxy = $address; Source = 'explicit' }
        return
    }
    $bypass = [string]$Environment['no_proxy']
    if ([string]::IsNullOrWhiteSpace($bypass)) { $bypass = [string]$Environment['NO_PROXY'] }
    if (Test-ZigupBypass $Url $bypass) { $direct; return }
    $routes = @()
    $names = if ($Url.Scheme -eq 'https') { @('https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY') } else { @('http_proxy', 'all_proxy', 'ALL_PROXY') }
    foreach ($name in $names) {
        $value = [string]$Environment[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        try { $routes += [pscustomobject]@{ Proxy = (ConvertTo-ZigupProxy $value); Source = 'environment' } }
        catch { Write-Host 'zigup: ignored an invalid environment proxy address' }
    }
    if ($null -eq $SystemSettings) { $SystemSettings = @(Get-ZigupSystemProxySettings) }
    foreach ($settings in $SystemSettings) {
        if ($null -eq $settings) { continue }
        $source = [string]$settings.Source
        if ([string]::IsNullOrEmpty($source)) { $source = 'windows-system' }
        if ($settings.AutoDetect -or -not [string]::IsNullOrWhiteSpace($settings.AutoConfigUrl)) {
            try {
                if ($null -ne $AutoResolver) { $resolved = & $AutoResolver $Url.AbsoluteUri $settings.AutoConfigUrl $settings.AutoDetect }
                else {
                    Initialize-ZigupNativeProxy
                    $resolved = [Zigup.NativeProxy]::Resolve($Url.AbsoluteUri, $settings.AutoConfigUrl, $settings.AutoDetect)
                }
                if ($null -ne $resolved) {
                    if ($resolved.Direct -or (Test-ZigupBypass $Url ([string]$resolved.Bypass) $true)) {
                        $routes += $direct
                        # A successful per-URL PAC bypass must not be overridden
                        # by a stale manual/machine proxy or a remembered winner.
                        break
                    }
                    else { $routes += @(Get-ZigupManualProxyRoutes $Url ([string]$resolved.Proxy) 'windows-auto') }
                    # Static settings are only fallback when auto resolution fails.
                    continue
                }
                else { Write-Host 'zigup: automatic Windows proxy resolution unavailable; trying other routes' }
            }
            catch { Write-Host 'zigup: automatic Windows proxy resolution failed; trying other routes' }
        }
        $hasEnabled = if ($settings -is [System.Collections.IDictionary]) { $settings.Contains('Enabled') } else { $null -ne $settings.PSObject.Properties['Enabled'] }
        if ($hasEnabled -and -not $settings.Enabled) { continue }
        if (-not [string]::IsNullOrWhiteSpace($settings.Proxy)) {
            if (Test-ZigupBypass $Url ([string]$settings.Bypass) $true) { $routes += $direct }
            else { $routes += @(Get-ZigupManualProxyRoutes $Url ([string]$settings.Proxy) $source) }
        }
    }
    $routes += $direct
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($route in $routes) {
        if ($seen.Add([string]$route.Proxy)) { $route }
    }
}

function ConvertTo-ZigupCurlConfigValue([string]$Value) {
    # All dynamic curl options travel on stdin, not a shell or the process list.
    if ($Value -match '[\x00\r\n]') { throw 'invalid download configuration' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t') + '"'
}

function Invoke-ZigupCurl([string]$Url, [string]$Destination, $Route) {
    $systemCurl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not [IO.File]::Exists($systemCurl)) {
        $systemCurl = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $systemCurl
    $start.Arguments = '--disable --config - --fail --location --silent --connect-timeout 8 --speed-limit 1024 --speed-time 15 --max-time 900 --retry 1 --retry-delay 1 --retry-max-time 30 --proto =http,https --proto-redir =https'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(?i)(http|https|all|no)_proxy$') { $start.EnvironmentVariables.Remove($key) }
    }
    $bypass = if ([string]::IsNullOrEmpty($Route.Proxy)) { '*' } else { '' }
    $config = @(
        ('url = ' + (ConvertTo-ZigupCurlConfigValue $Url)),
        ('output = ' + (ConvertTo-ZigupCurlConfigValue $Destination)),
        ('proxy = ' + (ConvertTo-ZigupCurlConfigValue $Route.Proxy)),
        ('noproxy = ' + (ConvertTo-ZigupCurlConfigValue $bypass))
    ) -join "`n"
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        $savedInputEncoding = $null
        try {
            $utf8 = New-Object Text.UTF8Encoding($false)
            if ($null -ne $start.PSObject.Properties['StandardInputEncoding']) {
                $start.StandardInputEncoding = $utf8
            }
            else {
                # Framework creates its stdin writer from Console.InputEncoding
                # and immediately flushes a preamble. Restore the encoding as
                # soon as the child is started; no persisted setting is changed.
                $savedInputEncoding = [Console]::InputEncoding
                [Console]::InputEncoding = $utf8
            }
            if (-not $process.Start()) { return 2 }
            $started = $true
        }
        finally {
            if ($null -ne $savedInputEncoding) { [Console]::InputEncoding = $savedInputEncoding }
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        # .NET Framework's Process.StandardInput emits a UTF-8 BOM and offers no
        # StandardInputEncoding setter. curl treats that BOM as an option name.
        # Write BOM-free bytes to the pipe itself on both PowerShell runtimes.
        $inputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($config + "`n")
        $inputPipe = $process.StandardInput.BaseStream
        $inputPipe.Write($inputBytes, 0, $inputBytes.Length)
        $inputPipe.Close()
        if (-not $process.WaitForExit(925000)) {
            $process.Kill()
            $process.WaitForExit()
            return 28
        }
        # Drain diagnostics but never echo them: curl errors can contain proxy credentials.
        $null = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        return $process.ExitCode
    }
    catch {
        if ($started) {
            try {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            }
            catch {}
        }
        return 2
    }
    finally { $process.Dispose() }
}

function Test-ZigupDownloadedHash([string]$Path, [string]$ExpectedHash) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
        finally { $hash.Dispose() }
    }
    finally { $stream.Dispose() }
    return $actual -eq $ExpectedHash
}

function Move-ZigupDownloadedFile([string]$Source, [string]$Destination) {
    if ([IO.File]::Exists($Destination)) {
        $backup = "$Destination.zigup-replace-backup-$([guid]::NewGuid().ToString('N'))"
        try { [IO.File]::Replace($Source, $Destination, $backup) }
        finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
    }
    else { [IO.File]::Move($Source, $Destination) }
}

function Invoke-ZigupDownload(
    [string]$Url,
    [string]$Destination,
    [string]$ExpectedHash = '',
    [scriptblock]$Validator = $null,
    [System.Collections.IDictionary]$Environment = [Environment]::GetEnvironmentVariables(),
    [object[]]$SystemSettings = $null,
    [scriptblock]$AutoResolver = $null,
    [scriptblock]$Runner = $null
) {
    $uri = $null
    if ($Url -match '[\x00-\x20\x7f]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo.Length -ne 0) { throw 'invalid download URL' }
    if ($ExpectedHash.Length -ne 0 -and $ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'invalid expected SHA-256' }
    $routes = @(Get-ZigupDownloadRoutes $uri $Environment $SystemSettings $AutoResolver)
    $origin = $uri.GetLeftPart([UriPartial]::Authority)
    $candidateSignature = (@($routes | ForEach-Object { [string]$_.Proxy }) -join "`0")
    if ($script:ZigupPreferredRoutes.ContainsKey($origin)) {
        $preferred = $script:ZigupPreferredRoutes[$origin]
        # DIRECT is always an automatic fallback, but must not mask a new PAC
        # proxy decision or newly enabled settings just because it worked before.
        if ($preferred.Candidates -ceq $candidateSignature) {
            $routes = @($routes | Where-Object { $_.Proxy -ceq $preferred.Proxy }) + @($routes | Where-Object { $_.Proxy -cne $preferred.Proxy })
        }
    }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $attempt = 0
    foreach ($route in $routes) {
        $attempt++
        $temporary = "$destinationPath.zigup-tmp-$([guid]::NewGuid().ToString('N'))"
        $label = if ([string]::IsNullOrEmpty($route.Proxy)) { 'direct connection' } else { "$($route.Source) proxy" }
        Write-Host "zigup: downloading via $label"
        try {
            if ($null -eq $Runner) { $code = Invoke-ZigupCurl $Url $temporary $route }
            else { $code = & $Runner $Url $temporary $route }
            if ($code -eq 0 -and [IO.File]::Exists($temporary)) {
                $valid = $ExpectedHash.Length -eq 0 -or (Test-ZigupDownloadedHash $temporary $ExpectedHash)
                if ($valid -and $null -ne $Validator) {
                    try { $valid = [bool](& $Validator $temporary) }
                    catch { $valid = $false }
                }
                if ($valid) {
                    Move-ZigupDownloadedFile $temporary $destinationPath
                    $script:ZigupPreferredRoutes[$origin] = [pscustomobject]@{
                        Proxy = [string]$route.Proxy; Candidates = $candidateSignature
                    }
                    return
                }
                throw 'download validation failed (SHA-256 or release index); no files were installed'
            }
            elseif ($code -in @(2, 3, 4, 23, 26, 27, 37, 43)) {
                throw "local downloader failed (curl exit $code); check curl and destination permissions"
            }
            else { $reason = "download failed (curl exit $code)" }
            if ($attempt -lt $routes.Count) { Write-Host "zigup: $reason; switching download route" }
        }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    throw "download failed on all permitted routes ($reason); check proxy/network settings or set ZIGUP_PROXY"
}
