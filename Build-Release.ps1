[CmdletBinding()]
param(
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$')]
    [string]$Version = 'v0.1.0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$packageName = 'codex-clipboard-' + $Version
$packageFiles = @(
    'ClipboardEngine.cs',
    'CodexClipboard.psm1',
    'Watcher.ps1',
    'Hook.ps1',
    'ProfileTools.ps1',
    'Install.ps1',
    'Uninstall.ps1',
    'Status.ps1',
    'config.json',
    'README.md',
    'LICENSE',
    'CHANGELOG.md'
)

# Copy only these project files. Runtime state and screenshots are never enumerated.
foreach ($name in $packageFiles) {
    $source = Join-Path $projectRoot $name
    if (-not [IO.File]::Exists($source)) {
        throw "Required release file is missing: $source"
    }
}

$distRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'dist'))
[void][IO.Directory]::CreateDirectory($distRoot)
if (((Get-Item -LiteralPath $distRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The release output directory must not be a junction or symbolic link.'
}

$temporaryName = '.release-' + [guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path $distRoot $temporaryName
$stagingRoot = Join-Path $temporaryRoot $packageName
$zipName = $packageName + '.zip'
$checksumName = $zipName + '.sha256'
$zipPath = Join-Path $distRoot $zipName
$checksumPath = Join-Path $distRoot $checksumName

try {
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    foreach ($name in $packageFiles) {
        [IO.File]::Copy((Join-Path $projectRoot $name), (Join-Path $stagingRoot $name), $false)
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryZip = Join-Path $temporaryRoot $zipName
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $temporaryZip,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $digest = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $temporaryChecksum = Join-Path $temporaryRoot $checksumName
    [IO.File]::WriteAllText($temporaryChecksum, ($digest + '  ' + $zipName + "`r`n"), [Text.Encoding]::ASCII)

    Move-Item -LiteralPath $temporaryZip -Destination $zipPath -Force
    Move-Item -LiteralPath $temporaryChecksum -Destination $checksumPath -Force
    Write-Output "Created: $zipPath"
    Write-Output "SHA256: $digest"
    Write-Output "Checksum: $checksumPath"
} finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        try {
            # Verify the absolute target before recursively deleting this build's private staging area.
            $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
            $resolvedDistRoot = [IO.Path]::GetFullPath($distRoot).TrimEnd('\', '/')
            $distPrefix = $resolvedDistRoot + [IO.Path]::DirectorySeparatorChar
            if (-not $resolvedTemporaryRoot.StartsWith($distPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([IO.Path]::GetDirectoryName($resolvedTemporaryRoot), $resolvedDistRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($resolvedTemporaryRoot) -ne $temporaryName) {
                throw 'Refusing to clean a temporary directory outside the release output directory.'
            }
            foreach ($directory in @($resolvedDistRoot, $resolvedTemporaryRoot, $stagingRoot)) {
                if ([IO.Directory]::Exists($directory) -and
                    ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Refusing to clean a temporary directory containing a junction or symbolic link.'
                }
            }
            [IO.Directory]::Delete($resolvedTemporaryRoot, $true)
        } catch {
            Write-Warning ("Could not remove the private release staging directory: " + $_.Exception.Message)
        }
    }
}
