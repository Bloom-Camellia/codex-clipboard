$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'Install.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw 'FAIL: Profile installer and uninstaller have not been implemented.' }
$testRoot = Join-Path $root ('tests\runs\install-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$profile = Join-Path $testRoot 'profile.ps1'
$original = '$global:ExistingMarker = "unchanged"'+[Environment]::NewLine+'# Existing configuration / 原有配置'+[Environment]::NewLine
[IO.File]::WriteAllText($profile,$original,[Text.UTF8Encoding]::new($true))
$script:passed = 0
function Assert($condition,$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
& $installer -ProfilePaths @($profile) | Out-Null
$installed = [IO.File]::ReadAllText($profile)
Assert ($installed.StartsWith($original)) 'installer preserves original profile content'
Assert (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.codex-clipboard-backup-*').Count -eq 1) 'installer creates backup before changing an existing profile'
& $installer -ProfilePaths @($profile) | Out-Null
Assert ([IO.File]::ReadAllText($profile) -eq $installed) 'repeated installation is idempotent'
. $profile
Assert ($global:ExistingMarker -eq 'unchanged' -and (Get-Command codex).CommandType -eq 'Function') 'installed profile loads existing settings and codex wrapper with a spaced project path'
& (Join-Path $root 'Uninstall.ps1') -ProfilePaths @($profile) | Out-Null
Assert ([IO.File]::ReadAllText($profile) -eq $original) 'uninstall restores original content'
& (Join-Path $root 'Uninstall.ps1') -ProfilePaths @($profile) | Out-Null
Assert ([IO.File]::ReadAllText($profile) -eq $original) 'repeated uninstall leaves original profile unchanged'

$unicodeProfile = Join-Path $testRoot 'unicode-profile.ps1'
[IO.File]::WriteAllText($unicodeProfile,$original,[Text.Encoding]::Unicode)
$beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($unicodeProfile))
& $installer -ProfilePaths @($unicodeProfile) | Out-Null
& (Join-Path $root 'Uninstall.ps1') -ProfilePaths @($unicodeProfile) | Out-Null
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($unicodeProfile)) -eq $beforeBytes) 'install and uninstall preserve UTF-16 profile bytes'


$ansiProfile = Join-Path $testRoot 'ansi-profile.ps1'
$ansiText = '$global:AnsiMarker = "原有配置 café"'+[Environment]::NewLine
$ansiEncoding = [Text.Encoding]::Default
[IO.File]::WriteAllText($ansiProfile,$ansiText,$ansiEncoding)
$ansiBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ansiProfile))
& $installer -ProfilePaths @($ansiProfile) | Out-Null
$ansiAfter = $ansiEncoding.GetString([IO.File]::ReadAllBytes($ansiProfile))
Assert ($ansiAfter.StartsWith($ansiText)) 'installer preserves existing ANSI profile characters'
& (Join-Path $root 'Uninstall.ps1') -ProfilePaths @($ansiProfile) | Out-Null
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ansiProfile)) -eq $ansiBytes) 'uninstall restores exact ANSI profile bytes'


$powerShell7 = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -ne $powerShell7) {
    & $powerShell7.Source -NoProfile -File $installer -ProfilePaths $ansiProfile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell 7 installer failed.' }
    Assert ($ansiEncoding.GetString([IO.File]::ReadAllBytes($ansiProfile)).StartsWith($ansiText)) 'PowerShell 7 installer preserves existing system ANSI profile'
    & $powerShell7.Source -NoProfile -File (Join-Path $root 'Uninstall.ps1') -ProfilePaths $ansiProfile | Out-Null
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ansiProfile)) -eq $ansiBytes) 'PowerShell 7 uninstall restores exact ANSI bytes'
}

$absentProfile = Join-Path $testRoot 'new-directory\profile.ps1'
& $installer -ProfilePaths @($absentProfile) | Out-Null
Assert ([IO.File]::Exists($absentProfile)) 'installer creates missing profile directories and files'
Write-Output "INSTALL: $script:passed assertions passed."
