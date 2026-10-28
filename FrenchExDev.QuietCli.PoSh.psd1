@{
    RootModule = 'FrenchExDev.QuietCli.PoSh.psm1'
    ModuleVersion = '0.0.1'
    GUID = 'c6792b32-6a6c-4f4e-a311-17bf9c5b33ed'
    Author = 'Stéphane Erard'
    CompanyName = 'FrenchExDev'
    Copyright = '(c) 2026 Stéphane Erard. MIT License.'
    Description = 'Companion scripts that reduce native CLI output into bounded structured results.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-QuietResult','Invoke-QuietCli','Invoke-QuietTask','Invoke-QuietStep','ConvertTo-QuietJson','QuietCliGain','Out-QuietResult','New-QuietContract','Register-QuietCommand','Resolve-QuietCommand','quiet','pump','Get-QuietRecord','Invoke-QuietRecord','New-QuietModule','Test-QuietModule','Install-QuietModule','Get-QuietConfiguration','Register-QuietObfuscator','Register-QuietTokenizer','Measure-QuietToken','Get-QuietAudit','Measure-QuietContract','Get-QuietAgentInstruction','Invoke-QuietHook','Install-QuietHook','Uninstall-QuietHook','Get-QuietSession','Limit-QuietProjection')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('QuietCli','CLI','Companion','PowerShell7')
            LicenseUri = 'https://github.com/FrenchExDev2/QuietCli2.PoSh/blob/develop/LICENSE'
            ProjectUri = 'https://github.com/FrenchExDev2/QuietCli2.PoSh'
        }
    }
}
