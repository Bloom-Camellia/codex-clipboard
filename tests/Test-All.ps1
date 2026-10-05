$ErrorActionPreference = 'Stop'
foreach ($test in @('Test-Core.ps1','Test-Lifecycle.ps1','Test-Install.ps1','Test-Regression.ps1','Test-Hotkey.ps1','Test-UninstallScope.ps1')) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw "Failed test suite: $test" }
}
Write-Output 'ALL TEST SUITES PASSED.'
