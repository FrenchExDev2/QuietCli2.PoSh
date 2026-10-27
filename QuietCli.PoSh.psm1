<#
.SYNOPSIS
Load the QuietCli companion-script module.
.DESCRIPTION
Reuse the implementation under src and expose its public commands through the workspace module entry point.
#>

#requires -Version 7.4
#requires -PSEdition Core

$ErrorActionPreference='Stop'
$implementation=Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot 'src/QuietCli.psd1') -PassThru -DisableNameChecking -ErrorAction Stop
Export-ModuleMember -Function @($implementation.ExportedFunctions.Keys)
