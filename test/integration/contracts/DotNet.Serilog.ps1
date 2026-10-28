#requires -Version 7.6
#requires -PSEdition Core
# Objectif : analyser les sorties documentees de dotnet pour le scenario Serilog Alpine.
param([Parameter(Mandatory)][hashtable]$Invocation)
# Scope: restore/build/test of the pinned Serilog project, English VSTest/MSBuild console.
# The TRX oracle belongs to the integration harness; this parser only consumes native captures.
$arguments=@($Invocation.ArgumentList)
if(!$arguments.Count -or $arguments[0] -notin @('restore','build','test')){
    return New-QuietResult -Outcome Unsupported -Summary 'Supported: dotnet restore/build/test for the integration workload.'
}

$project='test/Serilog.Tests/Serilog.Tests.csproj'
if($arguments.Count -lt 2 -or $arguments[1] -cne $project){
    return New-QuietResult -Outcome Unsupported -Summary 'Only the pinned Serilog test project is supported.'
}
if($arguments[0] -in @('build','test')){
    $configuration=[Array]::IndexOf($arguments,'-c')
    $framework=[Array]::IndexOf($arguments,'-f')
    if($configuration -lt 0 -or $framework -lt 0 -or $configuration+1 -ge $arguments.Count -or $framework+1 -ge $arguments.Count -or $arguments[$configuration+1] -cne 'Release' -or $arguments[$framework+1] -cne 'net10.0' -or '--tl:off' -cnotin $arguments){
        return New-QuietResult -Outcome Unsupported -Summary 'Only Release/net10.0 with the terminal logger disabled is supported.'
    }
}

$operation=[string]$arguments[0]
$parse={
    param($capture)
    $text=$capture.Stdout+[Environment]::NewLine+$capture.Stderr
    $diagnostics=@([regex]::Matches($text,'(?m)^.*?\b(?<severity>error|warning)\s+(?<code>[A-Z]+\d+):[ \t]*(?<message>[^\r\n]+)')|ForEach-Object {
        [pscustomobject]@{Severity=$_.Groups['severity'].Value;Code=$_.Groups['code'].Value;Message=$_.Groups['message'].Value.Trim()}
    }|Sort-Object Severity,Code,Message -Unique)
    $counts=$null
    if($operation -eq 'test'){
        $total=[regex]::Match($text,'(?m)^\s*Total tests:\s*(\d+)\s*$')
        if($total.Success){
            $counts=[ordered]@{Total=[int]$total.Groups[1].Value;Passed=0;Failed=0;Skipped=0}
            foreach($key in @('Passed','Failed','Skipped')){
                $match=[regex]::Match($text,('(?m)^\s*{0}:\s*(\d+)\s*$' -f $key))
                if($match.Success){$counts[$key]=[int]$match.Groups[1].Value}
            }
        }else{
            $line=[regex]::Match($text,'Failed:\s*(\d+),\s*Passed:\s*(\d+),\s*Skipped:\s*(\d+),\s*Total:\s*(\d+)')
            if($line.Success){$counts=[ordered]@{Total=[int]$line.Groups[4].Value;Passed=[int]$line.Groups[2].Value;Failed=[int]$line.Groups[1].Value;Skipped=[int]$line.Groups[3].Value}}
        }
        if(!$counts -or $counts.Total -lt 1 -or ($counts.Passed+$counts.Failed+$counts.Skipped) -ne $counts.Total){
            throw 'A complete non-empty VSTest summary was not found in the native capture.'
        }
    }
    [pscustomobject]@{
        Operation=$operation;Counts=$counts;Diagnostics=$diagnostics;DiagnosticCount=$diagnostics.Count
        CompilerFailureMarker=$text.Contains('QUIETCLI_EXPECTED_BUILD_FAILURE')
        TestFailureMarker=$text.Contains('QUIETCLI_EXPECTED_TEST_FAILURE')
        Scope='Pinned Serilog; English MSBuild/VSTest; net10.0; captured console only'
    }
}.GetNewClosure()
New-QuietContract -Id dotnet.serilog.integration -FilePath $Invocation.FilePath -ArgumentList $arguments -Parse $parse -Summary ('Serilog dotnet '+$operation) -SourcePath @($PSCommandPath) -SupportedForms @('dotnet restore <project>','dotnet build <project> -c Release -f net10.0','dotnet test <project> -c Release -f net10.0') -Documentation @(
    'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-restore',
    'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-build',
    'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test-vstest'
)
