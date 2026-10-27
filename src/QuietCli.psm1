#requires -Version 7.4
#requires -PSEdition Core
Set-StrictMode -Version 3
if (!('QuietCliStack.V1.NativeSession' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeSession.cs') -ErrorAction Stop
}
$script:Tasks = [Collections.Generic.Stack[object]]::new()

function Protect-QuietValue {
    param($Value, [hashtable]$State, [int]$Depth=0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 16) { $State.Limited=$true; return '[omitted: depth]' }
    if ($Value -is [string]) {
        $s=$Value -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
        foreach ($secret in $State.Secrets) { $s=$s.Replace($secret,'[REDACTED]',[StringComparison]::Ordinal) }
        $before=$s
        $s=$s -replace '(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|$)', '[REDACTED]'
        $s=$s -replace '(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', '[REDACTED]'
        $s=$s -replace '(?i)\b(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,}|AKIA[A-Z0-9]{16})\b', '[REDACTED]'
        $s=$s -replace '(?i)((?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*)[^\s,;&]+', '$1[REDACTED]'
        if ($s -ne $before -or $s.Contains('[REDACTED]')) { $State.Redacted=$true }
        if ($s.Length -gt 2048) { $State.Limited=$true; $s=$s.Substring(0,2048) }
        return $s
    }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.ToString('o') }
    if ($Value -is [ValueType]) { return $Value }
    # Pipeline arrays can also satisfy -is [pscustomobject]. Keep them on the collection path.
    if ($Value -is [Collections.IDictionary] -or
        ($Value -is [pscustomobject] -and $Value -isnot [Collections.IEnumerable])) {
        $map=[ordered]@{}; $count=0
        $keys=if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties | ForEach-Object Name) }
        foreach ($key in $keys) {
            if ($count++ -ge 128) { $State.Limited=$true; break }
            $safeKey=[string](Protect-QuietValue ([string]$key) $State ($Depth+1))
            if ([string]$key -match '(?i)^(password|passwd|secret|token|api[_-]?key|access[_-]?key|authorization|credential|connectionstring|env|environment)$') {
                $map[$safeKey]='[REDACTED]'; $State.Redacted=$true
            } else {
                $item=$null
                if ($Value -is [Collections.IDictionary]) { $item=$Value[$key] }
                else { $item=$Value.$key }
                $map[$safeKey]=Protect-QuietValue $item $State ($Depth+1)
            }
        }
        return [pscustomobject]$map
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items=[Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            if ($items.Count -ge 1000) { $State.Limited=$true; break }
            $items.Add((Protect-QuietValue $item $State ($Depth+1)))
        }
        return ,$items.ToArray()
    }
    $State.Limited=$true; return '[omitted: unsupported type]'
}

function New-QuietResult {
    [CmdletBinding()]
    param([string]$Summary='Command completed.',
          [ValidateSet('Success','Failed','Timeout','Unsupported')][string]$Outcome='Success',
          [AllowNull()]$Data=$null, [Collections.IDictionary]$Execution=@{}, [AllowNull()]$ErrorInfo=$null,
          [string[]]$Reasons=@(), [ValidateRange(1024,65536)][int]$MaxOutputBytes=4096)
    $state=@{Limited=$false;Redacted=$false;Secrets=@(Get-ChildItem Env: | Where-Object {
        $_.Name -match '(?i)password|secret|token|api_?key|connectionstring' -and $_.Value.Length -ge 8
    } | ForEach-Object Value)}
    $safe=Protect-QuietValue $Data $state
    $executionSafe=Protect-QuietValue $Execution $state
    $errorSafe=Protect-QuietValue $ErrorInfo $state
    $summarySafe=([string](Protect-QuietValue $Summary $state)) -replace '[\r\n]+',' '
    $summarySafe=$summarySafe.Substring(0,[Math]::Min(160,$summarySafe.Length))
    $reasonsSafe=[Collections.Generic.List[string]]::new()
    foreach ($reason in $Reasons | Select-Object -First 6) {
        $text=[string](Protect-QuietValue $reason $state)
        $text=$text.Substring(0,[Math]::Min(40,$text.Length))
        if (!$reasonsSafe.Contains($text)) { $reasonsSafe.Add($text) }
    }
    if ($state.Limited) { $reasonsSafe.Add('FieldLimit') }
    if ($state.Redacted) { $reasonsSafe.Add('SensitiveData') }
    $result=[pscustomobject][ordered]@{
        SchemaVersion=1; Summary=$summarySafe; Outcome=$Outcome; Data=$safe
        Execution=$executionSafe; Error=$errorSafe
        Truncation=[pscustomobject]@{Applied=($reasonsSafe.Count -gt 0);Reasons=$reasonsSafe.ToArray()}
    }
    $json=ConvertTo-Json -InputObject $result -Depth 24 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxOutputBytes) {
        $result.Data=$null
        $result.Truncation.Applied=$true
        $result.Truncation.Reasons=@($result.Truncation.Reasons | Select-Object -First 7)+@('OutputBudget')
        if ($result.Error) {
            $code=if ($result.Error.PSObject.Properties['Code']) { [string]$result.Error.Code } else { 'DetailsOmitted' }
            $result.Error=[pscustomobject]@{Code=$code.Substring(0,[Math]::Min(80,$code.Length));DetailsOmitted=$true}
        }
        $json=ConvertTo-Json -InputObject $result -Depth 24 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxOutputBytes) {
            $core=[ordered]@{}
            foreach ($key in @('ExitCode','ElapsedMs','AnalysisComplete','Steps','Failed','Timeouts','Unsupported','Truncated','ScriptErrors')) {
                if ($result.Execution.PSObject.Properties[$key]) {
                    $value=$result.Execution.$key
                    $core[$key]=if ($null -eq $value -or
                        ($value -is [ValueType] -and [Text.Encoding]::UTF8.GetByteCount(
                            (ConvertTo-Json -InputObject $value -Depth 24 -Compress)) -le 64)) {$value} else {'[omitted]'}
                }
            }
            $result.Execution=[pscustomobject]$core
            $result.Summary='Result details omitted to fit the output budget.'
            $result.Truncation.Reasons=@('OutputBudget')
        }
    }
    $json=ConvertTo-Json -InputObject $result -Depth 24 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxOutputBytes) {
        $complete=$result.Execution.PSObject.Properties['AnalysisComplete']
        $result.Execution=[pscustomobject]@{
            ExitCode=$null; AnalysisComplete=($complete -and $complete.Value -is [bool] -and $complete.Value)
            MetadataOmitted=$true
        }
        $result.Error=$(if ($result.Error) { [pscustomobject]@{Code='DetailsOmitted';DetailsOmitted=$true} } else { $null })
        $json=ConvertTo-Json -InputObject $result -Depth 24 -Compress
    }
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxOutputBytes) {
        throw 'The minimal QuietCli envelope exceeds the output budget.'
    }
    $result.PSObject.TypeNames.Insert(0,'QuietCli.Result')
    return $result
}

function ConvertTo-QuietJson {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$InputObject,
          [ValidateRange(1024,65536)][int]$MaxOutputBytes=4096)
    process {
        $execution=[ordered]@{}
        foreach ($p in $InputObject.Execution.PSObject.Properties) { $execution[$p.Name]=$p.Value }
        $safe=New-QuietResult -Summary $InputObject.Summary -Outcome $InputObject.Outcome -Data $InputObject.Data `
            -Execution $execution -ErrorInfo $InputObject.Error -Reasons @($InputObject.Truncation.Reasons) -MaxOutputBytes $MaxOutputBytes
        ConvertTo-Json -InputObject $safe -Depth 24 -Compress
    }
}

function Invoke-QuietCli {
    [CmdletBinding(DefaultParameterSetName='Document')]
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList=@(),
          [string]$WorkingDirectory=(Get-Location).Path,
          [Parameter(Mandatory,ParameterSetName='Document')][scriptblock]$Parse,
          [Parameter(Mandatory,ParameterSetName='Streaming')][scriptblock]$OnRecord,
          [Parameter(Mandatory,ParameterSetName='Streaming')][object]$State,
          [Parameter(Mandatory,ParameterSetName='Streaming')][scriptblock]$Complete,
          [char]$RecordDelimiter="`n", [int[]]$SuccessExitCodes=@(0),
          [ValidateRange(1,86400)][int]$TimeoutSeconds=600,
          [ValidateRange(1024,1048576)][int]$MaxCaptureCharacters=262144,
          [ValidateRange(1024,1048576)][int]$MaxRecordCharacters=65536,
          [ValidateRange(1024,65536)][int]$MaxOutputBytes=4096,
          [string]$Summary='Native command processed.')
    $ProgressPreference='SilentlyContinue'
    $streaming=$PSCmdlet.ParameterSetName -eq 'Streaming'
    $failedParser=$false; $data=$null; $session=$null; $capture=$null
    try {
        $session=[QuietCliStack.V1.NativeSession]::new($FilePath,$ArgumentList,$WorkingDirectory,$TimeoutSeconds,
            $streaming,$MaxCaptureCharacters,$MaxRecordCharacters,$RecordDelimiter)
        while ($null -ne ($record=$session.Next())) {
            if (!$failedParser) {
                try {
                    $emitted=0
                    & $OnRecord $record $State *>&1 | ForEach-Object { $emitted++ }
                    if ($emitted -ne 0) { throw 'OnRecord must only update state.' }
                } catch { $failedParser=$true }
            }
        }
        $capture=$session.Result
        if (!$failedParser -and !$capture.StartError -and !$capture.TimedOut -and
            !(!$streaming -and $capture.CaptureTruncated)) {
            try {
                $values=@(if ($streaming) { & $Complete $State $capture *>&1 } else { & $Parse $capture *>&1 })
                if ($values.Count -gt 1) { throw 'Parser must return one object; return arrays with a unary comma.' }
                if ($values.Count -eq 1) {
                    if ($values[0] -is [Management.Automation.ErrorRecord] -or $values[0] -is [Management.Automation.InformationalRecord] -or
                        $values[0] -is [Management.Automation.InformationRecord] -or [object]::ReferenceEquals($values[0],$capture)) {
                        throw 'Parser returned a diagnostic stream or a raw capture.'
                    }
                    $data=$values[0]
                }
            } catch { $failedParser=$true }
        }
    } catch {
        return New-QuietResult -Summary 'Companion execution failed.' -Outcome Failed `
            -Execution @{ExitCode=$null;AnalysisComplete=$false} -ErrorInfo @{Code='ExecutionFailed'} -MaxOutputBytes $MaxOutputBytes
    } finally { if ($session) { $session.Dispose() } }
    $reasons=@(); $code=$null; $outcome='Success'
    if ($capture.TimedOut) { $outcome='Timeout';$code='Timeout' }
    elseif ($capture.StartError) { $outcome='Failed';$code='NativeStartOrReadFailed' }
    elseif ($failedParser) { $outcome='Failed';$code='ParserFailed' }
    elseif ($streaming -and $capture.LostRecords -gt 0) { $outcome='Failed';$code='RecordLimit';$reasons=@('RecordLimit') }
    elseif (!$streaming -and $capture.CaptureTruncated) { $outcome='Failed';$code='CaptureLimit';$reasons=@('CaptureLimit') }
    elseif ($capture.ExitCode -notin $SuccessExitCodes) { $outcome='Failed';$code='NativeFailed' }
    $execution=@{ExitCode=$capture.ExitCode;ElapsedMs=$capture.ElapsedMs;AnalysisComplete=($outcome -eq 'Success');
        StdoutCharacters=$capture.StdoutCharacters;StderrCharacters=$capture.StderrCharacters;LostRecords=$capture.LostRecords}
    New-QuietResult -Summary $Summary -Outcome $outcome -Data $data -Execution $execution `
        -ErrorInfo $(if ($code) { @{Code=$code} } else { $null }) -Reasons $reasons -MaxOutputBytes $MaxOutputBytes
}

function Add-QuietStep {
    param($Task, $Result, [string]$Name)
    $seen=$null
    if ($Task.Seen.TryGetValue($Result,[ref]$seen)) { return }
    $Task.Seen.Add($Result,[object]::new()); $Task.Steps++
    switch ($Result.Outcome) {
        Failed { $Task.Failed++ }; Timeout { $Task.Timeouts++ }; Unsupported { $Task.Unsupported++ }
    }
    if ($Result.Truncation.Applied) { $Task.Truncated++ }
    if ($Result.Outcome -ne 'Success' -and $Task.Issues.Count -lt 3) {
        $Task.Issues.Add(@{Step=$Name;Outcome=$Result.Outcome;Code=$(if ($Result.Error) {$Result.Error.Code} else {$null})})
    }
}

function Invoke-QuietStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    if (!$script:Tasks.Count) { throw 'Invoke-QuietStep requires Invoke-QuietTask.' }
    $task=$script:Tasks.Peek();$count=0;$result=$null
    try {
        & $ScriptBlock *>&1 | ForEach-Object { if (++$count -eq 1) { $result=$_ } }
        if ($count -ne 1 -or !$result.PSObject.Properties['SchemaVersion'] -or $result.SchemaVersion -ne 1 -or
            $result.Outcome -notin @('Success','Failed','Timeout','Unsupported') -or
            !$result.PSObject.Properties['Truncation'] -or !$result.PSObject.Properties['Data']) {
            throw 'A step must return one common result.'
        }
    } catch {
        $result=New-QuietResult -Summary 'Task step failed.' -Outcome Failed -Execution @{AnalysisComplete=$false} `
            -ErrorInfo @{Code='StepFailed'} -MaxOutputBytes $task.Budget
    }
    Add-QuietStep $task $result $Name
    return $result
}

function Invoke-QuietTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList=@(),
          [ValidateRange(1,1000)][int]$MaxItems=20,
          [ValidateRange(1024,65536)][int]$MaxOutputBytes=4096,[switch]$AsJson)
    $ProgressPreference='SilentlyContinue'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $task=@{Steps=0;Failed=0;Timeouts=0;Unsupported=0;Truncated=0;ScriptErrors=0;Budget=$MaxOutputBytes;
        Seen=[Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new();Issues=[Collections.Generic.List[object]]::new()}
    $projection=[Collections.Generic.List[object]]::new();$produced=0L
    $script:Tasks.Push($task)
    try {
        & $ScriptBlock @ArgumentList *>&1 | ForEach-Object {
            $value=$_
            if ($value -is [Management.Automation.ErrorRecord] -or $value -is [Management.Automation.InformationalRecord] -or
                $value -is [Management.Automation.InformationRecord]) { $task.ScriptErrors++;return }
            if ($value.PSObject.Properties['SchemaVersion'] -and $value.PSObject.Properties['Outcome'] -and
                $value.PSObject.Properties['Truncation']) { Add-QuietStep $task $value 'Output';return }
            $produced++
            if ($projection.Count -lt $MaxItems) {
                $bounded=New-QuietResult -Data $value -MaxOutputBytes $MaxOutputBytes
                $projection.Add($bounded.Data)
                if ($bounded.Truncation.Applied) { $task.Truncated++ }
            }
        }
    } catch { $task.ScriptErrors++ }
    finally { [void]$script:Tasks.Pop();$watch.Stop() }
    $outcome=if ($task.Timeouts) {'Timeout'} elseif ($task.Failed -or $task.ScriptErrors) {'Failed'} elseif ($task.Unsupported) {'Unsupported'} else {'Success'}
    $data=$null
    if ($projection.Count -eq 1) { $data=$projection[0] }
    elseif ($projection.Count -gt 1) { $data=$projection.ToArray() }
    $reasons=@();if ($task.Truncated) {$reasons+=@('IntermediateTruncation')};if ($produced -gt $projection.Count) {$reasons+=@('TaskItemLimit')}
    $result=New-QuietResult -Summary "Task: $($task.Steps) steps; $($task.Failed) failed; $($task.Timeouts) timed out." `
        -Outcome $outcome -Data $data -Execution @{ExitCode=$null;ElapsedMs=$watch.ElapsedMilliseconds;
            AnalysisComplete=($outcome -eq 'Success');Steps=$task.Steps;Failed=$task.Failed;Timeouts=$task.Timeouts;
            Unsupported=$task.Unsupported;Truncated=$task.Truncated;ScriptErrors=$task.ScriptErrors} `
        -ErrorInfo $(if ($outcome -ne 'Success') {@{Code='TaskFailed';Issues=$task.Issues.ToArray()}} else {$null}) `
        -Reasons $reasons -MaxOutputBytes $MaxOutputBytes
    if ($AsJson) { ConvertTo-QuietJson $result -MaxOutputBytes $MaxOutputBytes } else { $result }
}

Export-ModuleMember -Function New-QuietResult,Invoke-QuietCli,Invoke-QuietTask,Invoke-QuietStep,ConvertTo-QuietJson
