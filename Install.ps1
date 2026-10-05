param([string[]]$ProfilePaths)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProfileTools.ps1')
if (-not $ProfilePaths -or $ProfilePaths.Count -eq 0) { $ProfilePaths = Get-DefaultCodexClipboardProfiles }
$hook = (Join-Path $PSScriptRoot 'Hook.ps1').Replace("'","''")
$nl = [Environment]::NewLine
$block = $nl+(@('# BEGIN CODEX CLIPBOARD',"if (Test-Path -LiteralPath '$hook') {","    . '$hook'",'}','# END CODEX CLIPBOARD') -join $nl)+$nl
foreach ($profilePath in $ProfilePaths) {
    $profilePath = [IO.Path]::GetFullPath($profilePath)
    $original = Read-CodexClipboardProfile $profilePath
    $updated = (Remove-CodexClipboardProfileBlock $original.Text)+$block
    if ($updated -eq $original.Text) { Write-Output "Already installed: $profilePath"; continue }
    Write-CodexClipboardProfile $profilePath $updated $original
    Write-Output "Installed: $profilePath"
}
Write-Output 'Open a new PowerShell terminal, then run codex. Or load Hook.ps1 in the current terminal.'
