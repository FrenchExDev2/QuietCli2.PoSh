#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Tag
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Release package creation is reserved for the GitHub Actions workflow.' }
Import-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion 1.2.0 -ErrorAction Stop
$archivePath = [IO.Path]::GetFullPath($ArchivePath)
$manifestPath = [IO.Path]::GetFullPath($ManifestPath)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $manifest.ArchiveSHA256) {
    throw 'Archive SHA256 mismatch.'
}
if ($manifest.SourceRef -cne $Tag) { throw 'Archive source tag does not match the release tag.' }
[void][IO.Directory]::CreateDirectory($output)
$archiveReport = Join-Path $output 'archive-verification.json'
$null = & (Join-Path $PSScriptRoot 'Verify-QuietCliArchive.ps1') -ArchivePath $archivePath -OutputPath $archiveReport
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('quietcli-package-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporary)
    $extracted = Join-Path $temporary 'QuietCli'
    $embedded = Get-Content -LiteralPath (Join-Path $extracted 'package-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($field in @('SchemaVersion', 'ModuleVersion', 'Repository', 'ModulePath', 'SourceRef', 'SourceCommitBase', 'SourceKind')) {
        if ([string]$manifest[$field] -cne [string]$embedded[$field]) { throw "Archive provenance mismatch: $field" }
    }
    $expected = @($manifest.Files | ForEach-Object { $_.Path + ':' + $_.SHA256 } | Sort-Object)
    $actual = @($embedded.Files | ForEach-Object { $_.Path + ':' + $_.SHA256 } | Sort-Object)
    if (Compare-Object $expected $actual) { throw 'Archive file inventories do not match.' }
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $expectedEntries = @('QuietCli/package-manifest.json') + @($embedded.Files | ForEach-Object { 'QuietCli/' + $_.Path })
        $actualEntries = @($zip.Entries | ForEach-Object FullName)
        if ($expectedEntries.Count -ne $actualEntries.Count -or (Compare-Object $expectedEntries $actualEntries)) {
            throw 'Archive contains files outside its verified inventory.'
        }
    } finally { $zip.Dispose() }
    $release = & (Join-Path $PSScriptRoot 'Test-QuietCliRelease.ps1') -ModuleRoot $extracted -Tag $Tag
    $staging = Join-Path $temporary $release.Name
    Move-Item -LiteralPath $extracted -Destination $staging
    $packagePath = Join-Path $output ($release.Name + '.' + $release.Version + '.nupkg')
    if (Test-Path -LiteralPath $packagePath) { throw "Package output already exists: $packagePath" }
    Compress-PSResource -Path $staging -DestinationPath $output -ErrorAction Stop
    if (!(Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw 'PSResourceGet did not create the expected package.' }
    # PSResourceGet omits nested .nuspec files. Restore every declared payload file,
    # including third-party metadata, before verifying and hashing the final package.
    $package = [IO.Compression.ZipFile]::Open($packagePath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($relative in (@($embedded.Files.Path) + @('package-manifest.json'))) {
            if ($null -eq $package.GetEntry($relative)) {
                $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($package, (Join-Path $staging $relative), $relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            }
        }
    } finally { $package.Dispose() }
    $packageReport = Join-Path $output 'package-verification.json'
    $null = & (Join-Path $PSScriptRoot 'Verify-QuietCliArchive.ps1') -ArchivePath $packagePath -ModuleDirectory '.' -OutputPath $packageReport
    $manifest['PackageFile'] = Split-Path -Leaf $packagePath
    $manifest['PackageSHA256'] = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    [pscustomobject]@{
        Outcome = 'Success'
        Data = @{ Package = $packagePath; SHA256 = $manifest.PackageSHA256; ModuleVersion = $release.Version; Files = $embedded.Files.Count }
    } | ConvertTo-Json -Depth 4 -Compress
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
