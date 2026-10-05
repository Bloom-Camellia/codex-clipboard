$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'ClipboardEngine.cs'
if (-not (Test-Path -LiteralPath $engine)) { throw 'FAIL: Clipboard conversion and retention engine has not been implemented.' }
Add-Type -Path $engine -ReferencedAssemblies System.Windows.Forms,System.Drawing
$testRoot = Join-Path $root ('tests\runs\core-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$originalClipboard = [Windows.Forms.Clipboard]::GetDataObject()
$script:passed = 0
function Assert($condition, $message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
function Set-TestImage {
    $bitmap = New-Object Drawing.Bitmap 2,3
    $bitmap.SetPixel(0,0,[Drawing.Color]::Red)
    [Windows.Forms.Clipboard]::SetImage($bitmap)
    $bitmap.Dispose()
}
function New-Fixture($directory, $number) {
    $name = 'codex-shot-' + $number.ToString('D19') + '-0123456789abcdef0123456789abcdef.png'
    $path = Join-Path $directory $name
    [IO.File]::WriteAllText($path, 'fixture')
    return $path
}
try {
    $images = Join-Path $testRoot 'images'
    Set-TestImage
    $sequence = [CodexClipboard.Native]::Sequence
    $result = [CodexClipboard.Engine]::Capture($images,30,$sequence)
    Assert ($null -ne $result -and $result.ClipboardReplaced) 'new image becomes plain absolute path'
    Assert ([Windows.Forms.Clipboard]::GetText() -eq $result.SavedPath) 'clipboard contains only PNG path'
    Assert ([IO.Path]::IsPathRooted($result.SavedPath) -and [IO.File]::Exists($result.SavedPath)) 'path points to existing absolute PNG'
    $saved = [Drawing.Image]::FromFile($result.SavedPath)
    try {
        Assert ($saved.Width -eq 2 -and $saved.Height -eq 3 -and $saved.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Red.ToArgb()) 'saved PNG preserves dimensions and pixels'
    } finally { $saved.Dispose() }
    $again = [CodexClipboard.Engine]::Capture($images,30,[CodexClipboard.Native]::Sequence)
    Assert ($null -eq $again -and @(Get-ChildItem -LiteralPath $images -Filter '*.png').Count -eq 1) 'path clipboard event does not save twice'

    [Windows.Forms.Clipboard]::SetText('ordinary copied text')
    $textResult = [CodexClipboard.Engine]::Capture($images,30,[CodexClipboard.Native]::Sequence)
    Assert ($null -eq $textResult -and [Windows.Forms.Clipboard]::GetText() -eq 'ordinary copied text') 'ordinary copied text stays unchanged'
    $files = New-Object Collections.Specialized.StringCollection
    [void]$files.Add($result.SavedPath)
    [Windows.Forms.Clipboard]::SetFileDropList($files)
    $fileResult = [CodexClipboard.Engine]::Capture($images,30,[CodexClipboard.Native]::Sequence)
    Assert ($null -eq $fileResult -and [Windows.Forms.Clipboard]::ContainsFileDropList()) 'copied files stay unchanged'

    Set-TestImage
    $oldSequence = [CodexClipboard.Native]::Sequence
    [Windows.Forms.Clipboard]::SetText('newer clipboard content')
    $stale = [CodexClipboard.Engine]::Capture($images,30,$oldSequence)
    Assert ($null -eq $stale -and [Windows.Forms.Clipboard]::GetText() -eq 'newer clipboard content') 'stale capture does not overwrite newer copied content'

    $blocked = Join-Path $testRoot 'not-a-directory'
    [IO.File]::WriteAllText($blocked,'block')
    Set-TestImage
    $failed = $false
    try { [void][CodexClipboard.Engine]::Capture($blocked,30,[CodexClipboard.Native]::Sequence) } catch { $failed = $true }
    Assert ($failed -and [Windows.Forms.Clipboard]::ContainsImage()) 'save failure preserves clipboard image'
    Assert (@(Get-ChildItem -LiteralPath $images -Filter '*.png').Count -eq 1) 'save failure does not clear historical files'

    $retention = Join-Path $testRoot 'retention'
    [IO.Directory]::CreateDirectory($retention) | Out-Null
    $fixturePaths = @(1..31 | ForEach-Object { New-Fixture $retention $_ })
    $unrelated = Join-Path $retention 'personal.png'
    [IO.File]::WriteAllText($unrelated,'keep')
    $nested = Join-Path $retention 'nested'
    [IO.Directory]::CreateDirectory($nested) | Out-Null
    $nestedFile = New-Fixture $nested 0
    [void][CodexClipboard.Engine]::Cleanup($retention,30)
    Assert (-not [IO.File]::Exists($fixturePaths[0]) -and [IO.File]::Exists($fixturePaths[1]) -and [IO.File]::Exists($fixturePaths[30])) '31 images remove the earliest and keep the newest'
    Assert (@(Get-ChildItem -LiteralPath $retention -Filter 'codex-shot-*.png').Count -eq 30) 'retention leaves exactly 30 generated images'
    Assert ([IO.File]::Exists($unrelated) -and [IO.File]::Exists($nestedFile)) 'retention preserves unrelated files and subdirectories'

    $lockedDir = Join-Path $testRoot 'locked'
    [IO.Directory]::CreateDirectory($lockedDir) | Out-Null
    $lockedPaths = @(1..31 | ForEach-Object { New-Fixture $lockedDir $_ })
    $lock = [IO.File]::Open($lockedPaths[0],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        $remaining = [CodexClipboard.Engine]::Cleanup($lockedDir,30)
        Assert ($remaining -eq 31 -and [IO.File]::Exists($lockedPaths[1])) 'locked oldest file does not cause newer images to be deleted'
    } finally { $lock.Dispose() }
    $remaining = [CodexClipboard.Engine]::Cleanup($lockedDir,30)
    Assert ($remaining -eq 30 -and -not [IO.File]::Exists($lockedPaths[0])) 'locked excess is removed on a later retry'

    Write-Output "CORE: $script:passed assertions passed."
} finally {
    if ($null -ne $originalClipboard) { [Windows.Forms.Clipboard]::SetDataObject($originalClipboard,$true) }
    else { [Windows.Forms.Clipboard]::Clear() }
}
