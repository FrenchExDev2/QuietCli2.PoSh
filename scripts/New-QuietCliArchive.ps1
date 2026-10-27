#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param(
    [string]$ModuleRoot = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory = '',
    [string]$SourceCommitBase = '',
    [string]$SourceRef = 'develop'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ModuleRoot)
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'downloads' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$version = (Import-PowerShellDataFile (Join-Path $root 'QuietCli.PoSh.psd1')).ModuleVersion
$paths = [Collections.Generic.List[string]]::new()
foreach ($name in @('QuietCli.PoSh.psd1', 'QuietCli.PoSh.psm1', 'README.md')) {
    if (!(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { throw "Missing package file: $name" }
    $paths.Add($name)
}
foreach ($folder in @('src', 'examples', 'fixtures', 'skills', 'test', 'scripts', 'verification')) {
    Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -File |
        Where-Object { $_.Extension -ne '.pyc' -and $_.Name -ne 'distribution.json' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]' } |
        ForEach-Object { $paths.Add([IO.Path]::GetRelativePath($root, $_.FullName).Replace([char]92, [char]47)) }
}
# The distribution report stays outside the ZIP to avoid a circular archive hash.
$files = @($paths | Sort-Object | ForEach-Object {
    [ordered]@{ Path = $_; SHA256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$manifest = [ordered]@{
    SchemaVersion = 1
    ModuleVersion = $version
    Repository = 'https://github.com/FrenchExDev/FrenchExDev'
    ModulePath = 'PoSh/FrenchExDev/FrenchExDev.QuietCli.PoSh'
    SourceRef = $SourceRef
    SourceCommitBase = $SourceCommitBase
    SourceKind = 'WorkingTreeFiles; identify the packaged contents by their SHA256 hashes'
    Files = $files
}
$manifestJson = $manifest | ConvertTo-Json -Depth 6
[void](New-Item -ItemType Directory -Path $output -Force)
$archivePath = Join-Path $output 'QuietCli.zip'
$stream = [IO.File]::Open($archivePath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
$zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($file in $files) {
        $entry = $zip.CreateEntry(('QuietCli/' + $file.Path), [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $destination = $entry.Open()
        $source = [IO.File]::OpenRead((Join-Path $root $file.Path))
        try { $source.CopyTo($destination) } finally { $source.Dispose(); $destination.Dispose() }
    }
    $entry = $zip.CreateEntry('QuietCli/package-manifest.json', [IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $destination = $entry.Open()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($manifestJson)
        $destination.Write($bytes, 0, $bytes.Length)
    } finally { $destination.Dispose() }
} finally { $zip.Dispose(); $stream.Dispose() }
$manifest['ArchiveSHA256'] = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'QuietCli.manifest.json') -Encoding utf8
[pscustomobject]@{
    Outcome = 'Success'
    Data = @{ Archive = $archivePath; Files = $files.Count; Bytes = (Get-Item -LiteralPath $archivePath).Length; SHA256 = $manifest.ArchiveSHA256 }
} | ConvertTo-Json -Depth 4 -Compress
