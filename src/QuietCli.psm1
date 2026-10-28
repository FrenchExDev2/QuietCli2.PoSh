#requires -Version 7.6
#requires -PSEdition Core
$ErrorActionPreference='Stop'
$script:QuietRoot=Split-Path -Parent $PSScriptRoot
if(!('QuietCliStack.V2.NativeSession' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'NativeSession.cs') -ErrorAction Stop}
if(!('QuietCliStack.GainV2.Database' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'GainStore.cs') -ErrorAction Stop}
$rid=[Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
[QuietCliStack.GainV2.Database]::NativeDirectory=Join-Path $script:QuietRoot "resources/runtime/runtimes/$rid/native"
foreach($part in @('Configuration','Result','Execution','Contract','CommandLine','Record','Module','Gain','Agent')){. (Join-Path $PSScriptRoot "$part.ps1")}
Export-ModuleMember -Function @('New-QuietResult','Invoke-QuietCli','Invoke-QuietTask','Invoke-QuietStep','ConvertTo-QuietJson','QuietCliGain','Out-QuietResult','New-QuietContract','Register-QuietCommand','Resolve-QuietCommand','quiet','pump','Get-QuietRecord','Invoke-QuietRecord','New-QuietModule','Test-QuietModule','Install-QuietModule','Get-QuietConfiguration','Register-QuietObfuscator','Register-QuietTokenizer','Measure-QuietToken','Get-QuietAudit','Measure-QuietContract','Get-QuietAgentInstruction','Invoke-QuietHook','Install-QuietHook','Uninstall-QuietHook','Get-QuietSession','Limit-QuietProjection')
