#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,[int]$MaxOutputBytes=2048,[switch]$Record)
Import-Module (Join-Path $PSScriptRoot '../FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking -ErrorAction Stop
$r=quiet -AsObject -Record:$Record -WorkingDirectory $Repository -ContractPath (Join-Path $PSScriptRoot 'contracts/Git.Status.ps1') git status
$r|Out-QuietResult -MaxOutputBytes $MaxOutputBytes
