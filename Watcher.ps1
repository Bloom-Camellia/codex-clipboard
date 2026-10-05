param([string]$ProjectRoot = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$state = Join-Path $ProjectRoot '.state'
[void][IO.Directory]::CreateDirectory($state)
$logPath = Join-Path $state 'watcher.log'
function Write-WatcherLog($message) {
    try {
        if ([IO.File]::Exists($logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 262144) { [IO.File]::WriteAllText($logPath,'') }
        [IO.File]::AppendAllText($logPath,([DateTime]::UtcNow.ToString('o')+' '+$message+[Environment]::NewLine))
    } catch {}
}
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant()))).Replace('-','') }
finally { $sha.Dispose() }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = New-Object Threading.Mutex($false,('Local\CodexClipboard-'+$sid+'-'+$hash.Substring(0,24)))
$owned = $false
$trigger = $null
$identity = [string]$PID+[Environment]::NewLine+[string]([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
$pidPath = Join-Path $state 'watcher.pid'
$readyPath = Join-Path $state 'watcher.ready'
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
    [IO.File]::WriteAllText($pidPath,$identity)
    if ([IO.File]::Exists($readyPath)) { [IO.File]::Delete($readyPath) }
    $configuration = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config.json') -Raw | ConvertFrom-Json
    $retainCount = [int]$configuration.retainCount
    $poll = [int]$configuration.pollMilliseconds
    if ($retainCount -lt 1 -or $poll -lt 20 -or $poll -gt 1000) { throw 'Invalid watcher configuration.' }
    $imageDirectory = $configuration.screenshotDirectory
    if (-not [IO.Path]::IsPathRooted($imageDirectory)) { $imageDirectory = Join-Path $ProjectRoot $imageDirectory }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -Path (Join-Path $PSScriptRoot 'ClipboardEngine.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
    Import-Module (Join-Path $PSScriptRoot 'CodexClipboard.psm1') -ArgumentList $ProjectRoot -Force
    $hotkey = 'Ctrl+Q'
    if (-not [string]::IsNullOrWhiteSpace($configuration.hotkey)) { $hotkey = [string]$configuration.hotkey }
    $trigger = New-Object CodexClipboard.HotkeyTrigger -ArgumentList $hotkey
    $lastHandledRequest = -1L
    [IO.File]::WriteAllText($readyPath,$identity)
    Write-WatcherLog "Started PID=$PID retain=$retainCount hotkey=$hotkey automaticConversion=false"
    $lastSessionCheck = [DateTime]::MinValue
    $emptySince = $null
    $lastError = [DateTime]::MinValue
    $pending = $null
    $pendingSequence = 0
    while ($true) {
        $now = [DateTime]::UtcNow
        if (($now-$lastSessionCheck).TotalMilliseconds -ge 300) {
            $lastSessionCheck = $now
            if ((Get-CodexClipboardSessionCount -ProjectRoot $ProjectRoot) -eq 0) {
                if ($null -eq $emptySince) { $emptySince = $now }
                if (($now-$emptySince).TotalMilliseconds -ge 600) {
                    $stateGate=New-CodexClipboardStateMutex -ProjectRoot $ProjectRoot
                    $gateOwned=$false
                    $shouldExit=$false
                    try {
                        try { $gateOwned=$stateGate.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $gateOwned=$true }
                        if ($gateOwned -and (Get-CodexClipboardSessionCount -ProjectRoot $ProjectRoot) -eq 0) {
                            if ([IO.File]::Exists($readyPath) -and [IO.File]::ReadAllText($readyPath) -eq $identity) { [IO.File]::Delete($readyPath) }
                            $shouldExit=$true
                        }
                    } finally {
                        if ($gateOwned) { $stateGate.ReleaseMutex() }
                        $stateGate.Dispose()
                    }
                    if ($shouldExit) { break }
                    $emptySince=$null
                }
            } else { $emptySince = $null }
        }
        $request = $trigger.TakeRequest()
        $sequence = [CodexClipboard.Native]::Sequence
        if ($null -ne $pending) {
            if ($sequence -ne $pendingSequence) { $pending = $null }
            else {
                try {
                    if ([CodexClipboard.Native]::ReplaceText($pendingSequence,$pending.SavedPath)) {
                        Write-WatcherLog ('Published pending '+$pending.SavedPath)
                        $pending = $null
                    }
                } catch {
                    if (($now-$lastError).TotalSeconds -ge 5) {
                        Write-WatcherLog ('Publication pending: '+$_.Exception.Message)
                        $lastError = $now
                    }
                }
            }
        }
        if ($null -eq $pending -and $request -ge 0 -and $request -ne $lastHandledRequest) {
            $sequence = [uint32]$request
            try {
                $result = [CodexClipboard.Engine]::Capture($imageDirectory,$retainCount,$sequence)
                $lastHandledRequest = $request
                if ($null -ne $result) {
                    if (-not $result.ClipboardReplaced -and [CodexClipboard.Native]::Sequence -eq $sequence) {
                        $pending = $result; $pendingSequence = $sequence
                    }
                    Write-WatcherLog ("Saved "+$result.SavedPath+" replaced="+$result.ClipboardReplaced+" remaining="+$result.RemainingFiles)
                    if ($result.RemainingFiles -gt $retainCount) { Write-WatcherLog ("Retention retry required: "+[CodexClipboard.Engine]::LastCleanupError) }
                }
            } catch {
                if (($now-$lastError).TotalSeconds -ge 5) {
                    Write-WatcherLog ('Capture failed: '+$_.Exception.Message)
                    $lastError = $now
                }
            }
        }
        Start-Sleep -Milliseconds $poll
    }
    Write-WatcherLog 'Stopped: final CLI session ended.'
} catch {
    Write-WatcherLog ('Watcher failed: '+$_.Exception.Message)
    throw
} finally {
    if ($owned) {
        if ($null -ne $trigger) { $trigger.Dispose() }
        foreach ($marker in @($readyPath,$pidPath)) {
            if ([IO.File]::Exists($marker) -and [IO.File]::ReadAllText($marker) -eq $identity) { [IO.File]::Delete($marker) }
        }
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
