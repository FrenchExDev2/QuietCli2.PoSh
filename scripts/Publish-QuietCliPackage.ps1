#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$Tag,
    [string]$ModuleRoot = (Join-Path $PSScriptRoot '..')
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'PSGallery publication is reserved for the GitHub Actions workflow.' }
if ([string]::IsNullOrWhiteSpace($env:PSGALLERY_API_KEY)) { throw 'Configure the PSGALLERY_API_KEY repository secret before publishing.' }
$release = & (Join-Path $PSScriptRoot 'Test-QuietCliRelease.ps1') -ModuleRoot $ModuleRoot -Tag $Tag
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$expectedName = $release.Name + '.' + $release.Version + '.nupkg'
if ((Split-Path -Leaf $PackagePath) -cne $expectedName -or $manifest.PackageFile -cne $expectedName -or $manifest.ModuleVersion -cne $release.Version -or $manifest.SourceRef -cne $Tag) {
    throw 'The package, manifest and release tag must identify the same module version.'
}
if ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -ine $manifest.PackageSHA256) { throw 'Package SHA256 mismatch.' }
$zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($PackagePath))
try {
    $entries = @($zip.Entries | Where-Object { $_.FullName -cmatch '^[^/]+\.nuspec$' })
    if ($entries.Count -ne 1) { throw 'The package must contain exactly one NuGet specification.' }
    $reader = [IO.StreamReader]::new($entries[0].Open())
    try { [xml]$specification = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($specification.package.metadata.id -cne $release.Name -or $specification.package.metadata.version -cne $release.Version) {
        throw 'NuGet identity does not match the release tag.'
    }
} finally { $zip.Dispose() }
Import-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion 1.2.0 -ErrorAction Stop
# An exact v2 feed lookup distinguishes a missing version (404) from network/authentication failures.
$uri = "https://www.powershellgallery.com/api/v2/Packages(Id='$($release.Name)',Version='$($release.Version)')"
$response = Invoke-WebRequest -Uri $uri -SkipHttpErrorCheck -TimeoutSec 60 -MaximumRetryCount 0 -ErrorAction Stop
if ([int]$response.StatusCode -eq 200) { throw "PSGallery version $($release.Version) is already published; use a new version." }
if ([int]$response.StatusCode -ne 404) { throw "PSGallery version lookup failed with HTTP $($response.StatusCode); nothing was published." }
if ($PSCmdlet.ShouldProcess("PSGallery/$($release.Name)/$($release.Version)", 'Publish the verified NuGet package')) {
    Publish-PSResource -NupkgPath ([IO.Path]::GetFullPath($PackagePath)) -Repository PSGallery -ApiKey $env:PSGALLERY_API_KEY -ErrorAction Stop
    [pscustomobject]@{ Outcome = 'Success'; Data = @{ Name = $release.Name; Version = $release.Version; Repository = 'PSGallery' } } | ConvertTo-Json -Compress
}
