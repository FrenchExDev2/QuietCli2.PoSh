@{
    RootModule = 'QuietCli.psm1'
    ModuleVersion = '0.0.1'
    GUID = '00f8c051-c3c6-47c3-9ee0-2f595d73578c'
    Author = 'Stéphane Érard / AI-assisted prototype'
    Description = 'Companion scripts that reduce native CLI output into bounded structured results.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-QuietResult','Invoke-QuietCli','Invoke-QuietTask','Invoke-QuietStep','ConvertTo-QuietJson','QuietCliGain','Out-QuietResult','New-QuietContract','Register-QuietCommand','Resolve-QuietCommand','quiet','pump','Get-QuietRecord','Invoke-QuietRecord','New-QuietModule','Test-QuietModule','Install-QuietModule','Get-QuietConfiguration','Register-QuietObfuscator','Register-QuietTokenizer','Measure-QuietToken','Get-QuietAudit','Measure-QuietContract','Get-QuietAgentInstruction','Invoke-QuietHook','Install-QuietHook','Uninstall-QuietHook','Get-QuietSession','Limit-QuietProjection')
    CmdletsToExport = @()
    AliasesToExport = @()
}
