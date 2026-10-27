#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([string]$Python='python3', [switch]$RuntimeOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../QuietCli.PoSh.psd1') -Force
if (!$RuntimeOnly) {
    $dependency=Invoke-QuietCli -FilePath $Python -ArgumentList @('-c',
        'import json,sys; print(json.dumps({"major":sys.version_info.major,"version":sys.version.split()[0]})); sys.exit(0 if sys.version_info.major == 3 else 1)') `
        -TimeoutSeconds 10 -Parse {param($capture) ConvertFrom-Json $capture.Stdout -ErrorAction Stop}
    if ($dependency.Outcome -ne 'Success') {
        New-QuietResult -Summary 'Python 3 is required; no smoke checks were run. Use -Python with a working executable, or -RuntimeOnly.' `
            -Outcome Unsupported -Execution @{AnalysisComplete=$false} -ErrorInfo @{Code='MissingDependency'} `
            -Data @{Dependency='Python 3';Executable=$Python;Passed=0;Failed=0} | ConvertTo-QuietJson
        exit 2
    }
}
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../fixtures/noisy-job.py'))
$checks=[Collections.Generic.List[object]]::new()
function Check {
    param([string]$Name,[scriptblock]$Body,[switch]$Native)
    if ($RuntimeOnly -and $Native) { return }
    try { & $Body; $checks.Add(@{Name=$Name;Passed=$true}) }
    catch { $checks.Add(@{Name=$Name;Passed=$false;Exception=$_.Exception.GetType().Name;Message=$_.Exception.Message}) }
}
function Assert([bool]$Condition,[string]$Message='Assertion failed') { if (!$Condition) { throw $Message } }
function Document([string[]]$NativeArgs,[int[]]$Codes=@(0),[int]$Limit=262144) {
    Invoke-QuietCli -FilePath $Python -ArgumentList (@($fixture)+$NativeArgs) -SuccessExitCodes $Codes `
        -MaxCaptureCharacters $Limit -Parse {param($capture) ConvertFrom-Json $capture.Stdout -ErrorAction Stop}
}
Check 'Data preserves object, scalar, array and null shapes' {
    $object=New-QuietResult -Data ([pscustomobject]@{Answer=42;Nested=@{Valid=$true}})
    Assert ($object.Data.Answer -eq 42 -and $object.Data.Nested.Valid)
    Assert ((New-QuietResult -Data 42).Data -eq 42)
    $array=New-QuietResult -Data @(1,2,3)
    Assert ($array.Data.Count -eq 3 -and $array.Data[1] -eq 2)
    Assert ($null -eq (New-QuietResult -Data $null).Data)
}
Check 'Arguments preserve spaces, quotes and shell-looking text' -Native {
    $argsWanted=@('a space','a"quote',"a'quote",'$(touch SHOULD_NOT_EXIST)','--literal')
    $result=Document (@('--echo-args')+$argsWanted)
    Assert ($result.Outcome -eq 'Success')
    Assert (($result.Data.arguments | ConvertTo-Json -Compress) -eq ($argsWanted | ConvertTo-Json -Compress))
}
Check 'Native failure remains failure even with parseable JSON' -Native {
    $result=Document @('--exit-code','7','--echo-args','value')
    Assert ($result.Outcome -eq 'Failed' -and $result.Execution.ExitCode -eq 7 -and !$result.Execution.AnalysisComplete)
}
Check 'Caller can explicitly accept a nonzero functional exit code' -Native {
    $result=Document @('--exit-code','7','--echo-args','value') -Codes @(0,7)
    Assert ($result.Outcome -eq 'Success' -and $result.Execution.ExitCode -eq 7)
}
Check 'Missing executable returns a structured failure' {
    $result=Invoke-QuietCli -FilePath '__quiet_cli_missing_executable__' -Parse {param($c) @{Never=$true}}
    Assert ($result.Outcome -eq 'Failed' -and !$result.Execution.AnalysisComplete -and $null -eq $result.Data)
}
Check 'Document capture overflow never parses a clipped document' -Native {
    $result=Document @('--echo-args',('x'*4000)) -Limit 1024
    Assert ($result.Outcome -eq 'Failed' -and $result.Error.Code -eq 'CaptureLimit' -and $null -eq $result.Data)
    Assert ($result.Execution.StdoutCharacters -gt 1024 -and $result.Execution.ExitCode -eq 0)
}
Check 'Large concurrent stdout and stderr are drained with exact counters' -Native {
    $state=@{Progress=0L;Stderr=0L;Final=$null}
    $result=Invoke-QuietCli -FilePath $Python -ArgumentList @($fixture,'--records','10000') -State $state `
        -OnRecord {
            param($record,$state)
            if ($record.Stream -eq 'stderr') {$state.Stderr++;return}
            $event=ConvertFrom-Json $record.Text
            if ($event.type -eq 'progress') {$state.Progress++} else {$state.Final=$event.processed}
        } -Complete {param($state,$capture) [pscustomobject]@{Progress=$state.Progress;Stderr=$state.Stderr;Reported=$state.Final}}
    Assert ($result.Outcome -eq 'Success' -and $result.Data.Progress -eq 10000 -and $result.Data.Stderr -eq 10000)
    Assert ($result.Data.Reported -eq 10000 -and $result.Execution.AnalysisComplete)
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024)
    Assert ($json -notmatch 'example-secret|verbose progress')
}
Check 'Oversized stream record produces an uncertified failure' -Native {
    $state=@{Seen=0}
    $result=Invoke-QuietCli -FilePath $Python -ArgumentList @($fixture,'--giant','4000') -MaxRecordCharacters 1024 `
        -State $state -OnRecord {param($r,$s) if (!$r.Truncated) {$s.Seen++}} `
        -Complete {param($s,$c) @{Seen=$s.Seen}}
    Assert ($result.Outcome -eq 'Failed' -and $result.Error.Code -eq 'RecordLimit' -and $result.Execution.LostRecords -eq 1)
}
Check 'Parser failure drains the command without relaunch or raw fallback' -Native {
    $result=Invoke-QuietCli -FilePath $Python -ArgumentList @($fixture,'--records','1000') `
        -State @{} -OnRecord {param($r,$s) throw 'bad parser'} -Complete {param($s,$c) @{Never=$true}}
    Assert ($result.Outcome -eq 'Failed' -and $result.Error.Code -eq 'ParserFailed')
    Assert ($result.Execution.ExitCode -eq 0 -and $result.Execution.StdoutCharacters -gt 50000)
}
Check 'Malformed machine output does not become a success' -Native {
    $result=Document @('--malformed')
    Assert ($result.Outcome -eq 'Failed' -and $result.Error.Code -eq 'ParserFailed')
}
Check 'Timeout is distinct from capture and output limits' -Native {
    $result=Invoke-QuietCli -FilePath $Python -ArgumentList @($fixture,'--sleep','5','--records','1') `
        -TimeoutSeconds 1 -Parse {param($c) @{Never=$true}}
    Assert ($result.Outcome -eq 'Timeout' -and $result.Error.Code -eq 'Timeout' -and !$result.Execution.AnalysisComplete)
    Assert ($result.Execution.ElapsedMs -lt 4000)
}
Check 'Known sensitive fields are masked and omissions reported' {
    $result=New-QuietResult -Data @{Password='do-not-show';Message='token=also-secret';Answer=42}
    $json=ConvertTo-QuietJson $result
    Assert ($json -notmatch 'do-not-show|also-secret' -and $result.Data.Answer -eq 42)
    Assert ($result.Truncation.Applied)
}
Check 'An oversized projection cannot exceed the final byte budget' {
    $data=@{Values=@(1..200 | ForEach-Object {('x'*100)})}
    $result=New-QuietResult -Data $data -MaxOutputBytes 1024
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024 -and $result.Truncation.Applied)
    Assert ($null -eq $result.Data)
}
Check 'Twenty assigned failures retain aggregate counters under 1 KiB' {
    $result=Invoke-QuietTask -MaxOutputBytes 1024 {
        foreach ($i in 1..20) {
            $local=Invoke-QuietStep "step-$i" {New-QuietResult -Outcome Failed -ErrorInfo @{Code='ExpectedFailure'}}
        }
        @{Large=@(1..100 | ForEach-Object {('z'*100)})}
    }
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ($result.Outcome -eq 'Failed' -and $result.Execution.Failed -eq 20 -and $result.Execution.Steps -eq 20)
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024)
}
Check 'Oversized metadata cannot defeat the transport byte limit' {
    $result=New-QuietResult -Data @{Answer=42} -MaxOutputBytes 1024 `
        -Execution @{ExitCode=('e'*2000);ElapsedMs=('m'*2000);Steps=20;Failed=20} `
        -ErrorInfo @{Code=('c'*2000);Detail=('d'*2000)}
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024)
    Assert ($result.Execution.Steps -eq 20 -and $result.Execution.Failed -eq 20)
}
Check 'Repeated emission of the same step envelope is not double-counted' {
    $result=Invoke-QuietTask {$step=Invoke-QuietStep once {New-QuietResult -Data @{Value=1}};$step;$step;@{Answer=1}}
    Assert ($result.Execution.Steps -eq 1 -and $result.Data.Answer -eq 1)
}
Check 'An assigned timeout survives the final projection' {
    $result=Invoke-QuietTask {$local=Invoke-QuietStep waited {New-QuietResult -Outcome Timeout -ErrorInfo @{Code='Timeout'}};@{Partial=$true}}
    Assert ($result.Outcome -eq 'Timeout' -and $result.Execution.Timeouts -eq 1)
}
Check 'Generated multi-stage script returns exactly one bounded document' -Native {
    $json=@(& (Join-Path $PSScriptRoot '../examples/Generated-NoisyJob.ps1') -Python $Python -Records 100)
    Assert ($json.Count -eq 1)
    $result=ConvertFrom-Json $json[0]
    Assert ($result.Outcome -eq 'Success' -and $result.Data.Prepared -eq 100 -and $result.Data.Validated -eq 100)
    Assert ($result.Execution.Steps -eq 2 -and [Text.Encoding]::UTF8.GetByteCount($json[0]) -le 2048)
}
Check 'Task and JSON roundtrip preserve empty, singleton and multi-value arrays' {
    foreach ($value in @(@(),@(42),@(1,2))) {
        $result=Invoke-QuietTask -ArgumentList @(,$value) {param($domain) return ,$domain}
        $expected=ConvertTo-Json -InputObject $value -Compress
        Assert ($result.Outcome -eq 'Success' -and !$result.Truncation.Applied)
        Assert ($result.Data -is [array]) 'A task changed an array into a scalar or an object.'
        Assert ((ConvertTo-Json -InputObject $result.Data -Compress) -eq $expected) 'A task changed the array contents.'
        $decoded=ConvertTo-QuietJson $result | ConvertFrom-Json
        Assert ($decoded.Data -is [array] -and (ConvertTo-Json -InputObject $decoded.Data -Compress) -eq $expected)
    }
}
Check 'Nested arrays and multiple task projections retain their JSON shape' {
    $domain=[pscustomobject]@{Empty=@();One=@(42);Nested=@(@(1,2),@(3))}
    $result=Invoke-QuietTask -ArgumentList @($domain) {param($value) $value}
    Assert ((ConvertTo-Json -InputObject $result.Data -Depth 8 -Compress) -eq
        (ConvertTo-Json -InputObject $domain -Depth 8 -Compress))
    $multiple=Invoke-QuietTask { ,@(1,2); ,@(3,4) }
    Assert ((ConvertTo-Json -InputObject $multiple.Data -Compress) -eq '[[1,2],[3,4]]')
}
Check 'Empty custom objects survive nested result serialization' {
    $empty=New-QuietResult -Data ([pscustomobject]@{})
    Assert ((ConvertTo-Json -InputObject $empty.Data -Compress) -eq '{}')
    $result=Invoke-QuietTask { [pscustomobject]@{Empty=[pscustomobject]@{};Values=@()} }
    $decoded=ConvertTo-QuietJson $result | ConvertFrom-Json
    Assert (@($decoded.Data.Empty.PSObject.Properties).Count -eq 0)
    Assert ($decoded.Data.Values -is [array] -and $decoded.Data.Values.Count -eq 0)
}
Check 'Large numeric metadata respects the final UTF-8 budget' {
    $result=New-QuietResult -Data @{Answer=42} -Execution @{Steps=[Numerics.BigInteger]::Pow(10,2000)} -MaxOutputBytes 1024
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024) 'Large numeric metadata escaped the byte budget.'
    Assert ($result.Outcome -eq 'Success')
    if ($null -eq $result.Data) { Assert $result.Truncation.Applied }
}
Check 'The last metadata fallback remains bounded and preserves failure' {
    $execution=@{AnalysisComplete=$false}
    foreach ($key in @('ExitCode','ElapsedMs','Steps','Failed','Timeouts','Unsupported','Truncated','ScriptErrors')) {
        $execution[$key]=[Numerics.BigInteger]::Pow(10,61)
    }
    $result=New-QuietResult -Outcome Failed -Summary ('é'*160) -Execution $execution `
        -ErrorInfo @{Code=('é'*80)} -MaxOutputBytes 1024
    $json=ConvertTo-QuietJson $result -MaxOutputBytes 1024
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 1024) 'The final fallback exceeded the UTF-8 budget.'
    Assert ($result.Outcome -eq 'Failed' -and $result.Truncation.Applied)
}
Check 'Missing Python is reported once before any native smoke checks' {
    $pwsh=(Get-Process -Id $PID).Path
    $result=Invoke-QuietCli -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',
        $PSCommandPath,'-Python','__quiet_cli_missing_python__') -SuccessExitCodes @(2) -TimeoutSeconds 30 `
        -Parse {param($capture) ConvertFrom-Json $capture.Stdout -ErrorAction Stop}
    Assert ($result.Outcome -eq 'Success' -and $result.Execution.ExitCode -eq 2)
    Assert ($result.Data.Outcome -eq 'Unsupported' -and $result.Data.Error.Code -eq 'MissingDependency')
    Assert ($result.Data.Data.Passed -eq 0 -and $result.Data.Data.Failed -eq 0)
}
$passed=@($checks | Where-Object Passed).Count
$failed=$checks.Count-$passed
$result=New-QuietResult -Summary "$passed checks passed; $failed failed." -Outcome $(if ($failed) {'Failed'} else {'Success'}) `
    -Data @{PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.Platform.ToString();PythonVersion=$(if ($RuntimeOnly) {$null} else {$dependency.Data.version});RuntimeOnly=[bool]$RuntimeOnly;Passed=$passed;Failed=$failed;Checks=$checks.ToArray()} -MaxOutputBytes 8192
ConvertTo-QuietJson $result -MaxOutputBytes 8192
if ($failed) { exit 1 }
