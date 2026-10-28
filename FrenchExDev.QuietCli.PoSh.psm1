#requires -Version 7.6
#requires -PSEdition Core
$implementation=Import-Module (Join-Path $PSScriptRoot 'src/QuietCli.psd1') -PassThru -DisableNameChecking -ErrorAction Stop
Export-ModuleMember -Function @($implementation.ExportedFunctions.Keys)
