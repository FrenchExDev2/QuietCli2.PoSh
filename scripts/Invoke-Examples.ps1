#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([string]$QuietCliRoot=(Join-Path $PSScriptRoot '..'),[string]$Python='python3',[string]$PythonImage='',
      [string]$ReportPath=(Join-Path $PSScriptRoot '../verification/series-examples.json'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($QuietCliRoot)
Import-Module (Join-Path $root 'QuietCli.PoSh.psd1') -ErrorAction Stop
$checks=[Collections.Generic.List[object]]::new()
$engine=(Get-Process -Id $PID).Path
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../examples/Native-Fixture.ps1'))
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-series-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporary)
function Test-Case([string]$Name,[scriptblock]$Body) {
    try { $observation=& $Body; $checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Observed=$observation}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message.Substring(0,[Math]::Min(200,$_.Exception.Message.Length)))}) }
}
function Require([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Native([string]$Mode,[int]$Timeout=20,[int]$Capture=262144) {
    Invoke-QuietCli -FilePath $engine -ArgumentList @('-NoLogo','-NoProfile','-File',$fixture,'-Mode',$Mode) `
        -TimeoutSeconds $Timeout -MaxCaptureCharacters $Capture -MaxOutputBytes 2048 -Parse {
            param($capture)
            if ($capture.ExitCode -ne 0) { return }
            ConvertFrom-Json -InputObject $capture.Stdout -ErrorAction Stop
        }
}
function Git([string[]]$Arguments) {
    $r=Invoke-QuietCli -FilePath git -ArgumentList $Arguments -WorkingDirectory $temporary -MaxOutputBytes 2048 -Parse { param($capture) [pscustomobject]@{Completed=($capture.ExitCode -eq 0)} }
    Require ($r.Outcome -eq 'Success') 'Git fixture setup failed.'
}
function Overview { (& (Join-Path $root 'examples/Generated-GitOverview.ps1') -Repository $temporary -MaxOutputBytes 2048) | ConvertFrom-Json }
try {
    Test-Case 'document-success' { $r=Native json; Require ($r.Outcome -eq 'Success' -and $r.Data.Count -eq 3) 'Document parsing failed.'; @{Outcome=$r.Outcome;Count=$r.Data.Count} }
    Test-Case 'malformed-is-not-empty-success' { $r=Native malformed; Require ($r.Outcome -eq 'Failed' -and !$r.Execution.AnalysisComplete -and $null -eq $r.Data) 'Malformed JSON was accepted.'; @{Outcome=$r.Outcome;Code=$r.Error.Code;DataIsNull=($null -eq $r.Data)} }
    Test-Case 'native-failure' { $r=Native fail; Require ($r.Outcome -eq 'Failed' -and $r.Execution.ExitCode -eq 7 -and $r.Error.Code -eq 'NativeFailed') 'Exit code was lost.'; @{Outcome=$r.Outcome;ExitCode=$r.Execution.ExitCode;Code=$r.Error.Code} }
    Test-Case 'timeout' { $r=Native wait 1; Require ($r.Outcome -eq 'Timeout' -and !$r.Execution.AnalysisComplete) 'Timeout was not preserved.'; @{Outcome=$r.Outcome;Code=$r.Error.Code} }
    Test-Case 'capture-limit' { $r=Native capture 20 1024; Require ($r.Outcome -eq 'Failed' -and $r.Error.Code -eq 'CaptureLimit' -and $null -eq $r.Data) 'Capture prefix was accepted.'; @{Outcome=$r.Outcome;Code=$r.Error.Code;Truncated=$r.Truncation.Applied} }
    Test-Case 'record-limit' {
        $state=@{Seen=0}
        $r=Invoke-QuietCli -FilePath $engine -ArgumentList @('-NoLogo','-NoProfile','-File',$fixture,'-Mode','record') -MaxRecordCharacters 1024 -MaxOutputBytes 2048 -State $state -OnRecord {param($record,$state) if(!$record.Truncated){$state.Seen++}} -Complete {param($state,$capture) [pscustomobject]@{Count=$null}}
        Require ($r.Outcome -eq 'Failed' -and $r.Error.Code -eq 'RecordLimit') 'Oversized record was accepted.'
        @{Outcome=$r.Outcome;Code=$r.Error.Code}
    }
    Test-Case 'output-budget' {
        $data=[ordered]@{};foreach($n in 1..20){$data['Field'+$n]='z'*300}
        $json=New-QuietResult -Data $data -Execution @{AnalysisComplete=$true} -MaxOutputBytes 2048 | ConvertTo-QuietJson -MaxOutputBytes 2048
        $r=$json|ConvertFrom-Json;$bytes=[Text.Encoding]::UTF8.GetByteCount($json)
        Require ($bytes -le 2048 -and $r.Truncation.Applied -and $null -eq $r.Data -and 'OutputBudget' -in $r.Truncation.Reasons) 'Final budget was not explicit.'
        @{Bytes=$bytes;DataIsNull=($null -eq $r.Data);Reasons=$r.Truncation.Reasons}
    }
    Test-Case 'consumed-failure-remains-visible' {
        $r=Invoke-QuietTask -MaxOutputBytes 2048 { $ignored=Invoke-QuietStep failed {Native fail}; [pscustomobject]@{Count=$null;AnswerComplete=$false} }
        Require ($r.Outcome -eq 'Failed' -and $r.Execution.Failed -eq 1 -and $null -eq $r.Data.Count) 'Consumed failure disappeared.'
        @{Outcome=$r.Outcome;Failed=$r.Execution.Failed;UnknownRemainsNull=($null -eq $r.Data.Count)}
    }
    Test-Case 'unknown-does-not-become-zero' { $r=New-QuietResult -Data @{Count=$null;AnswerComplete=$false} -MaxOutputBytes 2048; Require ($null -eq $r.Data.Count -and !$r.Data.AnswerComplete) 'Unknown count changed.'; @{Count=$r.Data.Count;AnswerComplete=$r.Data.AnswerComplete} }
    Git @('init','-b','main');Git @('config','user.name','QuietCli fixture');Git @('config','user.email','quietcli@example.invalid');Git @('config','commit.gpgsign','false')
    Set-Content -LiteralPath (Join-Path $temporary 'tracked.txt') -Value 'initial' -Encoding utf8
    Git @('add','tracked.txt');Git @('commit','-m','fixture')
    Test-Case 'git-clean' { $r=Overview; Require ($r.Outcome -eq 'Success' -and $r.Data.Clean -and $r.Data.Branch -eq 'main') 'Clean repository result failed.'; $r.Data }
    Add-Content -LiteralPath (Join-Path $temporary 'tracked.txt') -Value 'changed'
    [void](New-Item -ItemType Directory -Path (Join-Path $temporary 'new-directory'))
    Set-Content -LiteralPath (Join-Path $temporary 'new-directory/one.txt') -Value 'one';Set-Content -LiteralPath (Join-Path $temporary 'new-directory/two.txt') -Value 'two'
    Test-Case 'git-changed-and-directory-entry' { $r=Overview; Require ($r.Outcome -eq 'Success' -and $r.Data.Changed -eq 1 -and $r.Data.Untracked -eq 1 -and !$r.Data.Clean) 'Git entry semantics changed.'; $r.Data }
    Test-Case 'reused-companion-composition' { $json=& (Join-Path $PSScriptRoot '../examples/Invoke-RepositoryDecision.ps1') -Repository $temporary -QuietCliRoot ([IO.Path]::GetRelativePath((Get-Location).Path,$root)); $r=$json|ConvertFrom-Json;Require ($r.Outcome -eq 'Success' -and $r.Data.NeedsReview -and $r.Data.ChangedEntries -eq 1 -and [Text.Encoding]::UTF8.GetByteCount($json) -le 2048) 'Composition failed.';@{Outcome=$r.Outcome;Steps=$r.Execution.Steps;Bytes=[Text.Encoding]::UTF8.GetByteCount($json);NeedsReview=$r.Data.NeedsReview;RelativeRootTested=$true} }
    Test-Case 'git-rename-entry' { Git @('add','--all');Git @('commit','-m','second fixture');Git @('mv','tracked.txt','renamed with spaces.txt');$r=Overview;Require ($r.Outcome -eq 'Success' -and $r.Data.Changed -eq 1 -and $r.Data.Untracked -eq 0) 'Rename counted twice.';$r.Data }
    Test-Case 'git-detached-head' { Git @('checkout','--detach');$r=Overview;Require ($r.Outcome -eq 'Success' -and $r.Data.Detached -and $r.Data.Branch -eq '') 'Detached HEAD semantics changed.';@{Detached=$r.Data.Detached;Branch=$r.Data.Branch} }
    Test-Case 'streaming-two-stages' {
        $json=if($PythonImage){& (Join-Path $PSScriptRoot '../examples/Invoke-NoisyJobContainer.ps1') -PythonImage $PythonImage -QuietCliRoot $root -Records 2000 -MaxOutputBytes 2048}
              else{& (Join-Path $root 'examples/Generated-NoisyJob.ps1') -Python $Python -Records 2000 -MaxOutputBytes 2048}
        $r=$json|ConvertFrom-Json
        Require ($r.Outcome -eq 'Success' -and $r.Data.Prepared -eq 2000 -and $r.Data.Validated -eq 2000 -and $r.Execution.Steps -eq 2 -and [Text.Encoding]::UTF8.GetByteCount($json) -le 2048) ('Streaming completion evidence failed: '+$r.Outcome+' / '+($r.Error|ConvertTo-Json -Depth 4 -Compress))
        @{Outcome=$r.Outcome;Prepared=$r.Data.Prepared;Validated=$r.Data.Validated;Steps=$r.Execution.Steps;Bytes=[Text.Encoding]::UTF8.GetByteCount($json);Adapter=$(if($PythonImage){'Podman: original Python fixture and supplied reduction rules'}else{'Supplied native companion'})}
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path -Leaf $resolved).StartsWith('quietcli-series-')) { throw 'Temporary cleanup boundary failed.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$failed=@($checks|Where-Object {!$_.Passed}).Count
$gitVersion=Invoke-QuietCli -FilePath git -ArgumentList @('--version') -Parse {param($capture) [pscustomobject]@{Version=([regex]::Match($capture.Stdout,'git version [\w.]+')).Value}}
$pythonVersion=if($PythonImage){Invoke-QuietCli -FilePath podman -ArgumentList @('run','--rm','--pull=never','--network=none','--entrypoint','python3',$PythonImage,'--version') -Parse {param($capture) [pscustomobject]@{Version=([regex]::Match($capture.Stdout,'Python [\d.]+')).Value}}}
               else{Invoke-QuietCli -FilePath $Python -ArgumentList @('--version') -Parse {param($capture) [pscustomobject]@{Version=([regex]::Match($capture.Stdout,'Python [\d.]+')).Value}}}
$report=[ordered]@{CheckedDate='2026-10-12';ExecutedAtUtc=[DateTime]::UtcNow.ToString('o');Outcome=$(if($failed){'Failed'}else{'Success'});PowerShell=$PSVersionTable.PSVersion.ToString();Git=$gitVersion.Data.Version;PythonVersion=$pythonVersion.Data.Version;ModuleVersion=(Import-PowerShellDataFile (Join-Path $root 'QuietCli.PoSh.psd1')).ModuleVersion;Python=$Python;PythonImage=$PythonImage;StreamingMode=$(if($PythonImage){'Podman adapter; original Python fixture; native Python companion not executed'}else{'Supplied native Python companion'});RtkExecuted=$false;Benchmark=$false;Passed=$checks.Count-$failed;Failed=$failed;Checks=$checks.ToArray()}
[void](New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))) -Force)
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportPath -Encoding utf8
[pscustomobject]@{Outcome=$report.Outcome;Data=@{Passed=$report.Passed;Failed=$failed;Report=$ReportPath;Failures=@($checks|Where-Object {!$_.Passed}|Select-Object Name,Error)}}|ConvertTo-Json -Depth 5 -Compress
if($failed){exit 1}
