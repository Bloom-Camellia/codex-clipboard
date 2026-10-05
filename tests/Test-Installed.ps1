$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'HotkeyTestTools.ps1')
$root = Split-Path -Parent $PSScriptRoot
$command = Get-Command codex
if ($command.CommandType -ne 'Function' -or $command.ModuleName -ne 'CodexClipboard') { throw 'Installed PowerShell profile did not load the codex wrapper.' }
Write-Output ('PROFILE: '+$command.CommandType+' / '+$command.ModuleName)
$originalClipboard = [Windows.Forms.Clipboard]::GetDataObject()
$session = $null
$generatedPath = $null
try {
    $session = Start-CodexClipboardSession
    $bitmap = New-Object Drawing.Bitmap 4,5
    try {
        $bitmap.SetPixel(0,0,[Drawing.Color]::Blue)
        [Windows.Forms.Clipboard]::SetImage($bitmap)
    } finally { $bitmap.Dispose() }
    Start-Sleep -Milliseconds 250
    if (-not [Windows.Forms.Clipboard]::ContainsImage()) { throw 'Normal screenshot was changed without Ctrl+Q.' }
    Write-Output 'INSTALLED NORMAL: image preserved without Ctrl+Q.'
    Send-TestCtrlQ
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if ([Windows.Forms.Clipboard]::ContainsText()) {
            $text = [Windows.Forms.Clipboard]::GetText()
            if ($text.EndsWith('.png') -and [IO.File]::Exists($text)) { $generatedPath=$text; break }
        }
        Start-Sleep -Milliseconds 60
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $generatedPath) { throw 'Installed watcher did not turn the test image into a path.' }
    $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $root 'screenshots'))
    if ([IO.Path]::GetDirectoryName($generatedPath) -ne $expectedDirectory -or
        [IO.Path]::GetFileName($generatedPath) -notmatch '^codex-shot-[0-9]{19}-[0-9a-f]{32}\.png$') { throw 'Installed watcher saved outside the expected screenshot directory.' }
    Write-Output ('INSTALLED CAPTURE: '+$generatedPath)
    $image = [Drawing.Image]::FromFile($generatedPath)
    try {
        if ($image.Width -ne 4 -or $image.Height -ne 5 -or $image.GetPixel(0,0).ToArgb() -ne [Drawing.Color]::Blue.ToArgb()) { throw 'Installed PNG does not match the clipboard image.' }
    } finally { $image.Dispose() }
    Write-Output 'INSTALLED SMOKE: Ctrl+Q absolute path and real PNG verified.'
} finally {
    if ($null -ne $session) {
        Stop-CodexClipboardSession -Session $session
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while ((Get-CodexClipboardSessionCount) -eq 0 -and $null -ne (Get-CodexClipboardWatcher) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 60 }
    }
    if ($null -ne $generatedPath -and [IO.File]::Exists($generatedPath)) { [IO.File]::Delete($generatedPath) }
    if ($null -ne $originalClipboard) { [Windows.Forms.Clipboard]::SetDataObject($originalClipboard,$true) }
    else { [Windows.Forms.Clipboard]::Clear() }
}
