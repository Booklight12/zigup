param([string]$LockPath, [string]$ReadyPath)
$ErrorActionPreference = 'Stop'
$handle = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    [IO.File]::WriteAllText($ReadyPath, [string]$PID)
    while ($true) { Start-Sleep -Seconds 1 }
}
finally { $handle.Dispose() }
