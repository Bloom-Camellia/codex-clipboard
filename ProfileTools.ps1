function Get-CodexClipboardAnsiEncoding {
    if (-not ('CodexClipboard.ProfileEncoding' -as [type])) {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; namespace CodexClipboard { public static class ProfileEncoding { [DllImport("kernel32.dll")] public static extern uint GetACP(); } }'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    }
    return [Text.Encoding]::GetEncoding([int][CodexClipboard.ProfileEncoding]::GetACP())
}

function Get-DefaultCodexClipboardProfiles {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    return @((Join-Path $documents 'WindowsPowerShell\profile.ps1'),(Join-Path $documents 'PowerShell\profile.ps1'))
}
function Read-CodexClipboardProfile($path) {
    $encoding = [Text.UTF8Encoding]::new($true)
    $preamble = $encoding.GetPreamble()
    $text = ''
    if ([IO.File]::Exists($path)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $skip = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            $encoding = [Text.UTF8Encoding]::new($true); $skip=3
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
            $encoding = [Text.Encoding]::Unicode; $skip=2
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
            $encoding = [Text.Encoding]::BigEndianUnicode; $skip=2
        } else {
            try {
                $strictUtf8 = [Text.UTF8Encoding]::new($false,$true)
                [void]$strictUtf8.GetString($bytes)
                $encoding = [Text.UTF8Encoding]::new($false)
            } catch [Text.DecoderFallbackException] {
                $encoding = Get-CodexClipboardAnsiEncoding
            }
        }
        $preamble = $encoding.GetPreamble()
        $text = $encoding.GetString($bytes,$skip,$bytes.Length-$skip)
    }
    return [pscustomobject]@{Text=$text;Encoding=$encoding;Preamble=$preamble}
}
function Write-CodexClipboardProfile($path,$text,$original) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    if ([IO.File]::Exists($path)) {
        $backup = $path+'.codex-clipboard-backup-'+[DateTime]::UtcNow.Ticks
        [IO.File]::Copy($path,$backup,$false)
    }
    [byte[]]$bytes = $original.Preamble + $original.Encoding.GetBytes($text)
    $temporary = $path+'.codex-clipboard-tmp-'+[guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporary,$bytes)
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
function Remove-CodexClipboardProfileBlock($text) {
    return [regex]::Replace($text,'(?ms)\r?\n# BEGIN CODEX CLIPBOARD\r?\n.*?^# END CODEX CLIPBOARD\r?\n?','')
}
