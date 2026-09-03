param(
    [Parameter(Mandatory = $true)]
    [string]$ZigupHome,

    [Parameter(Mandatory = $true)]
    [string]$ZigupExe,

    [string]$IndexUrl = 'https://ziglang.org/download/index.json'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

# ZIGUP_PROXY_IMPLEMENTATION
if ($null -eq (Get-Command Invoke-ZigupDownload -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'windows_proxy.ps1')
}

function Write-Status([string]$Message) {
    Write-Host "zigup: $Message"
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $temporary = "$Path.zigup-tmp-$([guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        Move-FileAtomically $temporary $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Move-FileAtomically([string]$Source, [string]$Destination) {
    if ([System.IO.File]::Exists($Destination)) {
        $backup = "$Destination.zigup-replace-backup-$([guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::Replace($Source, $Destination, $backup)
        }
        finally {
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                [System.IO.File]::Delete($backup)
            }
        }
    }
    else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

function Copy-FileAtomically([string]$Source, [string]$Destination) {
    $temporary = "$Destination.zigup-tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::Copy($Source, $temporary, $false)
        if ((Get-FileSha256 $Source) -ne (Get-FileSha256 $temporary)) {
            throw "copied file failed SHA-256 validation: $Destination"
        }
        Move-FileAtomically $temporary $Destination
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Open-ExclusiveFileLock([string]$Path) {
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        while ($true) {
            try {
                $stream.Lock(0, 1)
                return $stream
            }
            catch [System.IO.IOException] {
                Start-Sleep -Milliseconds 50
            }
        }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Get-NormalizedPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = '\\' + $fullPath.Substring(8)
    }
    elseif ($fullPath.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $fullPath = $fullPath.Substring(4)
    }
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        return $fullPath.TrimEnd('\')
    }
    return $fullPath
}

function Test-DedicatedZigDirectory([string]$Directory) {
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory 'zig.exe') -PathType Leaf)) {
            return $false
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Directory 'lib\std\std.zig') -PathType Leaf)) {
            return $false
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Directory 'LICENSE') -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path $Directory 'LICENSE.md') -PathType Leaf)) {
            return $false
        }

        $allowedEntries = @(
            'doc', 'lib', 'LICENSE', 'LICENSE.md', 'README', 'README.md',
            'zig.exe', 'zig.pdb', 'zig-dev.cmd', 'zigup.cmd'
        )
        foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force)) {
            if ($entry.Name -notin $allowedEntries) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Test-PathContainsDirectory([string]$PathValue, [string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }
    $normalizedDirectory = Get-NormalizedPath $Directory
    foreach ($segment in $PathValue.Split(';')) {
        $candidate = [Environment]::ExpandEnvironmentVariables($segment.Trim().Trim('"'))
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            if ((Get-NormalizedPath $candidate).Equals($normalizedDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {}
    }
    return $false
}

function Get-PlatformKey {
    $architecture = $null
    try {
        $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {}
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'cannot determine the Windows architecture'
    }
    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'x86_64-windows' }
        'X64' { return 'x86_64-windows' }
        'ARM64' { return 'aarch64-windows' }
        'X86' { return 'x86-windows' }
        default { throw "unsupported Windows architecture: $architecture" }
    }
}

function Get-LatestStableProperty($Index) {
    $stable = @(
        $Index.PSObject.Properties |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
    )
    if ($stable.Count -eq 0) {
        throw 'the Zig download index contains no stable release'
    }
    return $stable[0]
}

function Get-ReleaseAsset($Release, [string]$PlatformKey) {
    $property = $Release.PSObject.Properties[$PlatformKey]
    if ($null -eq $property) {
        throw "the Zig download index has no asset for $PlatformKey"
    }
    return $property.Value
}

function Assert-SafeVersion([string]$Version) {
    if ($Version.Length -gt 128 -or $Version -notmatch '^[0-9A-Za-z](?:[0-9A-Za-z._+-]*[0-9A-Za-z])?$') {
        throw "unsafe version in Zig download index: $Version"
    }
    $stem = $Version.Split('.')[0].ToUpperInvariant()
    if ($stem -in @('CON', 'PRN', 'AUX', 'NUL') -or $stem -match '^(?:COM|LPT)[1-9]$') {
        throw "unsafe version in Zig download index: $Version"
    }
}

function Test-ZigVersion([string]$Executable, [string]$ExpectedVersion) {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $false
    }
    try {
        $actual = (& $Executable version 2>$null | Select-Object -First 1).Trim()
        return $actual -eq $ExpectedVersion
    }
    catch {
        return $false
    }
}

function Get-FileSha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            $actual = -join @($hashBytes | ForEach-Object { $_.ToString('x2') })
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    return $actual
}

function Test-ArchiveHash([string]$Archive, [string]$ExpectedHash) {
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        return $false
    }
    return (Get-FileSha256 $Archive) -eq $ExpectedHash.ToLowerInvariant()
}

function Get-SystemTool([string]$Name) {
    # Pin tar/curl to the copy in System32 so PATH entries from MSYS
    # environments (e.g. launching zigup from Git Bash) cannot shadow them:
    # MSYS tar misreads "C:\..." paths as remote host names.
    $systemTool = Join-Path $env:SystemRoot "System32\$Name"
    if (Test-Path -LiteralPath $systemTool -PathType Leaf) {
        return $systemTool
    }
    return $Name
}

function Install-Release(
    [string]$Channel,
    $Release,
    [string]$PlatformKey,
    [string]$DownloadsDir,
    [string]$ToolchainsDir
) {
    $version = [string]$Release.version
    Assert-SafeVersion $version
    $asset = Get-ReleaseAsset $Release $PlatformKey
    $url = [string]$asset.tarball
    $expectedHash = [string]$asset.shasum

    if (-not $url.StartsWith('https://ziglang.org/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'refusing a non-official Zig download URL'
    }
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "invalid SHA-256 in Zig download index for $version"
    }

    $targetDir = Join-Path $ToolchainsDir $version
    $zigExe = Join-Path $targetDir 'zig.exe'
    if (Test-ZigVersion $zigExe $version) {
        Write-Status "$Channel $version is already installed"
        return $zigExe
    }

    $archiveName = "zig-$Channel-$version.zip"
    $archive = Join-Path $DownloadsDir $archiveName
    if (-not (Test-ArchiveHash $archive $expectedHash)) {
        Write-Status "downloading $Channel $version"
        Invoke-ZigupDownload -Url $url -Destination $archive -ExpectedHash $expectedHash
    }

    Write-Status "verifying $Channel $version SHA-256"
    if (-not (Test-ArchiveHash $archive $expectedHash)) {
        throw "SHA-256 mismatch for $archive"
    }

    $targetItem = Get-Item -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue
    if ($null -ne $targetItem) {
        $invalidBackup = "$targetDir.invalid-$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $targetDir -Destination $invalidBackup
        Write-Status "preserved invalid installation at $invalidBackup"
    }

    $extractDir = Join-Path $ToolchainsDir ".extract-$Channel-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    try {
        Write-Status "extracting $Channel $version"
        & (Get-SystemTool 'tar.exe') -xf $archive -C $extractDir --strip-components 1
        if ($LASTEXITCODE -ne 0) {
            throw "tar failed while extracting $archive (exit $LASTEXITCODE)"
        }
        if (-not (Test-ZigVersion (Join-Path $extractDir 'zig.exe') $version)) {
            throw "the extracted $Channel archive does not contain Zig $version"
        }
        Move-Item -LiteralPath $extractDir -Destination $targetDir
    }
    finally {
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
    }

    if (-not (Test-ZigVersion $zigExe $version)) {
        throw "installed Zig failed version validation: $zigExe"
    }
    return $zigExe
}

function Write-CmdShim([string]$Path, [string]$Executable) {
    $escapedExecutable = $Executable.Replace('%', '%%')
    $content = "@echo off`r`nsetlocal DisableDelayedExpansion`r`n`"$escapedExecutable`" %*`r`n"
    Write-Utf8NoBom $Path $content
}

function Install-UserPath([string]$BinDir) {
    if ($BinDir.Contains(';')) {
        throw "cannot add a directory containing ';' to PATH: $BinDir"
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $segments = @($userPath.Split(';') | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.TrimEnd('\').Equals($BinDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
        })
    }
    $newPath = (@($BinDir) + $segments) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Status "ensured user PATH contains $BinDir"
}

function Install-SystemBridge(
    [string]$OriginalZigExe,
    [string]$StableExe,
    [string]$DevExe,
    [string]$InstalledZigup
) {
    if ([string]::IsNullOrWhiteSpace($OriginalZigExe)) {
        return
    }

    $systemDir = Split-Path -Parent $OriginalZigExe
    $stableDir = Split-Path -Parent $StableExe
    if ($systemDir.Equals($stableDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $systemDir 'zig.exe') -PathType Leaf)) {
        return
    }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not (Test-PathContainsDirectory $machinePath $systemDir)) {
        Write-Status "skipped system Zig bridge because the directory is not in the machine PATH: $systemDir"
        return
    }

    $normalizedSystemDir = Get-NormalizedPath $systemDir
    $normalizedStableDir = Get-NormalizedPath $stableDir
    $systemRoot = Get-NormalizedPath ([System.IO.Path]::GetPathRoot($normalizedSystemDir))
    if ($normalizedSystemDir.Equals($systemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Status "skipped system Zig bridge because the executable is in a filesystem root: $systemDir"
        return
    }
    $systemPrefix = $normalizedSystemDir.TrimEnd('\') + '\'
    if ($normalizedStableDir.StartsWith($systemPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Status "skipped system Zig bridge because it would move the managed toolchains: $systemDir"
        return
    }
    if (-not (Test-DedicatedZigDirectory $systemDir)) {
        Write-Status "skipped system Zig bridge because this is not a dedicated Zig distribution directory: $systemDir"
        return
    }

    Write-CmdShim (Join-Path $stableDir 'zig-dev.cmd') $DevExe
    Write-CmdShim (Join-Path $stableDir 'zigup.cmd') $InstalledZigup

    $systemItem = Get-Item -LiteralPath $systemDir -Force
    $isJunction = ($systemItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isJunction -and $null -ne $systemItem.Target) {
        foreach ($target in @($systemItem.Target)) {
            try {
                if ((Get-NormalizedPath ([string]$target)).Equals($normalizedStableDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Status "system Zig path already points to stable Zig: $systemDir"
                    return
                }
            }
            catch {}
        }
    }
    $newLink = "$systemDir.zigup-new"
    $newItem = Get-Item -LiteralPath $newLink -Force -ErrorAction SilentlyContinue
    if ($null -ne $newItem) {
        if (($newItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            [System.IO.Directory]::Delete($newLink)
        }
        else {
            throw "refusing to replace non-junction path: $newLink"
        }
    }
    New-Item -ItemType Junction -Path $newLink -Target $stableDir | Out-Null

    $oldVersion = 'unknown'
    try {
        $oldVersion = (& $OriginalZigExe version 2>$null | Select-Object -First 1).Trim()
    }
    catch {}
    $safeOldVersion = $oldVersion -replace '[^0-9A-Za-z._+-]', '_'
    if ([string]::IsNullOrWhiteSpace($safeOldVersion)) {
        $safeOldVersion = 'unknown'
    }
    if ($safeOldVersion.Length -gt 80) {
        $safeOldVersion = $safeOldVersion.Substring(0, 80)
    }
    $backup = "$systemDir.zigup-backup-$safeOldVersion"
    $backupItem = Get-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    if ($null -ne $backupItem) {
        $backup = "$backup-$([guid]::NewGuid().ToString('N'))"
    }

    [System.IO.Directory]::Move($systemDir, $backup)
    try {
        [System.IO.Directory]::Move($newLink, $systemDir)
    }
    catch {
        $installError = $_.Exception.Message
        if (-not (Test-Path -LiteralPath $systemDir) -and (Test-Path -LiteralPath $backup)) {
            try {
                [System.IO.Directory]::Move($backup, $systemDir)
            }
            catch {
                throw "failed to install the Zig junction ($installError) and rollback also failed ($($_.Exception.Message)); previous path is $backup"
            }
        }
        throw
    }

    if ($isJunction) {
        Write-Status "preserved previous system Zig junction at $backup"
    }
    else {
        Write-Status "preserved previous system Zig at $backup"
    }
    Write-Status "system Zig path now points to stable Zig: $systemDir"
}

$ZigupHome = Get-NormalizedPath $ZigupHome
$ZigupExe = Get-NormalizedPath $ZigupExe
$binDir = Join-Path $ZigupHome 'bin'
$versionsDir = Join-Path $ZigupHome 'versions'
$downloadsDir = Join-Path $ZigupHome 'downloads'
$toolchainsDir = Join-Path $ZigupHome 'toolchains'
New-Item -ItemType Directory -Force -Path $binDir, $versionsDir, $downloadsDir, $toolchainsDir | Out-Null

$lockPath = Join-Path $ZigupHome 'update.lock'
try {
    $updateLock = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch [System.IO.IOException] {
    throw "cannot acquire the update lock; another zigup update may already be running: $lockPath"
}

try {
$originalZigCommand = Get-Command zig.exe -ErrorAction SilentlyContinue
$originalZigExe = if ($null -ne $originalZigCommand) { $originalZigCommand.Source } else { '' }

Write-Status 'reading official release index'
$indexFile = Join-Path $downloadsDir "index-$([guid]::NewGuid().ToString('N')).json"
try {
    Invoke-ZigupDownload -Url $IndexUrl -Destination $indexFile -Validator {
        param($Path)
        $candidate = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        return $null -ne $candidate.PSObject.Properties['master']
    }
    $index = [IO.File]::ReadAllText($indexFile) | ConvertFrom-Json
}
finally {
    if ([IO.File]::Exists($indexFile)) { [IO.File]::Delete($indexFile) }
}
$platformKey = Get-PlatformKey
$stableProperty = Get-LatestStableProperty $index
$stableRelease = $stableProperty.Value
if ([string]$stableRelease.version -ne [string]$stableProperty.Name) {
    throw "the stable release key and version disagree: $($stableProperty.Name) vs $($stableRelease.version)"
}
$devRelease = $index.master
if ($null -eq $devRelease) {
    throw 'the Zig download index contains no master development release'
}

Write-Status "latest stable: $($stableRelease.version)"
Write-Status "latest dev:    $($devRelease.version)"
$stableExe = Install-Release 'stable' $stableRelease $platformKey $downloadsDir $toolchainsDir
$devExe = Install-Release 'dev' $devRelease $platformKey $downloadsDir $toolchainsDir

$storeLock = Open-ExclusiveFileLock (Join-Path $ZigupHome 'store.lock')
try {
    Write-Utf8NoBom (Join-Path $versionsDir "$($stableRelease.version).path") $stableExe
    Write-Utf8NoBom (Join-Path $versionsDir "$($devRelease.version).path") $devExe
    Write-Utf8NoBom (Join-Path $ZigupHome 'current') ([string]$stableRelease.version)
    Write-Utf8NoBom (Join-Path $ZigupHome 'current-dev') ([string]$devRelease.version)
    Write-CmdShim (Join-Path $binDir 'zig.cmd') $stableExe
    Write-CmdShim (Join-Path $binDir 'zig-dev.cmd') $devExe
}
finally {
    try {
        $storeLock.Unlock(0, 1)
    }
    finally {
        $storeLock.Dispose()
    }
}

$installedZigup = Join-Path $binDir 'zigup.exe'
$copyZigup = -not (Test-Path -LiteralPath $installedZigup -PathType Leaf)
if (-not $copyZigup) {
    $copyZigup = (Get-FileSha256 $ZigupExe) -ne (Get-FileSha256 $installedZigup)
}
if ($copyZigup) {
    Copy-FileAtomically $ZigupExe $installedZigup
}
Install-UserPath $binDir
Install-SystemBridge $originalZigExe $stableExe $devExe $installedZigup

Write-Status "update complete"
Write-Host "zig=$(& $stableExe version)"
Write-Host "zig-dev=$(& $devExe version)"
Write-Host 'Open a new terminal to pick up persistent PATH changes.'
}
finally {
    $updateLock.Dispose()
}
