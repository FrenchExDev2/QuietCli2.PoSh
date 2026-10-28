#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([switch]$Analyze,[string]$OutputPath=(Join-Path $PSScriptRoot '../verification/v2-validation.json'),[switch]$RuntimeOnly,[string]$Python='python3')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$environment=@{};foreach($key in @('QUIETCLI_DB_PATH','QUIETCLI_CONFIG_PATH','QUIETCLI_TRACKING','QUIETCLI_RECALL')){$environment[$key]=[Environment]::GetEnvironmentVariable($key)}
try{
    $config=New-PesterConfiguration;$config.TestRegistry.Enabled=$false;$config.Run.Parallel=$false;$config.Run.Path=@((Join-Path $PSScriptRoot 'V2.Acceptance.Tests.ps1'),(Join-Path $PSScriptRoot 'Release.Tests.ps1'),(Join-Path $PSScriptRoot 'DotNet.Contract.Tests.ps1'));$config.Run.PassThru=$true;$config.Output.Verbosity='None'
    $tests=Invoke-Pester -Configuration $config
    $analysisPaths=@('src','scripts/New-QuietCliArchive.ps1','scripts/Verify-QuietCliArchive.ps1','scripts/Test-QuietCliRelease.ps1','scripts/New-QuietCliPackage.ps1','scripts/Publish-QuietCliPackage.ps1','scripts/Install-QuietCliLocalTools.ps1','scripts/Invoke-LocalCI.ps1','scripts/Test-QuietCliDotNetIntegration.ps1','test/integration/contracts/DotNet.Serilog.ps1')
    $diagnostics=if($Analyze){@(foreach($relative in $analysisPaths){Invoke-ScriptAnalyzer -Path (Join-Path $root $relative) -Recurse -Severity Error,Warning})}else{@()}
    $hashes=[ordered]@{};foreach($file in Get-ChildItem (Join-Path $root 'src') -File|Sort-Object Name){$hashes[$file.Name]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash}
    $report=[ordered]@{SchemaVersion=2;ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Platform=$PSVersionTable.OS;PowerShell=$PSVersionTable.PSVersion.ToString()
        Outcome=$(if($tests.FailedCount -or $tests.FailedContainersCount -or $diagnostics.Count){'Failed'}else{'Success'})
        Passed=$tests.PassedCount;Failed=$tests.FailedCount;Skipped=$tests.SkippedCount;DiscoveryErrors=$tests.FailedContainersCount
        Failures=@($tests.Failed|ForEach-Object {@{Name=$_.ExpandedName;Messages=@($_.ErrorRecord|ForEach-Object {$_.Exception.Message})}})
        BlockFailures=@($tests.FailedBlocks|ForEach-Object {@{Name=$_.Name;Messages=@($_.ErrorRecord|ForEach-Object {$_.Exception.Message})}});AnalyzerRun=[bool]$Analyze;Analyzer=@($diagnostics|Select-Object RuleName,ScriptName,Line,Message);SourceSHA256=$hashes}
}finally{foreach($key in $environment.Keys){[Environment]::SetEnvironmentVariable($key,$environment[$key])}}
[void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))))
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{Outcome=$report.Outcome;Data=@{Passed=$report.Passed;Failed=$report.Failed;Skipped=$report.Skipped;DiscoveryErrors=$report.DiscoveryErrors;Analyzer=$report.Analyzer;Failures=$report.Failures;BlockFailures=$report.BlockFailures;Report=[IO.Path]::GetFullPath($OutputPath)}}|ConvertTo-Json -Depth 10 -Compress
if($report.Outcome -ne 'Success'){exit 1}
exit 0
