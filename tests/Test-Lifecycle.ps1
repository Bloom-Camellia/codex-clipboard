$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'HotkeyTestTools.ps1')
$root = Split-Path -Parent $PSScriptRoot
$module = Join-Path $root 'CodexClipboard.psm1'
if (-not (Test-Path -LiteralPath $module)) { throw 'FAIL: CLI session launcher and watcher have not been implemented.' }
$testRoot = Join-Path $root ('tests\runs\lifecycle-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot 'config.json'),'{"retainCount":30,"pollMilliseconds":60,"screenshotDirectory":"screenshots","hotkey":"Ctrl+Alt+Q"}')
$originalClipboard = [Windows.Forms.Clipboard]::GetDataObject()
$script:passed = 0
$sessions = @()
function Assert($condition,$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
function Wait-Until($condition, $message) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 60
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "FAIL: timed out: $message"
}
function Set-TestImage {
    $bitmap = New-Object Drawing.Bitmap 3,4
    [Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
}
try {
    Import-Module $module -ArgumentList $testRoot -Force
    Set-TestImage
    $first = Start-CodexClipboardSession -ProjectRoot $testRoot
    $sessions += $first
    Start-Sleep -Milliseconds 180
    Assert ([Windows.Forms.Clipboard]::ContainsImage() -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'screenshots'))) 'watcher ignores image already present when CLI starts'
    $second = Start-CodexClipboardSession -ProjectRoot $testRoot
    $sessions += $second
    Assert ($first.WatcherPid -eq $second.WatcherPid) 'multiple CLI sessions reuse a single watcher'
    $duplicate = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Watcher.ps1')+'" -ProjectRoot "'+$testRoot+'"')
    Assert ($duplicate.WaitForExit(10000) -and $duplicate.ExitCode -eq 0) 'duplicate watcher exits without replacing active watcher'
    $live = Get-CodexClipboardWatcher -ProjectRoot $testRoot
    Assert ($live.Pid -eq $first.WatcherPid) 'duplicate watcher leaves original watcher registered'

    Set-TestImage
    Send-TestConversionHotkey
    Wait-Until { [Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText().EndsWith('.png') } 'new image conversion'
    $imagePath = [Windows.Forms.Clipboard]::GetText()
    Assert ([IO.File]::Exists($imagePath) -and [IO.Path]::IsPathRooted($imagePath)) 'background watcher converts a new image into a saved absolute PNG path'
    Start-Sleep -Milliseconds 180
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'screenshots') -Filter '*.png').Count -eq 1) 'background watcher does not save its own path event'

    Stop-CodexClipboardSession -Session $first
    Start-Sleep -Milliseconds 700
    Assert ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $testRoot)) 'watcher stays alive while a second CLI session exists'
    $leaseDir = Join-Path $testRoot '.state\sessions'
    [IO.File]::WriteAllText((Join-Path $leaseDir ('session-'+[guid]::NewGuid().ToString('N')+'.lease')), ('2147483646'+[Environment]::NewLine+'1'))
    Stop-CodexClipboardSession -Session $second
    Wait-Until { $null -eq (Get-CodexClipboardWatcher -ProjectRoot $testRoot) } 'last session shutdown'
    Assert ($null -eq (Get-CodexClipboardWatcher -ProjectRoot $testRoot)) 'watcher stops after final CLI exit and removes dead session leases'

    $fakeExe = Join-Path $testRoot 'fake-codex.cmd'
    [IO.File]::WriteAllText($fakeExe, ((@('@echo off','echo %~1','echo %~2','exit /b 7','')) -join [Environment]::NewLine))
    $configuration = @{retainCount=30;pollMilliseconds=60;screenshotDirectory='screenshots';hotkey='Ctrl+Alt+Q';codexExecutable=$fakeExe} | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $testRoot 'config.json'),$configuration)
    $output = @(codex 'path with spaces' '--example')
    Assert ($output.Count -eq 2 -and $output[0] -eq 'path with spaces' -and $output[1] -eq '--example') 'codex wrapper forwards arguments including spaces'
    Assert ($LASTEXITCODE -eq 7) 'codex wrapper preserves original executable exit code'
    Wait-Until { $null -eq (Get-CodexClipboardWatcher -ProjectRoot $testRoot) } 'wrapper final cleanup'
    Assert (@(Get-ChildItem -LiteralPath $leaseDir -Filter '*.lease').Count -eq 0) 'codex wrapper unregisters its session on exit'
    Write-Output "LIFECYCLE: $script:passed assertions passed."
} finally {
    foreach ($session in $sessions) {
        if ($null -ne (Get-Command Stop-CodexClipboardSession -ErrorAction SilentlyContinue)) { Stop-CodexClipboardSession -Session $session }
    }
    if ($null -ne $originalClipboard) { [Windows.Forms.Clipboard]::SetDataObject($originalClipboard,$true) }
    else { [Windows.Forms.Clipboard]::Clear() }
}
