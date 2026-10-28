#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([string]$QuietCliRoot=(Join-Path $PSScriptRoot '..'),[string]$ReportPath=(Join-Path $PSScriptRoot '../verification/v2-examples.json'))
& (Join-Path $QuietCliRoot 'test/Invoke-Tests.ps1') -OutputPath $ReportPath
if($LASTEXITCODE){exit $LASTEXITCODE}