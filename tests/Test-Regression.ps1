param([ValidateSet('Clock','Contention','Shutdown','All')][string]$Case='All')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'HotkeyTestTools.ps1')
$root=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root 'ClipboardEngine.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
$runRoot=Join-Path $root ('tests\runs\regression-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$originalClipboard=[Windows.Forms.Clipboard]::GetDataObject()
$script:passed=0
function Assert($condition,$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
$helperSource = 'using System; using System.IO; using System.Threading; using System.Runtime.InteropServices;
public class ClipboardLockProbe {
[DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hwnd);
[DllImport("user32.dll")] static extern bool CloseClipboard();
public static bool Locked;
public static Thread HoldDuringSave(string directory) {
 Locked=false; Thread thread=new Thread(delegate() {
  DateTime deadline=DateTime.UtcNow.AddSeconds(5);
  while(DateTime.UtcNow<deadline) {
   if(Directory.GetFiles(directory,"*.partial").Length>0 && OpenClipboard(IntPtr.Zero)) {
    Locked=true; Thread.Sleep(600); CloseClipboard(); return;
   }
   Thread.Sleep(1);
  }
 }); thread.Start(); return thread;
}}'
try {
    if ($Case -eq 'Clock' -or $Case -eq 'All') {
        $directory=Join-Path $runRoot 'clock'
        [void][IO.Directory]::CreateDirectory($directory)
        foreach ($n in 1..30) {
            $ticks=9000000000000000000L+$n
            [IO.File]::WriteAllText((Join-Path $directory ('codex-shot-'+$ticks.ToString('D19')+'-0123456789abcdef0123456789abcdef.png')),'fixture')
        }
        $bitmap=New-Object Drawing.Bitmap 2,2
        try { [Windows.Forms.Clipboard]::SetImage($bitmap) } finally { $bitmap.Dispose() }
        $result=[CodexClipboard.Engine]::Capture($directory,30,[CodexClipboard.Native]::Sequence)
        Assert ([IO.File]::Exists($result.SavedPath)) 'backward clock adjustment cannot delete newly saved screenshot'
        Assert (@(Get-ChildItem -LiteralPath $directory -Filter '*.png').Count -eq 30) 'monotonic retention still keeps 30 files'
    }
    if ($Case -eq 'Contention' -or $Case -eq 'All') {
        Add-Type -TypeDefinition $helperSource
        $directory=Join-Path $runRoot 'contention'
        [void][IO.Directory]::CreateDirectory($directory)
        $bitmap=New-Object Drawing.Bitmap 4096,4096
        try { [Windows.Forms.Clipboard]::SetImage($bitmap) } finally { $bitmap.Dispose() }
        $sequence=[CodexClipboard.Native]::Sequence
        $thread=[ClipboardLockProbe]::HoldDuringSave($directory)
        try {
            $result=$null
            try { $result=[CodexClipboard.Engine]::Capture($directory,30,$sequence) }
            catch { throw ('FAIL: capture must return the saved path when clipboard publication is busy: '+$_.Exception.Message) }
        } finally { [void]$thread.Join(7000) }
        Assert ([ClipboardLockProbe]::Locked -and $null -ne $result -and [IO.File]::Exists($result.SavedPath)) 'saved PNG survives clipboard publication contention'
        [void][CodexClipboard.Native]::ReplaceText($sequence,$result.SavedPath)
        Assert ([Windows.Forms.Clipboard]::GetText() -eq $result.SavedPath -and @(Get-ChildItem -LiteralPath $directory -Filter '*.png').Count -eq 1) 'publication retries reuse one saved image'
    }

    if ($Case -eq 'Contention' -or $Case -eq 'All') {
        $sessionRoot=Join-Path $runRoot 'background-contention'
        [void][IO.Directory]::CreateDirectory($sessionRoot)
        [IO.File]::WriteAllText((Join-Path $sessionRoot 'config.json'),'{"retainCount":30,"pollMilliseconds":60,"screenshotDirectory":"screenshots","hotkey":"Ctrl+Alt+Q"}')
        $backgroundImages=Join-Path $sessionRoot 'screenshots'
        [void][IO.Directory]::CreateDirectory($backgroundImages)
        Import-Module (Join-Path $root 'CodexClipboard.psm1') -ArgumentList $sessionRoot -Force
        $session=Start-CodexClipboardSession -ProjectRoot $sessionRoot
        try {
            $thread=[ClipboardLockProbe]::HoldDuringSave($backgroundImages)
            $bitmap=New-Object Drawing.Bitmap 4096,4096
            try { [Windows.Forms.Clipboard]::SetImage($bitmap) } finally { $bitmap.Dispose() }
            Send-TestConversionHotkey
            [void]$thread.Join(7000)
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while (-not [Windows.Forms.Clipboard]::ContainsText() -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 60 }
            Assert ([ClipboardLockProbe]::Locked -and [Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText().EndsWith('.png')) 'background watcher publishes pending path after clipboard becomes available'
            Assert (@(Get-ChildItem -LiteralPath $backgroundImages -Filter '*.png').Count -eq 1) 'clipboard contention saves only one image in background'
        } finally {
            Stop-CodexClipboardSession -Session $session
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $sessionRoot) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 60 }
        }
    }
    if ($Case -eq 'Shutdown' -or $Case -eq 'All') {
        $sessionRoot=Join-Path $runRoot 'shutdown'
        [void][IO.Directory]::CreateDirectory($sessionRoot)
        [IO.File]::WriteAllText((Join-Path $sessionRoot 'config.json'),'{"retainCount":30,"pollMilliseconds":60,"screenshotDirectory":"screenshots","hotkey":"Ctrl+Alt+Q"}')
        Import-Module (Join-Path $root 'CodexClipboard.psm1') -ArgumentList $sessionRoot -Force
        Assert ($null -ne (Get-Command New-CodexClipboardStateMutex -ErrorAction SilentlyContinue)) 'session registration and watcher shutdown share a state mutex'
        $first=Start-CodexClipboardSession -ProjectRoot $sessionRoot
        $second=$null
        $gate=New-CodexClipboardStateMutex -ProjectRoot $sessionRoot
        [void]$gate.WaitOne()
        try {
            Stop-CodexClipboardSession -Session $first
            Start-Sleep -Milliseconds 1500
            Assert ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $sessionRoot)) 'watcher cannot commit shutdown while registration lock is held'
            $second=Start-CodexClipboardSession -ProjectRoot $sessionRoot
        } finally { $gate.ReleaseMutex();$gate.Dispose() }
        try {
            Start-Sleep -Milliseconds 400
            Assert ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $sessionRoot)) 'new registered CLI retains a live watcher across final-session shutdown'
        } finally {
            if ($null -ne $second) { Stop-CodexClipboardSession -Session $second }
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while ($null -ne (Get-CodexClipboardWatcher -ProjectRoot $sessionRoot) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 60 }
        }
    }
    Write-Output "REGRESSION ($Case): $script:passed assertions passed."
} finally {
    if ($null -ne $originalClipboard) { [Windows.Forms.Clipboard]::SetDataObject($originalClipboard,$true) }
    else { [Windows.Forms.Clipboard]::Clear() }
}
