param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $ProjectRoot 'src\windows_proxy.ps1')
$script:Assertions = 0

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "assertion failed: $Name" }
    $script:Assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $failed = $false
    try { & $Action | Out-Null }
    catch { $failed = $true }
    Assert-Equal $failed $true $Name
}
function New-TestSettings([string]$Proxy = '', [string]$Bypass = '', [bool]$Enabled = $true) {
    return [pscustomobject]@{
        Proxy = $Proxy; Bypass = $Bypass; Enabled = $Enabled
        Source = 'windows-user'; AutoConfigUrl = ''; AutoDetect = $false
    }
}

Assert-Equal (ConvertTo-ZigupProxy 'proxy.test:8080') 'http://proxy.test:8080' 'bare proxy'
Assert-Equal (ConvertTo-ZigupProxy 'https://PROXY.test') 'https://proxy.test:443' 'HTTPS default port'
Assert-Equal (ConvertTo-ZigupProxy 'socks5h://[::1]:1080') 'socks5h://[::1]:1080' 'SOCKS IPv6'
Assert-Equal (ConvertTo-ZigupProxy 'socks5://proxy.test') 'socks5://proxy.test:1080' 'SOCKS default port'
Assert-Equal (ConvertTo-ZigupProxy 'http://user:p%40ss@proxy.test:8080') 'http://user:p%40ss@proxy.test:8080' 'encoded credentials'
foreach ($invalid in @('', 'file://proxy', 'http://host:0', 'http://host/path', 'http://host?token=secret', "http://bad`nproxy", 'http://host:70000', 'http://host/#fragment')) {
    Assert-Throws { ConvertTo-ZigupProxy $invalid } 'invalid proxy rejected'
}
Assert-Throws { ConvertTo-ZigupProxy 'host:1234' $false } 'explicit scheme required'
Assert-Equal (Test-ZigupBypass 'https://ziglang.org' 'ziglang.org') $true 'host bypass'
Assert-Equal (Test-ZigupBypass 'https://builds.ziglang.org' '.ziglang.org') $true 'suffix bypass'
Assert-Equal (Test-ZigupBypass 'https://notziglang.org' 'ziglang.org') $false 'suffix boundary'
Assert-Equal (Test-ZigupBypass 'https://ziglang.org' 'ziglang.org:443') $true 'bypass matching port'
Assert-Equal (Test-ZigupBypass 'https://ziglang.org' 'ziglang.org:80') $false 'bypass wrong port'
Assert-Equal (Test-ZigupBypass 'https://ziglang.org' 'ziglang.org:9999999999999') $false 'overflow port ignored'
Assert-Equal (Test-ZigupBypass 'http://[::1]:1234' '[::1]:1234') $true 'IPv6 port'
Assert-Equal (Test-ZigupBypass 'http://[::1]:1234' '[::1]:99999999999999') $false 'IPv6 overflow port ignored'
Assert-Equal (Test-ZigupBypass 'http://127.3.4.5' '127.0.0.0/8') $true 'IPv4 CIDR'
Assert-Equal (Test-ZigupBypass 'http://128.3.4.5' '127.0.0.0/8') $false 'IPv4 outside CIDR'
Assert-Equal (Test-ZigupBypass 'http://[fe80::2]' 'fe80::/10') $true 'IPv6 CIDR'
Assert-Equal (Test-ZigupBypass 'http://intranet' '<local>' $true) $true 'Windows local bypass'
Assert-Equal (Test-ZigupBypass 'http://example.org' '*.org' $true) $true 'Windows wildcard'
Assert-Equal (Test-ZigupBypass 'http://example.org' 'example.org' $true) $true 'Windows exact host'

$settings = @(New-TestSettings 'http=plain.test:80;https=secure.test:8080;socks=socks.test:1080')
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{} $settings)
Assert-Equal $routes.Count 2 'mapped proxy and direct'
Assert-Equal $routes[0].Proxy 'http://secure.test:8080' 'HTTPS mapping uses HTTP proxy transport'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{} @(New-TestSettings 'stale.test:80' '' $false))
Assert-Equal $routes.Count 1 'disabled manual proxy ignored'
$disabledHash = @{Proxy='stale.test:80';Bypass='';Enabled=$false;Source='windows-user';AutoConfigUrl='';AutoDetect=$false}
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{} @($disabledHash))
Assert-Equal $routes.Count 1 'disabled injected dictionary proxy ignored'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{https_proxy='env.test:81';all_proxy='socks5h://fallback.test:1080'} $settings)
Assert-Equal $routes.Count 4 'deduplicate routes'
Assert-Equal $routes[0].Proxy 'http://env.test:81' 'environment precedes system'
Assert-Equal $routes[1].Proxy 'socks5h://fallback.test:1080' 'all_proxy fallback'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{http_proxy='wrong.test:80'} @())
Assert-Equal $routes.Count 1 'HTTP-only env not used for HTTPS'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{https_proxy='env.test:81';no_proxy='.ziglang.org'} $settings)
Assert-Equal $routes.Count 1 'NO_PROXY suppresses all proxy sources'
Assert-Equal $routes[0].Proxy '' 'NO_PROXY direct'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{ZIGUP_PROXY='direct';https_proxy='env.test:81'} $settings)
Assert-Equal $routes.Count 1 'forced direct no fallback'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org' @{ZIGUP_PROXY='http://explicit.test:80';no_proxy='*'} $settings)
Assert-Equal $routes.Count 1 'forced explicit no fallback'
Assert-Equal $routes[0].Proxy 'http://explicit.test:80' 'forced proxy overrides bypass'
Assert-Throws { Get-ZigupDownloadRoutes 'https://ziglang.org' @{ZIGUP_PROXY='typo'} @() } 'invalid explicit mode'
$autoSettings = @(New-TestSettings)
$autoSettings[0].AutoConfigUrl = 'http://pac.test/proxy.pac'
$script:AutoUrls = @()
$resolver = {
    param($Url, $Pac, $Detect)
    $script:AutoUrls += $Url
    return [pscustomobject]@{Proxy='pac.test:8080';Bypass='';Direct=$Url.EndsWith('/direct')}
}
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org/proxy' @{} $autoSettings $resolver)
Assert-Equal $routes[0].Proxy 'http://pac.test:8080' 'PAC proxy result'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org/direct' @{} $autoSettings $resolver)
Assert-Equal $routes.Count 1 'PAC direct result'
Assert-Equal $script:AutoUrls.Count 2 'PAC evaluated per URL'
$autoSettings[0].Proxy = 'manual.test:8080'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org/direct' @{} $autoSettings $resolver)
Assert-Equal $routes.Count 1 'PAC DIRECT excludes configured manual proxy'
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org/proxy' @{} $autoSettings $resolver)
Assert-Equal $routes.Count 2 'PAC success excludes same-entry manual fallback'
$failedResolver = { param($Url, $Pac, $Detect); return $null }
$routes = @(Get-ZigupDownloadRoutes 'https://ziglang.org/proxy' @{} $autoSettings $failedResolver)
Assert-Equal $routes[0].Proxy 'http://manual.test:8080' 'PAC failure permits manual fallback'

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('zigup-proxy-unit-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
try {
    $destination = Join-Path $testDirectory 'download.bin'
    $script:Attempts = @()
    $script:GoodProxy = 'http://system.test:8080'
    $runner = {
        param($Url, $Temporary, $Route)
        $script:Attempts += $Route.Proxy
        [IO.File]::WriteAllText($Temporary, 'partial')
        if ($Route.Proxy -ne $script:GoodProxy) { return 7 }
        [IO.File]::WriteAllText($Temporary, 'complete')
        return 0
    }
    Reset-ZigupProxyState
    $request = @{Url='https://ziglang.org/index.json';Destination=$destination;Environment=@{https_proxy='broken.test:80'};SystemSettings=@(New-TestSettings 'system.test:8080');Runner=$runner}
    Invoke-ZigupDownload @request
    Assert-Equal ($script:Attempts -join ',') 'http://broken.test:80,http://system.test:8080' 'failed environment switches to system'
    Assert-Equal ([IO.File]::ReadAllText($destination)) 'complete' 'only complete download installed'
    $script:Attempts = @()
    Invoke-ZigupDownload @request
    Assert-Equal $script:Attempts.Count 1 'successful route remembered'
    Assert-Equal $script:Attempts[0] 'http://system.test:8080' 'remembered route first'
    $request.SystemSettings = @()
    $script:GoodProxy = ''
    $script:Attempts = @()
    Invoke-ZigupDownload @request
    Assert-Equal ($script:Attempts -join ',') 'http://broken.test:80,' 'stale winner not reused'

    $script:ZigupPreferredRoutes['https://ziglang.org'] = [pscustomobject]@{Proxy='http://manual.test:8080';Candidates="http://manual.test:8080`0"}
    $script:Attempts = @()
    Invoke-ZigupDownload -Url 'https://ziglang.org/direct' -Destination $destination -Environment @{} -SystemSettings $autoSettings -AutoResolver $resolver -Runner $runner
    Assert-Equal $script:Attempts.Count 1 'PAC bypass not overridden by cached manual route'
    Assert-Equal $script:Attempts[0] '' 'PAC bypass stays direct'
    $script:GoodProxy = 'http://pac.test:8080'
    $script:Attempts = @()
    Invoke-ZigupDownload -Url 'https://ziglang.org/proxy' -Destination $destination -Environment @{} -SystemSettings $autoSettings -AutoResolver $resolver -Runner $runner
    Assert-Equal $script:Attempts.Count 1 'new PAC route used before previous direct winner'
    Assert-Equal $script:Attempts[0] 'http://pac.test:8080' 'PAC DIRECT to PROXY transition respected'
    $script:GoodProxy = ''
    $script:Attempts = @()
    Invoke-ZigupDownload -Url 'https://ziglang.org/direct' -Destination $destination -Environment @{} -SystemSettings $autoSettings -AutoResolver $resolver -Runner $runner
    Assert-Equal $script:Attempts.Count 1 'new PAC bypass used before previous proxy winner'
    Assert-Equal $script:Attempts[0] '' 'PAC PROXY to DIRECT transition respected'

    Reset-ZigupProxyState
    $script:Attempts = @()
    $request.Runner = { param($Url, $Temporary, $Route); $script:Attempts += $Route.Proxy; [IO.File]::WriteAllText($Temporary, 'invalid'); return 0 }
    $request.ExpectedHash = ('0' * 64)
    Assert-Throws { Invoke-ZigupDownload @request } 'hash mismatch fails closed'
    Assert-Equal $script:Attempts.Count 1 'hash mismatch does not reroute'
    Assert-Equal ([IO.File]::ReadAllText($destination)) 'complete' 'hash failure preserves destination'
    $request.Remove('ExpectedHash')
    $request.Validator = { param($Path); return $false }
    Assert-Throws { Invoke-ZigupDownload @request } 'index validator fails closed'
    $request.Remove('Validator')
    $request.Runner = { param($Url, $Temporary, $Route); [IO.File]::WriteAllText($Temporary, 'partial'); return 7 }
    Assert-Throws { Invoke-ZigupDownload @request } 'all routes fail'
    Assert-Equal ([IO.File]::ReadAllText($destination)) 'complete' 'all failures preserve destination'
    $script:Attempts = @()
    $request.Runner = { param($Url, $Temporary, $Route); $script:Attempts += $Route.Proxy; return 23 }
    Assert-Throws { Invoke-ZigupDownload @request } 'local write failure'
    Assert-Equal $script:Attempts.Count 1 'local write failure does not reroute'
    $request.Environment = @{ZIGUP_PROXY='http://username:secret@proxy.test:80'}
    $request.Runner = { param($Url, $Temporary, $Route); return 7 }
    $captured = (& { try { Invoke-ZigupDownload @request } catch { Write-Output $_.Exception.Message } } 6>&1 | Out-String)
    Assert-Equal ($captured.Contains('secret') -or $captured.Contains('username') -or $captured.Contains('proxy.test')) $false 'credentials and endpoint not logged'
    Assert-Equal @(Get-ChildItem -LiteralPath $testDirectory -Filter '*.zigup-*').Count 0 'temporary files cleaned'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'zigup-proxy-unit-*') {
        throw 'test cleanup target failed validation'
    }
    [IO.Directory]::Delete($resolved, $true)
}
Write-Host "Windows proxy unit tests passed: $script:Assertions assertions"
