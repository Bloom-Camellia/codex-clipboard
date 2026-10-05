param([string]$ProjectRoot = $PSScriptRoot)
$script:ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$script:SourceRoot = $PSScriptRoot


function New-CodexClipboardStateMutex {
    param([string]$ProjectRoot = $script:ProjectRoot)
    $rootPath=[IO.Path]::GetFullPath($ProjectRoot).ToLowerInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rootPath))).Replace('-','') }
    finally { $sha.Dispose() }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return New-Object Threading.Mutex($false,('Local\CodexClipboardState-'+$sid+'-'+$hash.Substring(0,24)))
}

function Get-CodexClipboardWatcher {
    param([string]$ProjectRoot = $script:ProjectRoot,[switch]$IncludeStarting)
    $state = Join-Path $ProjectRoot '.state'
    $pidPath = Join-Path $state 'watcher.pid'
    $readyPath = Join-Path $state 'watcher.ready'
    try {
        if (-not [IO.File]::Exists($pidPath)) { return $null }
        $record = [IO.File]::ReadAllLines($pidPath)
        if ($record.Count -ne 2) { return $null }
        if (-not $IncludeStarting) {
            if (-not [IO.File]::Exists($readyPath)) { return $null }
            $ready = [IO.File]::ReadAllLines($readyPath)
            if ($ready.Count -ne 2 -or $record[0] -ne $ready[0] -or $record[1] -ne $ready[1]) { return $null }
        }
        $process = [Diagnostics.Process]::GetProcessById([int]$record[0])
        try {
            if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$record[1]) { return $null }
            return [pscustomobject]@{ Pid=[int]$record[0]; StartTicks=[long]$record[1] }
        } finally { $process.Dispose() }
    } catch { return $null }
}

function Get-CodexClipboardSessionCount {
    param([string]$ProjectRoot = $script:ProjectRoot)
    $directory = Join-Path $ProjectRoot '.state\sessions'
    if (-not [IO.Directory]::Exists($directory)) { return 0 }
    $count = 0
    foreach ($lease in @(Get-ChildItem -LiteralPath $directory -Filter 'session-*.lease' -File)) {
        if ($lease.Name -notmatch '^session-[a-f0-9]{32}\.lease$') { continue }
        $valid = $false
        try {
            $record = [IO.File]::ReadAllLines($lease.FullName)
            if ($record.Count -eq 2) {
                $process = [Diagnostics.Process]::GetProcessById([int]$record[0])
                try { $valid = $process.StartTime.ToUniversalTime().Ticks -eq [long]$record[1] }
                finally { $process.Dispose() }
            }
        } catch { $valid = $false }
        if ($valid) { $count++ }
        else { Remove-Item -LiteralPath $lease.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $count
}

function Start-CodexClipboardSession {
    param([string]$ProjectRoot = $script:ProjectRoot)
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $gate=New-CodexClipboardStateMutex -ProjectRoot $ProjectRoot
    $owned=$false
    $leasePath=$null
    try {
        try { $owned=$gate.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { throw 'Timed out waiting for watcher registration lock.' }
        $directory = Join-Path $ProjectRoot '.state\sessions'
        [void][IO.Directory]::CreateDirectory($directory)
        $leasePath = Join-Path $directory ('session-'+[guid]::NewGuid().ToString('N')+'.lease')
        $temporary = $leasePath+'.tmp'
        $record = [string]$PID+[Environment]::NewLine+[string]([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
        [IO.File]::WriteAllText($temporary,$record)
        [IO.File]::Move($temporary,$leasePath)
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        $lastLaunch=[DateTime]::MinValue
        do {
            $watcher = Get-CodexClipboardWatcher -ProjectRoot $ProjectRoot
            if ($null -ne $watcher) {
                return [pscustomobject]@{ ProjectRoot=$ProjectRoot; LeasePath=$leasePath; WatcherPid=$watcher.Pid }
            }
            $starting=Get-CodexClipboardWatcher -ProjectRoot $ProjectRoot -IncludeStarting
            if ($null -eq $starting -and ([DateTime]::UtcNow-$lastLaunch).TotalMilliseconds -ge 400) {
                $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $script:SourceRoot 'Watcher.ps1')+'" -ProjectRoot "'+$ProjectRoot+'"'
                Start-Process -FilePath $powerShellPath -WindowStyle Hidden -ArgumentList $arguments | Out-Null
                $lastLaunch=[DateTime]::UtcNow
            }
            Start-Sleep -Milliseconds 60
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Clipboard watcher did not start. Check $(Join-Path $ProjectRoot '.state\watcher.log')."
    } catch {
        if ($null -ne $leasePath) { Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($owned) { $gate.ReleaseMutex() }
        $gate.Dispose()
    }
}

function Stop-CodexClipboardSession {
    param([Parameter(Mandatory=$true)]$Session)
    $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $Session.ProjectRoot '.state\sessions')).TrimEnd('\')
    $lease = [IO.Path]::GetFullPath($Session.LeasePath)
    if ([IO.Path]::GetDirectoryName($lease).TrimEnd('\') -ne $expectedDirectory -or
        [IO.Path]::GetFileName($lease) -notmatch '^session-[a-f0-9]{32}\.lease$') {
        throw 'Session cleanup target is outside the tool session directory.'
    }
    Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue
}

function codex {
    $configuration = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'config.json') -Raw | ConvertFrom-Json
    $executable = $configuration.codexExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) {
        $command = Get-Command codex -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $executable = $command.Source
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Codex executable not found: $executable" }
    $session = $null
    try {
        try { $session = Start-CodexClipboardSession -ProjectRoot $script:ProjectRoot }
        catch { Write-Warning ("Clipboard watcher failed to start: "+$_.Exception.Message) }
        & $executable @args
        $codexExitCode = $LASTEXITCODE
    } finally {
        if ($null -ne $session) { Stop-CodexClipboardSession -Session $session }
    }
    $global:LASTEXITCODE = $codexExitCode
}
Export-ModuleMember -Function codex,Start-CodexClipboardSession,Stop-CodexClipboardSession,Get-CodexClipboardWatcher,Get-CodexClipboardSessionCount,New-CodexClipboardStateMutex
