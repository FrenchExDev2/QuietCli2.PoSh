#requires -Version 7.6
#requires -PSEdition Core
# Objectif : Installer des versions vérifiées d'act et actionlint dans un cache Linux privé au projet.
[CmdletBinding()]
param([string]$Destination = (Join-Path $PSScriptRoot '../.local-ci/tools'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!$IsLinux -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'Local CI tools require Linux x64. Run Invoke-LocalCI.ps1 to use its Linux container transport.'
}
$destination = [IO.Path]::GetFullPath($Destination)
$specifications = @(
    @{
        Name = 'act'; Version = '0.2.91'
        URL = 'https://github.com/nektos/act/releases/download/v0.2.91/act_Linux_x86_64.tar.gz'
        ArchiveSHA256 = 'b25a2876f2dfd5ae7a57c057b25ad666456fb4b31603d1f5b4c69bb68ad96fef'
        BinarySHA256 = '03633e862b6d50cac3943c05e8d972e4d03ded7fbbb7757004fd48688a95943a'
    },
    @{
        Name = 'actionlint'; Version = '1.7.12'
        URL = 'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz'
        ArchiveSHA256 = '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'
        BinarySHA256 = 'c872d6db8c6bf83a8eaa704fc93999f027d55dffbc63b8a6abdccb47df5f4cd4'
    }
)
$installed = @{}
foreach ($specification in $specifications) {
    $directory = Join-Path $destination ($specification.Name + '/' + $specification.Version)
    $binary = Join-Path $directory $specification.Name
    if (Test-Path -LiteralPath $binary) {
        if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ine $specification.BinarySHA256) {
            throw "Cached $($specification.Name) checksum mismatch: $binary. Review this file before replacing it."
        }
    } else {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('quietcli-tool-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($temporary)
        try {
            $archive = Join-Path $temporary 'tool.tar.gz'
            # Objectif : Télécharger une archive officielle sans exécuter d'installateur distant.
            Invoke-WebRequest -Uri $specification.URL -OutFile $archive -TimeoutSec 120 -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $specification.ArchiveSHA256) {
                throw "Downloaded $($specification.Name) archive checksum mismatch."
            }
            $extracted = Join-Path $temporary 'extracted'
            [void][IO.Directory]::CreateDirectory($extracted)
            $stream = [IO.File]::OpenRead($archive)
            $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
            # Objectif : Extraire seulement une archive vérifiée et contrôler aussi son exécutable.
            try { [System.Formats.Tar.TarFile]::ExtractToDirectory($gzip, $extracted, $false) }
            finally { $gzip.Dispose(); $stream.Dispose() }
            $candidate = Join-Path $extracted $specification.Name
            if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $specification.BinarySHA256) {
                throw "Extracted $($specification.Name) executable checksum mismatch."
            }
            [void][IO.Directory]::CreateDirectory($directory)
            Copy-Item -LiteralPath $candidate -Destination $binary -ErrorAction Stop
            [IO.File]::SetUnixFileMode($binary, [IO.UnixFileMode]493)
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }
    $installed[$specification.Name] = [pscustomobject]@{
        Path = $binary; Version = $specification.Version
        ArchiveSHA256 = $specification.ArchiveSHA256; BinarySHA256 = $specification.BinarySHA256
    }
}
[pscustomobject]$installed
