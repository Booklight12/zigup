param(
    [Parameter(Mandatory = $true)]
    [string]$FixtureFile,

    [Parameter(Mandatory = $true)]
    [string]$TestDirectory
)

# Run with Windows PowerShell 5.1 as well as newer PowerShell. All configuration
# is injected into the downloader; never change registry or persisted proxy data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'src\windows_proxy.ps1')
$fixture = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json
$testRoot = [System.IO.Path]::GetFullPath($TestDirectory)
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:PassedCases = 0
$script:CaseNumber = 0
$script:CapturedDownloadLog = ''
$script:CapturedDownloadError = $null

foreach ($property in @('origin', 'good', 'bad')) {
    $uri = [uri]$fixture.$property
    if ($uri.Scheme -ne 'http' -or -not $uri.IsLoopback) {
        throw "fixture $property must be a loopback HTTP URL"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FixtureEvents {
    # Explicitly bypass every ambient proxy, including a real system proxy.
    $client = New-Object System.Net.WebClient
    $client.Proxy = $null
    try {
        $events = $client.DownloadString("$($fixture.origin)/stats") | ConvertFrom-Json
        foreach ($event in @($events)) { $event }
    }
    finally { $client.Dispose() }
}

function Get-NewEvents([int]$PreviousCount) {
    $events = @(Get-FixtureEvents)
    if ($events.Count -gt $PreviousCount) {
        for ($i = $PreviousCount; $i -lt $events.Count; $i++) { $events[$i] }
    }
}

function Get-EventCount($Events, [string]$Kind, [string]$Method = 'GET') {
    return @($Events | Where-Object { $_.kind -eq $Kind -and $_.method -eq $Method }).Count
}

function Get-TextSha256([string]$Text) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function New-TestDestination([string]$Name) {
    $script:CaseNumber++
    return Join-Path $testRoot ("{0:D2}-{1}.download" -f $script:CaseNumber, $Name)
}

function Assert-Payload([string]$Path) {
    Assert-True ([System.IO.File]::Exists($Path)) "download did not create $Path"
    Assert-True ([System.IO.File]::ReadAllText($Path) -ceq [string]$fixture.payload) 'download payload differs from the fixture'
}

function Write-Passed([string]$Name) {
    $script:PassedCases++
    Write-Host "PASS $Name"
}

function Invoke-CapturedDownload([hashtable]$Parameters) {
    $log = New-Object System.Text.StringBuilder
    $encodingBefore = [Console]::InputEncoding
    $encodingSignature = $encodingBefore.CodePage.ToString() + ':' + [BitConverter]::ToString($encodingBefore.GetPreamble())
    $script:CapturedDownloadError = $null
    try {
        & { Invoke-ZigupDownload @Parameters } *>&1 | ForEach-Object {
            [void]$log.AppendLine([string]$_)
        }
    }
    catch {
        $script:CapturedDownloadError = $_
        [void]$log.AppendLine([string]$_)
    }
    $script:CapturedDownloadLog = $log.ToString()
    $encodingAfter = [Console]::InputEncoding
    $restoredSignature = $encodingAfter.CodePage.ToString() + ':' + [BitConverter]::ToString($encodingAfter.GetPreamble())
    Assert-True ($encodingSignature -ceq $restoredSignature) 'downloader changed the caller console input encoding'
}

function Invoke-SuccessfulDownload([hashtable]$Parameters) {
    Invoke-CapturedDownload $Parameters
    if ($null -ne $script:CapturedDownloadError) {
        throw "expected successful download: $($script:CapturedDownloadLog)"
    }
}

function New-SystemProxy([string]$Proxy, [bool]$Enabled = $true, [string]$Bypass = '') {
    return [pscustomobject]@{
        Source = 'integration system settings'
        Enabled = $Enabled
        Proxy = $Proxy
        Bypass = $Bypass
        AutoDetect = $false
        AutoConfigUrl = ''
    }
}

function Reset-TestProxyState {
    Reset-ZigupProxyState
}

$payloadHash = Get-TextSha256 ([string]$fixture.payload)
$goodSystem = @(New-SystemProxy ([string]$fixture.good))
$badSystem = @(New-SystemProxy ([string]$fixture.bad))
$noSystem = @()
$emptyResolver = { param($Url, $Settings) @() }

# An unsuccessful environment proxy must lead to a distinct system proxy.
# The second request verifies that the selected route is remembered.
Reset-TestProxyState
$environment = @{ https_proxy = [string]$fixture.bad; http_proxy = [string]$fixture.bad }
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'environment-to-system'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/environment-to-system"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = $environment; SystemSettings = $goodSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -ge 1) 'environment proxy was not attempted'
Assert-True ((Get-EventCount $events 'good') -eq 1) 'system fallback did not use the good proxy'
$firstBad = -1
$firstGood = -1
for ($i = 0; $i -lt $events.Count; $i++) {
    if ($firstBad -lt 0 -and $events[$i].kind -eq 'bad') { $firstBad = $i }
    if ($firstGood -lt 0 -and $events[$i].kind -eq 'good') { $firstGood = $i }
}
Assert-True ($firstGood -gt $firstBad) 'fallback proxies were attempted out of order'
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'sticky-system'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/sticky-system"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = $environment; SystemSettings = $goodSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -eq 0) 'later download retried the failed environment proxy'
Assert-True ((Get-EventCount $events 'good') -eq 1) 'later download did not remember the working system proxy'
Write-Passed 'environment -> system fallback and successful-route reuse'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'all-bad-to-direct'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/all-bad-to-direct"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = $environment; SystemSettings = $badSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -ge 1) 'unavailable proxy was not attempted before direct fallback'
Assert-True ((Get-EventCount $events 'good') -eq 0) 'unexpected proxy used during direct fallback'
Assert-True ((Get-EventCount $events 'origin') -eq 1) 'direct fallback did not reach the origin exactly once'
Write-Passed 'all automatic proxies unavailable -> direct'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'partial-to-empty'
[System.IO.File]::WriteAllText($destination, 'old output must be atomically replaced by an empty file')
$partialProxy = ([string]$fixture.bad).Replace('http://', 'http://zigup_test_user:zigup_test_secret@')
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/empty"; Destination = $destination
    ExpectedHash = (Get-TextSha256 '')
    Environment = @{ http_proxy = $partialProxy }; SystemSettings = $noSystem; AutoResolver = $emptyResolver
}
Assert-True ((Get-Item -LiteralPath $destination).Length -eq 0) 'successful empty download retained bytes from the failed partial response'
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -ge 1 -and (Get-EventCount $events 'origin') -eq 1) 'truncated proxy response did not switch to direct'
Assert-True (-not $script:CapturedDownloadLog.Contains('zigup_test_user') -and -not $script:CapturedDownloadLog.Contains('zigup_test_secret')) 'partial-response failure leaked proxy credentials'
Write-Passed 'partial proxy response -> empty direct response without stale bytes'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'disabled-system-proxy'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/disabled-system-proxy"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{}; SystemSettings = @(New-SystemProxy ([string]$fixture.bad) $false)
    AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -eq 0 -and (Get-EventCount $events 'good') -eq 0) 'disabled system proxy retained an active route'
Write-Passed 'disabled system proxy ignores retained proxy address'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'system-bypass'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/system-bypass"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{}; SystemSettings = @(New-SystemProxy ([string]$fixture.bad) $true '127.0.0.1')
    AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -eq 0) 'system bypass list was ignored'
Write-Passed 'system proxy bypass list'

foreach ($bypass in @('*', '127.0.0.1', "127.0.0.1:$(([uri]$fixture.origin).Port)")) {
    Reset-TestProxyState
    $before = @(Get-FixtureEvents).Count
    $destination = New-TestDestination 'no-proxy'
    Invoke-SuccessfulDownload @{
        Url = "$($fixture.origin)/no-proxy"
        Destination = $destination; ExpectedHash = $payloadHash
        Environment = @{ https_proxy = [string]$fixture.bad; http_proxy = [string]$fixture.bad; NO_PROXY = $bypass }
        SystemSettings = $goodSystem; AutoResolver = $emptyResolver
    }
    Assert-Payload $destination
    $events = @(Get-NewEvents $before)
    Assert-True ((Get-EventCount $events 'bad') -eq 0 -and (Get-EventCount $events 'good') -eq 0) "NO_PROXY=$bypass was not respected"
}
Write-Passed 'NO_PROXY wildcard, exact host, and host:port'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'forced-direct'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/forced-direct"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{ ZIGUP_PROXY = 'direct'; https_proxy = [string]$fixture.bad; http_proxy = [string]$fixture.bad }
    SystemSettings = $badSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -eq 0 -and (Get-EventCount $events 'good') -eq 0) 'forced direct still contacted a proxy'
Write-Passed 'forced direct overrides environment and system proxies'

Reset-TestProxyState
$curlConfigurationDirectory = Join-Path $testRoot 'isolated-curl-config'
[System.IO.Directory]::CreateDirectory($curlConfigurationDirectory) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $curlConfigurationDirectory '.curlrc'), "zigup-invalid-test-option`n")
$previousCurlHome = [Environment]::GetEnvironmentVariable('CURL_HOME', 'Process')
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'curl-config-isolation'
try {
    [Environment]::SetEnvironmentVariable('CURL_HOME', $curlConfigurationDirectory, 'Process')
    Invoke-SuccessfulDownload @{
        Url = "$($fixture.origin)/curl-config-isolation"; Destination = $destination; ExpectedHash = $payloadHash
        Environment = @{ ZIGUP_PROXY = 'direct' }; SystemSettings = $noSystem; AutoResolver = $emptyResolver
    }
}
finally { [Environment]::SetEnvironmentVariable('CURL_HOME', $previousCurlHome, 'Process') }
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'origin') -eq 1 -and (Get-EventCount $events 'bad') -eq 0) 'curl configuration isolation failed'
Write-Passed 'curl ignores caller configuration files and restores console encoding'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'forced-proxy'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/forced-proxy"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{ ZIGUP_PROXY = [string]$fixture.good; NO_PROXY = '*'; https_proxy = [string]$fixture.bad; http_proxy = [string]$fixture.bad }
    SystemSettings = $badSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'good') -eq 1 -and (Get-EventCount $events 'bad') -eq 0) 'forced proxy failed to override bypass or other proxy sources'
Write-Passed 'forced proxy overrides NO_PROXY and other candidates'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'proxy-authentication'
$authenticatedProxy = ([string]$fixture.good).Replace('http://', 'http://zigup_test_user:p%40ss%3Aword%25@')
Invoke-SuccessfulDownload @{
    Url = "$($fixture.origin)/proxy-authentication"
    Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{ ZIGUP_PROXY = $authenticatedProxy; NO_PROXY = '*' }
    SystemSettings = $noSystem; AutoResolver = $emptyResolver
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True (@($events | Where-Object { $_.kind -eq 'good' -and $_.auth_valid }).Count -eq 1) 'authenticated proxy request did not decode the expected credentials'
Assert-True (-not $script:CapturedDownloadLog.Contains('zigup_test_user')) 'successful proxy request leaked its username'
Assert-True (-not $script:CapturedDownloadLog.Contains('p%40ss') -and -not $script:CapturedDownloadLog.Contains('p@ss:word%')) 'successful proxy request leaked its password'
Write-Passed 'authenticated proxy works and credentials are absent from logs'

foreach ($invalid in @('file:///not-a-proxy', 'http://', "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:80`n--insecure")) {
    Reset-TestProxyState
    $before = @(Get-FixtureEvents).Count
    $destination = New-TestDestination 'invalid-forced-proxy'
    Invoke-CapturedDownload @{
        Url = "$($fixture.origin)/invalid-forced-proxy"; Destination = $destination
        Environment = @{ ZIGUP_PROXY = $invalid }; SystemSettings = $goodSystem; AutoResolver = $emptyResolver
    }
    Assert-True ($null -ne $script:CapturedDownloadError) 'invalid forced proxy was accepted'
    Assert-True (@(Get-NewEvents $before).Count -eq 0) 'invalid forced proxy caused a network request'
    Assert-True (-not [System.IO.File]::Exists($destination)) 'invalid forced proxy created an output file'
}
Write-Passed 'invalid explicit settings fail before network access'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'failed-output-preservation'
$sentinel = 'pre-existing output must survive failure'
[System.IO.File]::WriteAllText($destination, $sentinel)
$credentialProxy = ([string]$fixture.bad).Replace('http://', 'http://zigup_test_user:zigup_test_secret@')
Invoke-CapturedDownload @{
    Url = "$($fixture.origin)/failed-output-preservation"; Destination = $destination
    Environment = @{ ZIGUP_PROXY = $credentialProxy; NO_PROXY = '*' }
    SystemSettings = $goodSystem; AutoResolver = $emptyResolver
}
Assert-True ($null -ne $script:CapturedDownloadError) 'forced unavailable proxy unexpectedly succeeded'
Assert-True ([System.IO.File]::ReadAllText($destination) -ceq $sentinel) 'failed download replaced the existing output'
Assert-True (-not $script:CapturedDownloadLog.Contains('zigup_test_user')) 'proxy username leaked into logs'
Assert-True (-not $script:CapturedDownloadLog.Contains('zigup_test_secret')) 'proxy password leaked into logs'
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'bad') -ge 1) 'forced unavailable proxy was not contacted'
Assert-True ((Get-EventCount $events 'good') -eq 0 -and (Get-EventCount $events 'origin') -eq 0) 'forced unavailable proxy fell back to another route'
Write-Passed 'forced failure preserves output, refuses fallback, and redacts credentials'

Reset-TestProxyState
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'hash-mismatch'
[System.IO.File]::WriteAllText($destination, $sentinel)
Invoke-CapturedDownload @{
    Url = "$($fixture.origin)/hash-mismatch"; Destination = $destination
    ExpectedHash = ('0' * 64); Environment = @{ http_proxy = [string]$fixture.good }
    SystemSettings = $noSystem; AutoResolver = $emptyResolver
}
Assert-True ($null -ne $script:CapturedDownloadError) 'hash mismatch was accepted'
Assert-True ([System.IO.File]::ReadAllText($destination) -ceq $sentinel) 'hash mismatch replaced existing output'
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'origin') -eq 1) 'hash mismatch incorrectly retried another route'
Write-Passed 'hash mismatch is terminal and preserves existing output'

# Exercise the real native Windows PAC engine with explicit, loopback-only
# configuration. It receives no real registry settings and needs no TLS bypass.
Initialize-ZigupNativeProxy
$pacUrl = "$($fixture.origin)/pac?case=$([guid]::NewGuid().ToString('N'))"
$nativeLoopback = [Zigup.NativeProxy]::Resolve("$($fixture.origin)/index.json", $pacUrl, $false)
Assert-True ($null -ne $nativeLoopback -and $nativeLoopback.Direct) 'native resolver did not preserve Windows implicit loopback bypass'
$nativeIndex = [Zigup.NativeProxy]::Resolve("$($fixture.synthetic)/index.json", $pacUrl, $false)
Assert-True ($null -ne $nativeIndex) 'native PAC resolver returned no index result'
Assert-True (-not $nativeIndex.Direct) 'native PAC resolver ignored URL-specific proxy result'
Assert-True ($nativeIndex.Proxy.Contains(([uri]$fixture.good).Authority)) 'native PAC resolver returned an unexpected proxy'
$nativeArchive = [Zigup.NativeProxy]::Resolve("$($fixture.synthetic)/archive.tar.xz", $pacUrl, $false)
Assert-True ($null -ne $nativeArchive -and $nativeArchive.Direct) 'native PAC resolver ignored its DIRECT result'
$nativeIndexAgain = [Zigup.NativeProxy]::Resolve("$($fixture.synthetic)/index.json", $pacUrl, $false)
Assert-True ($null -ne $nativeIndexAgain -and -not $nativeIndexAgain.Direct) 'native PAC host-result cache overrode a later URL-specific proxy result'
Assert-True ($nativeIndexAgain.Proxy.Contains(([uri]$fixture.good).Authority)) 'native PAC repeat lookup returned an unexpected proxy'
Write-Passed 'native WinHTTP PAC resolves different routes per URL without registry edits'

Reset-TestProxyState
$pacSystem = @([pscustomobject]@{
    Source = 'integration PAC'; Enabled = $true; Proxy = ''; Bypass = ''
    AutoConfigUrl = $pacUrl; AutoDetect = $false
})
# WinHTTP implicitly bypasses literal loopback targets before consulting PAC.
# Resolve the original reserved synthetic host natively. The fixture proxy maps
# that host to our loopback origin without DNS. For DIRECT only, this test runner
# makes the equivalent local mapping before invoking the real production curl
# runner. Thus both transfers are real while no global DNS/hosts state changes.
$pacTestRunner = {
    param($Url, $Destination, $Route)
    $transferUrl = $Url
    if ([string]::IsNullOrEmpty($Route.Proxy)) {
        $original = [uri]$Url
        $synthetic = [uri]$fixture.synthetic
        Assert-True ($original.Host -ceq $synthetic.Host -and $original.Port -eq $synthetic.Port) 'test runner rejected a non-fixture synthetic target'
        $transferUrl = [string]$fixture.origin + $original.PathAndQuery
    }
    Invoke-ZigupCurl $transferUrl $Destination $Route
}
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'native-pac-index'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.synthetic)/index.json"; Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{}; SystemSettings = $pacSystem; Runner = $pacTestRunner
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'good') -eq 1) 'native PAC proxy result was not used by curl'
$before = @(Get-FixtureEvents).Count
$destination = New-TestDestination 'native-pac-archive'
Invoke-SuccessfulDownload @{
    Url = "$($fixture.synthetic)/archive.tar.xz"; Destination = $destination; ExpectedHash = $payloadHash
    Environment = @{}; SystemSettings = $pacSystem; Runner = $pacTestRunner
}
Assert-Payload $destination
$events = @(Get-NewEvents $before)
Assert-True ((Get-EventCount $events 'good') -eq 0 -and (Get-EventCount $events 'bad') -eq 0) 'sticky proxy overrode a later PAC DIRECT result'
Write-Passed 'native PAC drives downloads and prevents stale route reuse'

foreach ($invalidPac in @('pac-invalid', 'pac-fail')) {
    $result = [Zigup.NativeProxy]::Resolve(
        "$($fixture.synthetic)/index.json",
        "$($fixture.origin)/$($invalidPac)?case=$([guid]::NewGuid().ToString('N'))",
        $false
    )
    Assert-True ($null -eq $result) "native PAC failure $invalidPac was not reported"
}
Write-Passed 'native PAC syntax and HTTP failures are handled'

Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.zigup-tmp-*' -File).Count -eq 0) 'download temporary files were left behind'
Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.zigup-replace-backup-*' -File).Count -eq 0) 'download replacement backups were left behind'

if ([bool]$fixture.allow_live) {
    Reset-TestProxyState
    $before = @(Get-FixtureEvents).Count
    $destination = New-TestDestination 'live-official-index'
    Invoke-SuccessfulDownload @{
        Url = 'https://ziglang.org/download/index.json'; Destination = $destination
        Environment = @{ ZIGUP_PROXY = [string]$fixture.good; NO_PROXY = '*' }
        SystemSettings = $noSystem; AutoResolver = $emptyResolver
    }
    $index = [System.IO.File]::ReadAllText($destination) | ConvertFrom-Json
    Assert-True ($null -ne $index.PSObject.Properties['master']) 'official index does not contain master'
    $events = @(Get-NewEvents $before)
    Assert-True ((Get-EventCount $events 'good' 'CONNECT') -ge 1) 'live HTTPS request did not use CONNECT'
    Assert-True ((Get-EventCount $events 'bad') -eq 0) 'live request used unexpected proxy'
    Write-Passed 'live official HTTPS index through CONNECT with TLS verification'
}
else {
    Write-Host 'SKIP live official HTTPS index (fixture allow_live is false)'
}

Write-Host "WINDOWS_PROXY_INTEGRATION_OK cases=$script:PassedCases"
