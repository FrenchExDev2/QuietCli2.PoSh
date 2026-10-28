#requires -Version 7.6
param([ValidateSet('off','warn','deny','rewrite')][string]$Awareness='warn')
try{
    Import-Module (Join-Path $PSScriptRoot '../FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking -ErrorAction Stop
    $event=[Console]::In.ReadToEnd()|ConvertFrom-Json
    Invoke-QuietHook -Event $event -Awareness $Awareness|ConvertTo-Json -Depth 20 -Compress
}catch{@{hookSpecificOutput=@{hookEventName='PreToolUse';additionalContext='QuietCli hook could not inspect this invocation.'}}|ConvertTo-Json -Depth 10 -Compress}
