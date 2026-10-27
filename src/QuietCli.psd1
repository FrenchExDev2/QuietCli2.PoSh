@{
    RootModule = 'QuietCli.psm1'
    ModuleVersion = '0.2.0'
    GUID = '00f8c051-c3c6-47c3-9ee0-2f595d73578c'
    Author = 'Stéphane Érard / AI-assisted prototype'
    Description = 'Companion scripts that reduce native CLI output into bounded structured results.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-QuietResult','Invoke-QuietCli','Invoke-QuietTask','Invoke-QuietStep','ConvertTo-QuietJson','QuietCliGain')
    CmdletsToExport = @()
    AliasesToExport = @()
}
