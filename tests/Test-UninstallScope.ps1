$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runRoot=Join-Path $root ('tests\runs\uninstall-scope-'+[guid]::NewGuid().ToString('N'))
$tool=Join-Path $runRoot 'tool'
[void][IO.Directory]::CreateDirectory($tool)
foreach ($name in @('Uninstall.ps1','Install.ps1','ProfileTools.ps1','CodexClipboard.psm1','Hook.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $tool $name)
}
$profiles=Join-Path $runRoot 'profiles'
[void][IO.Directory]::CreateDirectory($profiles)
$profile=Join-Path $profiles 'custom-profile.ps1'
$original='# existing custom profile'+[Environment]::NewLine
[IO.File]::WriteAllText($profile,$original)
$leases=Join-Path $tool '.state\sessions'
[void][IO.Directory]::CreateDirectory($leases)
$lease=Join-Path $leases ('session-'+[guid]::NewGuid().ToString('N')+'.lease')
[IO.File]::WriteAllText($lease,([string]$PID+[Environment]::NewLine+[string][Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks))
& (Join-Path $tool 'Install.ps1') -ProfilePaths @($profile) | Out-Null
& (Join-Path $tool 'Uninstall.ps1') -ProfilePaths @($profile) | Out-Null
if (-not [IO.File]::Exists($lease)) { throw 'FAIL: uninstalling a custom profile must preserve existing CLI session registrations.' }
Write-Output 'PASS: custom-profile uninstall preserves existing CLI session registrations'
if ([IO.File]::ReadAllText($profile) -ne $original) { throw 'FAIL: custom profile was not restored.' }
Write-Output 'PASS: custom-profile uninstall still restores original profile content'
Import-Module (Join-Path $tool 'CodexClipboard.psm1') -ArgumentList $tool -Force
if ((Get-CodexClipboardSessionCount -ProjectRoot $tool) -ne 1) { throw 'FAIL: preserved session is not live.' }
Write-Output 'PASS: preserved session remains valid for the original live owner'
Write-Output 'UNINSTALL SCOPE: 3 assertions passed.'
