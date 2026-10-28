#requires -Version 7.6
[CmdletBinding()]
param([string]$OutputPath=(Join-Path $PSScriptRoot '../verification/v2-layout-validation.json'))
$ErrorActionPreference='Stop'
$core=Split-Path -Parent $PSScriptRoot
$ecosystem=Split-Path -Parent $core
$checks=[Collections.Generic.List[object]]::new()
$report=[ordered]@{SchemaVersion=2;ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Scope='QuietCli ecosystem layout and Linux runtime';PowerShell=$PSVersionTable.PSVersion.ToString();Outcome='Running'}
try{
    $runtime=Import-Module (Join-Path $core 'FrenchExDev.QuietCli.PoSh.psd1') -PassThru -DisableNameChecking
    foreach($name in @('quiet','pump')){
        $command=Get-Command $name -Module $runtime.Name
        if($command.CommandType -ne 'Function'){throw "Missing public function: $name"}
        foreach($manifestPath in @('FrenchExDev.QuietCli.PoSh.psd1','src/QuietCli.psd1')){
            $manifest=Import-PowerShellDataFile (Join-Path $core $manifestPath)
            if($name -notin $manifest.FunctionsToExport){throw "Missing manifest export: $name"}
        }
        $checks.Add(@{Name='PublicCommand';Command=$name;Outcome='Success'})
    }
    foreach($name in @('Invoke-QuietCli','New-QuietContract')){
        $command=Get-Command $name -Module $runtime.Name
        if(!$command.Parameters.ContainsKey('OnOutput')){throw "Missing streaming parameter on $name"}
        $checks.Add(@{Name='StreamingInterface';Command=$name;Parameter='OnOutput';Outcome='Success'})
    }
    $acceptancePath=Join-Path $core 'verification/v2-validation.json'
    $acceptance=Get-Content -LiteralPath $acceptancePath -Raw|ConvertFrom-Json -AsHashtable
    if($acceptance.Outcome -ne 'Success' -or $acceptance.Failed -or $acceptance.Skipped -or $acceptance.DiscoveryErrors -or !$acceptance.AnalyzerRun -or $acceptance.Analyzer.Count){throw 'Current Linux acceptance and analysis evidence is not successful.'}
    $report.Acceptance=@{Passed=$acceptance.Passed;Failed=$acceptance.Failed;Skipped=$acceptance.Skipped;DiscoveryErrors=$acceptance.DiscoveryErrors;AnalyzerDiagnostics=$acceptance.Analyzer.Count;ReportSHA256=(Get-FileHash $acceptancePath).Hash}
    $moduleProofs=@()
    foreach($path in @((Join-Path $ecosystem 'FrenchExDev.QuietCli.Git.PoSh/FrenchExDev.QuietCli.Git.PoSh.psd1')|Where-Object {Test-Path -LiteralPath $_})){
        $validation=Test-QuietModule -Path $path -AsObject
        if($validation.Outcome -ne 'Success'){throw ($validation.Data.Failures -join '; ')}
        $moduleProofs+=@{Path=[IO.Path]::GetRelativePath($ecosystem,$path);Hash=$validation.Data.Hash;Checks=$validation.Data.Checks;Outcome=$validation.Outcome}
    }
    $report.GitModules=$moduleProofs
    if(Test-Path -LiteralPath (Join-Path $core 'modules')){throw 'Consumer modules must remain separate from the runtime workspace.'}
    $report.EngineModuleCopies=0
    $syntax=@(foreach($path in Get-ChildItem -LiteralPath $ecosystem -Recurse -File|Where-Object Extension -In @('.ps1','.psm1','.psd1')){
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors)
        foreach($errorItem in $errors){@{Path=[IO.Path]::GetRelativePath($ecosystem,$path.FullName);Message=$errorItem.Message}}
    })
    if($syntax.Count){$report.SyntaxErrors=$syntax;throw 'PowerShell syntax errors remain.'}
    $report.SyntaxErrors=@()
    $report.RequiredRuntimeModules=@($runtime.RequiredModules|ForEach-Object Name)
    $report.ContainerInit=([IO.File]::ReadAllText('/proc/1/comm').Trim() -eq 'podman-init')
    if(!$IsLinux -or !$report.ContainerInit){throw 'Qualification requires the owned Linux container with init.'}
    $report.CIExecution='Not run; local Linux validation only'
    $report.Checks=$checks.ToArray()
    $report.Outcome='Success'
}catch{
    $report.Outcome='Failed'
    $report.Error=$_.Exception.Message
    $report.Checks=$checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{Outcome=$report.Outcome;Data=@{Checks=$checks.Count;GitModules=$report.GitModules;Acceptance=$report.Acceptance;Error=$report.Error;Report=[IO.Path]::GetFullPath($OutputPath)}}|ConvertTo-Json -Depth 8 -Compress
if($report.Outcome -ne 'Success'){exit 1}