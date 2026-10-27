@{
    RootModule = 'QuietCli.PoSh.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'c6792b32-6a6c-4f4e-a311-17bf9c5b33ed'
    Author = 'Stéphane Erard'
    CompanyName = 'FrenchExDev'
    Description = 'Companion scripts that reduce native CLI output into bounded structured results.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'New-QuietResult'
        'Invoke-QuietCli'
        'Invoke-QuietTask'
        'Invoke-QuietStep'
        'ConvertTo-QuietJson'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('QuietCli','CLI','Companion','PowerShell7')
        }
    }
}
