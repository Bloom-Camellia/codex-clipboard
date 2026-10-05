param([string[]]$ProfilePaths)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProfileTools.ps1')
$defaultProfiles=@(Get-DefaultCodexClipboardProfiles | ForEach-Object { [IO.Path]::GetFullPath($_) })
if (-not $ProfilePaths -or $ProfilePaths.Count -eq 0) { $ProfilePaths=$defaultProfiles }
$stopActualWatcher=$false
foreach ($profilePath in $ProfilePaths) {
    $profilePath=[IO.Path]::GetFullPath($profilePath)
    if ($defaultProfiles -contains $profilePath) { $stopActualWatcher=$true }
    if (-not [IO.File]::Exists($profilePath)) { continue }
    $original=Read-CodexClipboardProfile $profilePath
    $updated=Remove-CodexClipboardProfileBlock $original.Text
    if ($updated -ne $original.Text) {
        Write-CodexClipboardProfile $profilePath $updated $original
        Write-Output "Removed integration: $profilePath"
    }
}
if ($stopActualWatcher) {
    Import-Module (Join-Path $PSScriptRoot 'CodexClipboard.psm1') -Force
    $sessionDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.state\sessions'))
    if ([IO.Directory]::Exists($sessionDirectory)) {
        foreach ($lease in @(Get-ChildItem -LiteralPath $sessionDirectory -Filter 'session-*.lease' -File)) {
            if ($lease.Name -match '^session-[a-f0-9]{32}\.lease$' -and $lease.DirectoryName -eq $sessionDirectory) {
                Remove-Item -LiteralPath $lease.FullName -Force
            }
        }
    }
    Remove-Module CodexClipboard -ErrorAction SilentlyContinue
    Write-Output 'Uninstalled. Screenshots and profile backups are preserved. Existing watcher sessions will stop.'
} else {
    Write-Output 'Custom profile integration removed. Active watcher sessions, screenshots and profile backups are preserved.'
}
