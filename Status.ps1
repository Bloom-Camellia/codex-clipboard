$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexClipboard.psm1') -Force
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$directory = $config.screenshotDirectory
if (-not [IO.Path]::IsPathRooted($directory)) { $directory = Join-Path $PSScriptRoot $directory }
$watcher = Get-CodexClipboardWatcher
$count = 0
if ([IO.Directory]::Exists($directory)) {
    $count = @(Get-ChildItem -LiteralPath $directory -Filter 'codex-shot-*.png' -File | Where-Object { $_.Name -match '^codex-shot-[0-9]{19}-[0-9a-f]{32}\.png$' }).Count
}
[pscustomobject]@{
    WatcherRunning=($null -ne $watcher)
    WatcherPid=if ($null -ne $watcher) {$watcher.Pid} else {$null}
    ActiveSessions=(Get-CodexClipboardSessionCount)
    ScreenshotDirectory=[IO.Path]::GetFullPath($directory)
    ScreenshotCount=$count
    RetainCount=$config.retainCount
    ConversionHotkey=if ([string]::IsNullOrWhiteSpace($config.hotkey)) { 'Ctrl+Q' } else { $config.hotkey }
    AutomaticConversion=$false
    RetentionPending=($count -gt $config.retainCount)
}
