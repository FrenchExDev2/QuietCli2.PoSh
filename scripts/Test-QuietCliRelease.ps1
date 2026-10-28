#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param(
    [string]$ModuleRoot = (Join-Path $PSScriptRoot '..'),
    [Parameter(Mandatory)][string]$Tag
)
$ErrorActionPreference = 'Stop'
if ($Tag -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'Release tags must use the stable vX.Y.Z format, for example v2.0.0.'
}
$version = $Tag.Substring(1)
foreach ($relative in @('FrenchExDev.QuietCli.PoSh.psd1', 'src/QuietCli.psd1')) {
    $path = Join-Path $ModuleRoot $relative
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release manifest: $relative" }
    $manifest = Import-PowerShellDataFile -LiteralPath $path
    if ([string]$manifest.ModuleVersion -cne $version) {
        throw "Tag/version mismatch: $Tag requires $version in $relative; found $($manifest.ModuleVersion)."
    }
    if ($manifest.PrivateData.PSData.Prerelease) { throw "Stable release tags cannot publish a prerelease manifest: $relative" }
    $null = Test-ModuleManifest -Path $path -ErrorAction Stop
}
[pscustomobject]@{ Name = 'FrenchExDev.QuietCli.PoSh'; Version = $version; Tag = $Tag }
