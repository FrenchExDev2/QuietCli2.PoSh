#requires -Version 7.6
#requires -PSEdition Core
# Objectif : qualifier le ZIP QuietCli sur un vrai build et les tests Serilog dans Alpine.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$archive=[IO.Path]::GetFullPath($ArchivePath)
$manifestFile=[IO.Path]::GetFullPath($ManifestPath)
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path (Join-Path $output 'integration.json')){throw 'Choose a new output directory: integration.json already exists.'}
[void][IO.Directory]::CreateDirectory($output)
$work=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-dotnet-'+[guid]::NewGuid().ToString('N'))
$report=[ordered]@{
    Kind='DotNetIntegration';SchemaVersion=1;Outcome='Failed'
    StartedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');CompletedAtUtc=$null
    Image='mcr.microsoft.com/dotnet/sdk:10.0-alpine3.24@sha256:cc02b814237a76c4735fb6eeee87181597b5e56f2ce458a435e527674d91f4d7'
    Source=@{Repository='https://github.com/serilog/serilog';Tag='v4.4.0';Commit='6d9fc0b84e004418f2677b5961b9c8970349d0be';Project='test/Serilog.Tests/Serilog.Tests.csproj';Framework='net10.0'}
    DependencyCorrections=@{ 'System.Security.Cryptography.Xml'='8.0.5';'System.Security.Cryptography.Pkcs'='8.0.2';NuGetAudit=$true;NuGetAuditMode='all';TreatWarningsAsErrors=$true }
    Runtime=$null;Distribution=$null;Tests=$null;ExpectedFailure=$null;Replay=$null
    Checks=[Collections.Generic.List[string]]::new();Phases=[Collections.Generic.List[object]]::new();Error=$null
}
$before=@{}
foreach($key in @('QUIETCLI_DB_PATH','QUIETCLI_CONFIG_PATH','QUIETCLI_TRACKING','QUIETCLI_RECALL','DOTNET_CLI_UI_LANGUAGE','DOTNET_NOLOGO','DOTNET_CLI_TELEMETRY_OPTOUT','NO_COLOR')){
    $before[$key]=[Environment]::GetEnvironmentVariable($key)
}
function Assert-Integration {
    param([bool]$Condition,[string]$Message)
    if(!$Condition){throw ("Assertion failed: "+$Message)}
    $report.Checks.Add($Message)
}
function Test-IntegrationDistribution {
    param([string]$ZipPath,[string]$JsonPath,[string]$Destination)
    $external=Get-Content -LiteralPath $JsonPath -Raw|ConvertFrom-Json
    $hash=(Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -cne $external.ArchiveSHA256){throw 'Archive SHA-256 mismatch.'}
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath,$Destination)
    $runtime=Join-Path $Destination 'QuietCli'
    $package=Get-Content (Join-Path $runtime 'package-manifest.json') -Raw|ConvertFrom-Json
    $required=@('FrenchExDev.QuietCli.PoSh.psd1','FrenchExDev.QuietCli.PoSh.psm1','src/NativeSession.cs','src/GainStore.cs','resources/runtime/runtimes/linux-musl-x64/native/libe_sqlite3.so')
    foreach($relative in $required){
        if(!(Test-Path -LiteralPath (Join-Path $runtime $relative) -PathType Leaf)){throw "Required module file missing: $relative"}
    }
    $externalFiles=@{}
    foreach($item in $external.Files){
        if($externalFiles.ContainsKey($item.Path)){throw 'Duplicate external manifest path.'}
        $externalFiles[$item.Path]=$item.SHA256
    }
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $package.Files){
        $path=[IO.Path]::GetFullPath((Join-Path $runtime $item.Path))
        if(!$path.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or !$paths.Add([string]$item.Path)){throw 'Unsafe or duplicate package path.'}
        if(!$externalFiles.ContainsKey($item.Path) -or $externalFiles[$item.Path] -cne $item.SHA256){throw "Manifest disagreement: $($item.Path)"}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.SHA256){throw "Package hash mismatch: $($item.Path)"}
    }
    foreach($relative in $required){if(!$paths.Contains($relative)){throw "Required module file untracked: $relative"}}
    if($paths.Count -ne $externalFiles.Count){throw 'Manifest file counts disagree.'}
    $actual=@(Get-ChildItem -LiteralPath $runtime -File -Recurse)
    if($actual.Count -ne ($paths.Count+1)){throw 'Untracked archive content.'}
    if(Test-Path (Join-Path $runtime 'modules')){throw 'Consumer modules must not be bundled.'}
    [pscustomobject]@{Runtime=$runtime;ArchiveSHA256=$hash;VerifiedFiles=$paths.Count;SourceCommit=$external.SourceCommitBase}
}
function Invoke-IntegrationDotNet {
    param([string]$Name,[string[]]$NativeArguments,[switch]$Record)
    # Objectif : executer une phase dotnet et calculer son resultat depuis la capture native.
    $result=quiet -AsObject -ContractPath $contract -TimeoutSeconds 600 -Record:$Record dotnet @NativeArguments
    $report.Phases.Add(@{Name=$Name;Outcome=$result.Outcome;ExitCode=$result.Execution.ExitCode;Completeness=$result.Completeness;Data=$result.Data;Error=$result.Error;RecordId=$result.RecordId})
    Assert-Integration ($result.Completeness.Source -and $result.Completeness.Analysis -and $result.Completeness.Capture) "$Name has complete source, analysis and capture."
    # Objectif : verifier que la livraison bornee conserve les compteurs du resultat local complet.
    $json=$result|ConvertTo-QuietJson -MaxOutputBytes 4096 -MaxItems 10
    Assert-Integration ([Text.Encoding]::UTF8.GetByteCount($json) -le 4096) "$Name delivery fits 4096 UTF-8 bytes."
    if($result.Data.Counts){
        $delivered=$json|ConvertFrom-Json
        foreach($key in @('Total','Passed','Failed','Skipped')){
            Assert-Integration ($null -ne $delivered.Data.Counts.$key -and $delivered.Data.Counts.$key -eq $result.Data.Counts.$key) "$Name delivery preserves $key."
        }
    }
    $result
}
function Test-IntegrationTrx {
    param($Counts,[string]$Path)
    if(!(Test-Path -LiteralPath $Path)){throw "Missing TRX oracle: $Path"}
    [xml]$trx=Get-Content -LiteralPath $Path -Raw
    $counters=$trx.TestRun.ResultSummary.Counters
    $rows=@($trx.TestRun.Results.UnitTestResult)
    $oracle=[ordered]@{Total=[int]$counters.total;Passed=[int]$counters.passed;Failed=[int]$counters.failed;Skipped=[int]$counters.notExecuted}
    foreach($key in @('Total','Passed','Failed','Skipped')){
        Assert-Integration ($null -ne $Counts.$key -and $Counts.$key -eq $oracle[$key]) "Console and TRX agree on $key in $(Split-Path $Path -Leaf)."
    }
    Assert-Integration ($rows.Count -eq $oracle.Total -and @($rows|Where-Object outcome -EQ 'Passed').Count -eq $oracle.Passed -and @($rows|Where-Object outcome -EQ 'Failed').Count -eq $oracle.Failed) 'TRX result rows agree with its counters.'
    [pscustomobject]$oracle
}
try {
    # Objectif : refuser toute qualification hors Alpine ou avec un module preimporte.
    Assert-Integration ($IsLinux -and (Test-Path '/etc/alpine-release')) 'Execution uses Alpine Linux.'
    Assert-Integration ([Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier -eq 'linux-musl-x64') 'Execution uses linux-musl-x64.'
    Assert-Integration (!(Get-Module FrenchExDev.QuietCli.PoSh,QuietCli)) 'QuietCli starts in a fresh PowerShell process.'
    [void][IO.Directory]::CreateDirectory($work)
    # Objectif : verifier la distribution et ses dependances avant tout import.
    $distribution=Test-IntegrationDistribution $archive $manifestFile (Join-Path $work 'distribution')
    $report.Distribution=$distribution
    # Objectif : verifier le refus explicite du ZIP altere.
    $tampered=Join-Path $work 'tampered.zip'
    $bytes=[IO.File]::ReadAllBytes($archive);$bytes[$bytes.Length-1]=$bytes[$bytes.Length-1] -bxor 1
    [IO.File]::WriteAllBytes($tampered,$bytes)
    $refused=$false
    try{$null=Test-IntegrationDistribution $tampered $manifestFile (Join-Path $work 'tampered')}catch{$refused=$_.Exception.Message -eq 'Archive SHA-256 mismatch.'}
    Assert-Integration $refused 'An altered ZIP is rejected by its SHA-256.'
    # Objectif : verifier un fichier requis absent meme avec des manifestes coherents.
    $missing=Join-Path $work 'missing.zip'
    Copy-Item -LiteralPath $archive -Destination $missing
    $zip=[IO.Compression.ZipFile]::Open($missing,[IO.Compression.ZipArchiveMode]::Update)
    try{
        $zip.GetEntry('QuietCli/FrenchExDev.QuietCli.PoSh.psd1').Delete()
        $entry=$zip.GetEntry('QuietCli/package-manifest.json')
        $reader=[IO.StreamReader]::new($entry.Open())
        try{$package=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        $package.Files=@($package.Files|Where-Object Path -NE 'FrenchExDev.QuietCli.PoSh.psd1')
        $entry.Delete()
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('QuietCli/package-manifest.json').Open())
        try{$writer.Write(($package|ConvertTo-Json -Depth 20))}finally{$writer.Dispose()}
    }finally{$zip.Dispose()}
    $missingManifest=Get-Content $manifestFile -Raw|ConvertFrom-Json
    $missingManifest.Files=@($missingManifest.Files|Where-Object Path -NE 'FrenchExDev.QuietCli.PoSh.psd1')
    $missingManifest.ArchiveSHA256=(Get-FileHash $missing -Algorithm SHA256).Hash.ToLowerInvariant()
    $missingJson=Join-Path $work 'missing.json'
    [IO.File]::WriteAllText($missingJson,($missingManifest|ConvertTo-Json -Depth 20))
    $refused=$false
    try{$null=Test-IntegrationDistribution $missing $missingJson (Join-Path $work 'missing')}catch{$refused=$_.Exception.Message -like 'Required module file missing:*'}
    Assert-Integration $refused 'A required file missing from a coherent archive is rejected.'
    # Objectif : importer exclusivement le runtime extrait et isoler sa base SQLite.
    $env:QUIETCLI_DB_PATH=Join-Path $work 'history.sqlite3'
    $env:QUIETCLI_CONFIG_PATH=Join-Path $work 'settings.json'
    $env:QUIETCLI_TRACKING='0';$env:QUIETCLI_RECALL='0'
    Import-Module (Join-Path $distribution.Runtime 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
    $loaded=Get-Module FrenchExDev.QuietCli.PoSh
    Assert-Integration ($loaded.ModuleBase -ceq $distribution.Runtime) 'Only the extracted module is imported.'
    $env:DOTNET_CLI_UI_LANGUAGE='en-US';$env:DOTNET_NOLOGO='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:NO_COLOR='1'
    $contract=Join-Path $PSScriptRoot '../test/integration/contracts/DotNet.Serilog.ps1'
    # Objectif : cloner le tag public dans un repertoire temporaire puis verifier son commit.
    $source=Join-Path $work 'source'
    $clone=quiet -AsObject -TimeoutSeconds 600 -Parse {param($capture) @{ExitCode=$capture.ExitCode;Diagnostics=@(($capture.Stderr -split '\r?\n')|Where-Object {$_}|Select-Object -Last 8)}} git clone --quiet --depth 1 --branch v4.4.0 https://github.com/serilog/serilog.git $source
    Assert-Integration ($clone.Outcome -eq 'Success') ('Serilog clone succeeds. '+($clone.Data.Diagnostics -join ' '))
    Push-Location $source
    try {
        $revision=quiet -AsObject -Parse {param($capture) $capture.Stdout.Trim()} git rev-parse HEAD
        Assert-Integration ($revision.Outcome -eq 'Success' -and $revision.Data -ceq $report.Source.Commit) 'The Serilog commit matches the pinned tag.'
        # Objectif : appliquer uniquement les deux correctifs NuGet autorises dans la copie.
        $project=$report.Source.Project
        [xml]$xml=Get-Content $project -Raw
        $reference=$xml.SelectSingleNode("//PackageReference[@Include='System.Security.Cryptography.Xml']")
        if(!$reference -or $reference.Version -ne '8.0.3'){throw 'Unexpected upstream XML package reference.'}
        $reference.SetAttribute('Version','8.0.5')
        $pkcs=$xml.CreateElement('PackageReference');$pkcs.SetAttribute('Include','System.Security.Cryptography.Pkcs');$pkcs.SetAttribute('Version','8.0.2')
        $null=$reference.ParentNode.AppendChild($pkcs)
        $xml.Save((Join-Path $source $project))
        $report.Source['PatchedProjectSHA256']=(Get-FileHash $project -Algorithm SHA256).Hash.ToLowerInvariant()
        $sdk=quiet -AsObject -Parse {param($capture) $capture.Stdout.Trim()} dotnet --version
        Assert-Integration ($sdk.Outcome -eq 'Success' -and $sdk.Data -eq '10.0.403') 'The selected SDK is 10.0.403.'
        $report.Runtime=@{PowerShell=$PSVersionTable.PSVersion.ToString();Alpine=(Get-Content /etc/alpine-release -Raw).Trim();SDK=$sdk.Data;RID=[Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier;ModuleVersion=$loaded.Version.ToString();ModuleBase=$loaded.ModuleBase}
        # Objectif : restaurer avec audit complet, compiler puis tester le vrai projet.
        $audit=@('-p:NuGetAudit=true','-p:NuGetAuditMode=all','-p:TreatWarningsAsErrors=true')
        $restore=Invoke-IntegrationDotNet 'Restore' (@('restore',$project,'--verbosity','normal')+$audit)
        Assert-Integration ($restore.Outcome -eq 'Success') 'Restore succeeds with NuGet audit enabled.'
        $buildArgs=@('build',$project,'-c','Release','-f','net10.0','--no-restore','--tl:off','--verbosity','normal')+$audit
        $build=Invoke-IntegrationDotNet 'Build' $buildArgs
        Assert-Integration ($build.Outcome -eq 'Success') 'The baseline Release build succeeds.'
        $results=Join-Path $output 'trx'
        $testArgs=@('test',$project,'-c','Release','-f','net10.0','--no-build','--no-restore','--tl:off','--logger','console;verbosity=normal','--logger','trx;LogFileName=baseline.trx','--results-directory',$results)
        $baseline=Invoke-IntegrationDotNet 'BaselineTests' $testArgs -Record
        Assert-Integration ($baseline.Outcome -eq 'Success' -and $baseline.Execution.ExitCode -eq 0) 'The baseline test command succeeds.'
        $report.Tests=Test-IntegrationTrx $baseline.Data.Counts (Join-Path $results 'baseline.trx')
        Assert-Integration ($report.Tests.Total -eq 815 -and $report.Tests.Failed -eq 0) 'The pinned project executes its 815 baseline tests without failure.'
        # Objectif : injecter une erreur de compilation et verifier son diagnostic.
        $compilerFixture=Join-Path $source 'src/Serilog/QuietCliExpectedBuildFailure.cs'
        try{
            [IO.File]::WriteAllText($compilerFixture,"#error QUIETCLI_EXPECTED_BUILD_FAILURE")
            $failure=Invoke-IntegrationDotNet 'ExpectedCompilerFailure' $buildArgs
            Assert-Integration ($failure.Outcome -eq 'Failed' -and $failure.Execution.ExitCode -ne 0 -and $failure.Data.CompilerFailureMarker -and @($failure.Data.Diagnostics|Where-Object Code -EQ 'CS1029').Count -gt 0) 'The compiler error is classified with CS1029 and its marker.'
        }finally{if(Test-Path $compilerFixture){Remove-Item -LiteralPath $compilerFixture -Force}}
        # Objectif : injecter un test xUnit defaillant, le compiler et executer uniquement ce test.
        $testFixture=Join-Path $source 'test/Serilog.Tests/QuietCliExpectedFailureTests.cs'
        try{
            [IO.File]::WriteAllText($testFixture,'public class QuietCliIntegrationExpectedFailure { [Xunit.Fact] public void FailsAsExpected() => throw new System.InvalidOperationException("QUIETCLI_EXPECTED_TEST_FAILURE"); }')
            $fixtureBuild=Invoke-IntegrationDotNet 'BuildFailureFixture' $buildArgs
            Assert-Integration ($fixtureBuild.Outcome -eq 'Success') 'The controlled failing-test fixture compiles.'
            $failureArgs=@($testArgs|ForEach-Object {if($_ -eq 'trx;LogFileName=baseline.trx'){'trx;LogFileName=expected-failure.trx'}else{$_}})+@('--filter','FullyQualifiedName=QuietCliIntegrationExpectedFailure.FailsAsExpected')
            $testFailure=Invoke-IntegrationDotNet 'ExpectedTestFailure' $failureArgs
            Assert-Integration ($testFailure.Outcome -eq 'Failed' -and $testFailure.Execution.ExitCode -eq 1 -and $testFailure.Data.TestFailureMarker) 'The failing xUnit test returns exit code 1 and its marker.'
            $report.ExpectedFailure=Test-IntegrationTrx $testFailure.Data.Counts (Join-Path $results 'expected-failure.trx')
            Assert-Integration ($report.ExpectedFailure.Total -eq 1 -and $report.ExpectedFailure.Failed -eq 1) 'Exactly one controlled test fails.'
        }finally{if(Test-Path $testFixture){Remove-Item -LiteralPath $testFixture -Force}}
    }finally{Pop-Location}
    # Objectif : rendre les sources et les TRX originaux indisponibles avant le rejeu.
    $offlineSource=Join-Path $work 'source-offline'
    $offlineTrx=Join-Path $output 'trx-offline'
    Move-Item -LiteralPath $source -Destination $offlineSource
    Move-Item -LiteralPath $results -Destination $offlineTrx
    try{
        $replay=Invoke-QuietRecord -Id $baseline.RecordId -ContractPath $contract -AsObject
        Assert-Integration ($replay.Outcome -eq 'Success' -and $replay.Execution.Replay) 'Replay succeeds without a native execution.'
        foreach($key in @('Total','Passed','Failed','Skipped')){
            Assert-Integration ($replay.Data.Counts.$key -eq $baseline.Data.Counts.$key) "Replay preserves $key without source files or original TRX."
        }
        $report.Replay=@{Outcome=$replay.Outcome;Replay=[bool]$replay.Execution.Replay;OriginalSourceUnavailable=!(Test-Path $source);OriginalTrxUnavailable=!(Test-Path $results);Counts=$replay.Data.Counts}
    }finally{Move-Item -LiteralPath $offlineTrx -Destination $results;Move-Item -LiteralPath $offlineSource -Destination $source}
    $report.Outcome='Success'
}catch{$report.Error=$_.Exception.Message}
finally{
    $report.CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    # Objectif : conserver uniquement les resultats metier et nettoyer le repertoire temporaire verifie.
    [IO.File]::WriteAllText((Join-Path $output 'integration.json'),($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    foreach($key in $before.Keys){[Environment]::SetEnvironmentVariable($key,$before[$key])}
    if(Test-Path -LiteralPath $work){
        $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if([IO.Path]::GetDirectoryName($work) -cne $parent -or (Split-Path $work -Leaf) -notmatch '^quietcli-dotnet-[a-f0-9]{32}$'){throw 'Unexpected cleanup target.'}
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
$summary=@{Kind='DotNetIntegration';Report=(Join-Path $output 'integration.json');Tests=$report.Tests;ExpectedFailure=$report.ExpectedFailure;Replay=$report.Replay;Checks=$report.Checks.Count;Runtime=$report.Runtime;ArchiveSHA256=$report.Distribution.ArchiveSHA256;Error=$report.Error}
if(Get-Command New-QuietResult -ErrorAction SilentlyContinue){
    New-QuietResult -Outcome $report.Outcome -Summary ('Alpine Serilog integration: '+$report.Outcome) -Data $summary|ConvertTo-QuietJson -MaxOutputBytes 4096 -MaxItems 20
}else{
    # Bootstrap failures happen before QuietCli can safely be imported.
    [pscustomobject]@{Outcome=$report.Outcome;Data=$summary}|ConvertTo-Json -Depth 12 -Compress
}
if($report.Outcome -ne 'Success'){exit 1}
exit 0
