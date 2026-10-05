$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'HotkeyTestTools.ps1')
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $root ('tests\runs\hotkey-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
[IO.File]::WriteAllText((Join-Path $testRoot 'config.json'),'{"retainCount":30,"pollMilliseconds":60,"screenshotDirectory":"screenshots","hotkey":"Ctrl+Alt+Q"}')
$images=Join-Path $testRoot 'screenshots'
[void][IO.Directory]::CreateDirectory($images)
$oldest=Join-Path $images 'codex-shot-0000000000000000001-0123456789abcdef0123456789abcdef.png'
foreach ($number in 1..30) {
    $file=Join-Path $images ('codex-shot-'+$number.ToString('D19')+'-0123456789abcdef0123456789abcdef.png')
    [IO.File]::WriteAllText($file,'old fixture')
}
$original=[Windows.Forms.Clipboard]::GetDataObject()
$session=$null
$script:passed=0
function Assert($condition,$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
function Set-TestImage {
    $image=New-Object Drawing.Bitmap 8,5
    try {
        $image.SetPixel(0,0,[Drawing.Color]::Green)
        [Windows.Forms.Clipboard]::SetImage($image)
    } finally { $image.Dispose() }
}
function Wait-Until($predicate,$message) {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $predicate) { return }
        Start-Sleep -Milliseconds 60
    }
    throw "FAIL: $message"
}
try {
    Import-Module (Join-Path $root 'CodexClipboard.psm1') -ArgumentList $testRoot -Force
    $session=Start-CodexClipboardSession -ProjectRoot $testRoot
    Set-TestImage
    Start-Sleep -Milliseconds 500
    Assert ([Windows.Forms.Clipboard]::ContainsImage()) 'new screenshot remains an image without Ctrl+Alt+Q'
    Assert (@(Get-ChildItem -LiteralPath $images -Filter '*.png').Count -eq 30 -and [IO.File]::Exists($oldest)) 'normal screenshot does not save a file or evict history'

    Send-TestConversionHotkey
    Wait-Until { [Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText().EndsWith('.png') } 'Ctrl+Alt+Q did not convert the image'
    $path=[Windows.Forms.Clipboard]::GetText()
    Assert ([IO.Path]::IsPathRooted($path) -and [IO.File]::Exists($path) -and [IO.Path]::GetDirectoryName($path) -eq $images) 'Ctrl+Alt+Q writes only the saved absolute PNG path'
    $image=[Drawing.Image]::FromFile($path)
    try { Assert ($image.Width -eq 8 -and $image.Height -eq 5 -and $image.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Green.ToArgb()) 'hotkey conversion preserves screenshot pixels' }
    finally { $image.Dispose() }
    Assert (@(Get-ChildItem -LiteralPath $images -Filter '*.png').Count -eq 30 -and -not [IO.File]::Exists($oldest)) 'Ctrl+Alt+Q conversion of image 31 deletes only the oldest image'
    Send-TestConversionHotkey
    Start-Sleep -Milliseconds 250
    Assert ([Windows.Forms.Clipboard]::GetText() -eq $path -and @(Get-ChildItem -LiteralPath $images -Filter '*.png').Count -eq 30) 'Ctrl+Alt+Q on a path does not create another file'

    [Windows.Forms.Clipboard]::SetText('plain copied text')
    Send-TestConversionHotkey
    Start-Sleep -Milliseconds 250
    Assert ([Windows.Forms.Clipboard]::GetText() -eq 'plain copied text') 'Ctrl+Alt+Q on ordinary text leaves it unchanged'
    $files=New-Object Collections.Specialized.StringCollection
    [void]$files.Add($path)
    [Windows.Forms.Clipboard]::SetFileDropList($files)
    Send-TestConversionHotkey
    Start-Sleep -Milliseconds 250
    Assert ([Windows.Forms.Clipboard]::ContainsFileDropList()) 'Ctrl+Alt+Q on copied files leaves them unchanged'

    Set-TestImage
    Start-Sleep -Milliseconds 250
    Assert ([Windows.Forms.Clipboard]::ContainsImage() -and [IO.File]::Exists($path)) 'following screenshots remain images until another Ctrl+Alt+Q press'
    $available=[CodexClipboardTest.Keyboard]::RegisterHotKey([IntPtr]::Zero,20982,16387,81)
    if ($available) { [void][CodexClipboardTest.Keyboard]::UnregisterHotKey([IntPtr]::Zero,20982) }
    Assert (-not $available) 'watcher owns actual Windows Ctrl+Alt+Q hotkey registration'

    Stop-CodexClipboardSession -Session $session
    Wait-Until { $null -eq (Get-CodexClipboardWatcher -ProjectRoot $testRoot) } 'watcher did not stop'
    Wait-Until { [CodexClipboardTest.Keyboard]::RegisterHotKey([IntPtr]::Zero,20982,16387,81) } 'hotkey was not released on final CLI exit'
    [void][CodexClipboardTest.Keyboard]::UnregisterHotKey([IntPtr]::Zero,20982)
    Assert ($true) 'final CLI exit releases Ctrl+Alt+Q'
    Write-Output "HOTKEY: $script:passed assertions passed."
} finally {
    if ($null -ne $session) {
        Stop-CodexClipboardSession -Session $session
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $testRoot) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 60 }
    }
    if ($null -ne $original) { [Windows.Forms.Clipboard]::SetDataObject($original,$true) }
    else { [Windows.Forms.Clipboard]::Clear() }
}
