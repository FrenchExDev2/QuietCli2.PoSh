function Add-QuietTaskResult {
    param($Result)
    foreach($task in $script:QuietTasks){if($task.Seen.Add($Result.Internal.Id)){$task.Results.Add($Result)}}
}
function New-QuietResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory value; no external state is changed.')]
    [CmdletBinding()]param([string]$Summary='Command completed.',
        [ValidateSet('Success','Failed','Timeout','Cancelled','Unsupported')][string]$Outcome='Success',
        [AllowNull()]$Data=$null,[Collections.IDictionary]$Execution=@{},[AllowNull()]$ErrorInfo=$null,
        [string[]]$Reasons=@(),[scriptblock]$Projection,[int]$MaxOutputBytes=4096,[switch]$NoRegister)
    $result=[pscustomobject][ordered]@{
        SchemaVersion=2;Summary=$Summary;Outcome=$Outcome;Data=$Data;Execution=[pscustomobject]$Execution;Error=$ErrorInfo
        Completeness=[pscustomobject]@{Source=($Outcome -eq 'Success');Analysis=($Outcome -eq 'Success');Capture=$true}
        Truncation=[pscustomobject]@{Applied=($Reasons.Count -gt 0);Reasons=@($Reasons);Omitted=0L}
        Measurement=[pscustomobject]@{Status='NotDelivered';Profile=$null;Version=$null}
        Capture=$null;Projection=$Projection;RecordId=$null
        Internal=@{PresentationMs=0.0;RecallMs=0.0;Id=[guid]::NewGuid().ToString('N');Sources=[ordered]@{};DeliveryPaths=[Collections.Generic.HashSet[string]]::new();Origin=$null;Records=@();PresentationBudget=$(if($PSBoundParameters.ContainsKey('MaxOutputBytes')){$MaxOutputBytes}else{$null})}
    }
    $result.PSObject.TypeNames.Insert(0,'QuietCli.Result')
    if(!$NoRegister -and !$script:QuietBuildingContract){Add-QuietTaskResult $result}
    $result
}
function Invoke-QuietStep {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    if(!$script:QuietTasks.Count){throw 'Invoke-QuietStep requires Invoke-QuietTask.'}
    try{
        $items=@(Invoke-QuietCallback $ScriptBlock)
        if($items.Count -ne 1 -or $items[0].PSObject.TypeNames -notcontains 'QuietCli.Result'){throw 'A step must return one QuietCli result.'}
        $result=$items[0];$result.Execution|Add-Member -NotePropertyName Step -NotePropertyValue $Name -Force
        Add-QuietTaskResult $result
        $result
    }catch{New-QuietResult -Summary "Step $Name failed." -Outcome Failed -ErrorInfo @{Code='StepFailed';Message=$_.Exception.Message}}
}
function Invoke-QuietTask {
    [CmdletBinding()]param([Parameter(Mandatory)][scriptblock]$ScriptBlock,[object[]]$ArgumentList=@(),
        [int]$MaxItems=20,[int]$MaxOutputBytes=4096,[switch]$AsJson,[switch]$AsYaml,[switch]$AsObject,[switch]$Record)
    if(@($AsObject,$AsJson,$AsYaml|Where-Object {$_}).Count -gt 1){throw 'AsObject, AsJson and AsYaml are exclusive.'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $task=@{Results=[Collections.Generic.List[object]]::new();Seen=[Collections.Generic.HashSet[string]]::new();Record=[bool]$Record}
    $script:QuietTasks.Push($task);$failure=$null;$values=@()
    try{$values=@(Invoke-QuietCallback $ScriptBlock $ArgumentList|Where-Object {$_.PSObject.TypeNames -notcontains 'QuietCli.Result'})}
    catch{$failure=@{Code='TaskFailed';Message=$_.Exception.Message}}
    finally{[void]$script:QuietTasks.Pop()}
    $issues=@($task.Results|Where-Object Outcome -ne 'Success')
    $outcome=if($issues.Count){$issues[0].Outcome}elseif($failure){'Failed'}else{'Success'}
    $data=if($values.Count -eq 1){$values[0]}elseif($values.Count){,$values}else{$null}
    $result=New-QuietResult -Summary "Task: $($task.Results.Count) steps." -Outcome $outcome -Data $data -ErrorInfo $failure -NoRegister -Execution @{
        Steps=$task.Results.Count;ElapsedMs=$watch.Elapsed.TotalMilliseconds;ExitCode=$null
        AnalysisComplete=(!$failure -and @($task.Results|Where-Object {!$_.Completeness.Analysis}).Count -eq 0)
        Issues=@($issues|Select-Object -First 20|ForEach-Object {@{Outcome=$_.Outcome;Error=$_.Error;ExitCode=$_.Execution.ExitCode}})
    }
    foreach($step in $task.Results){foreach($key in $step.Internal.Sources.Keys){$result.Internal.Sources[$key]=$step.Internal.Sources[$key]}}
    $result.Completeness.Source=(@($task.Results|Where-Object {!$_.Completeness.Source}).Count -eq 0)
    $result.Completeness.Analysis=$result.Execution.AnalysisComplete
    $result.Completeness.Capture=(@($task.Results|Where-Object {!$_.Completeness.Capture}).Count -eq 0)
    if($Record){$result.Internal.Records=@($task.Results.RecordId|Where-Object {$_});Save-QuietRecord $result -Explicit|Out-Null}
    if($AsJson -or $AsYaml){Out-QuietResult -InputObject $result -AsYaml:$AsYaml -MaxItems $MaxItems -MaxOutputBytes $MaxOutputBytes}else{$result}
}
function ConvertTo-QuietYaml {
    param($Value,[int]$Indent=0)
    $pad=' '*$Indent
    if($null -eq $Value){return 'null'}
    if($Value -is [string] -or $Value -is [ValueType]){return ConvertTo-Json -InputObject $Value -Compress -Depth 64}
    if($Value -is [Collections.IDictionary] -or ($Value -is [pscustomobject] -and $Value -isnot [Collections.IEnumerable])){
        $keys=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
        if(!$keys.Count){return '{}'}
        $lines=foreach($key in $keys){
            $child=$Value.$key;$name=ConvertTo-Json ([string]$key) -Compress
            $rendered=ConvertTo-QuietYaml $child ($Indent+2)
            if($rendered -notin @('{}','[]') -and ($child -is [Collections.IDictionary] -or $child -is [pscustomobject] -or ($child -is [Collections.IEnumerable] -and $child -isnot [string] -and @($child).Count))){
                ('{0}{1}:' -f $pad,$name)+[Environment]::NewLine+$rendered
            }else{('{0}{1}: {2}' -f $pad,$name,$rendered)}
        }
        return $lines -join [Environment]::NewLine
    }
    $items=@($Value);if(!$items.Count){return '[]'}
    $lines=foreach($item in $items){$rendered=ConvertTo-QuietYaml $item ($Indent+2);if($rendered -in @('{}','[]') -or $item -is [ValueType] -or $item -is [string] -or $null -eq $item){"$pad- $rendered"}else{"$pad-"+[Environment]::NewLine+$rendered}}
    $lines -join [Environment]::NewLine
}
function Limit-QuietProjection {
    [CmdletBinding()]param([Parameter(Mandatory)]$Data,[Parameter(Mandatory)][string[]]$Property,[int]$MaxItems=20)
    $copy=[ordered]@{}
    if($Data -is [Collections.IDictionary]){foreach($key in $Data.Keys){$copy[$key]=$Data[$key]}}else{foreach($p in $Data.PSObject.Properties){$copy[$p.Name]=$p.Value}}
    $omitted=[ordered]@{}
    foreach($name in $Property){if($null -ne $copy[$name]){$list=@($copy[$name]);$copy[$name]=@($list|Select-Object -First $MaxItems);if($list.Count -gt $MaxItems){$omitted[$name]=$list.Count-$MaxItems}}}
    if($omitted.Count){$copy['Omitted']=[pscustomobject]$omitted}
    $projection=[pscustomobject]$copy;$projection.PSObject.TypeNames.Insert(0,'QuietCli.Projection');$projection
}
function Out-QuietResult {
    [CmdletBinding()]param([Parameter(Mandatory,ValueFromPipeline)]$InputObject,[switch]$AsJson,[switch]$AsYaml,
        [int]$MaxItems=-1,[int]$MaxOutputBytes=-1,[int]$ExcerptLines=-1,[ValidateSet('compact','full')][string]$Envelope)
    process{
        $deliveryWatch=[Diagnostics.Stopwatch]::StartNew()
        $settings=Get-QuietConfiguration
        if($MaxItems -lt 0){$MaxItems=$settings.MaxItems};if($MaxOutputBytes -lt 0){$MaxOutputBytes=$settings.MaxOutputBytes}
        if($ExcerptLines -lt 0){$ExcerptLines=$settings.ExcerptLines};if(!$Envelope){$Envelope=$settings.Envelope}
        if($MaxOutputBytes -lt 256 -or $MaxItems -lt 0){throw 'Invalid delivery limits.'}
        $result=if($InputObject.PSObject.TypeNames -contains 'QuietCli.Result'){$InputObject}else{New-QuietResult -Data $InputObject -NoRegister}
                if(!$PSBoundParameters.ContainsKey('MaxOutputBytes') -and $result.Internal.PresentationBudget){$MaxOutputBytes=$result.Internal.PresentationBudget}
        $data=$result.Data;$reasons=[Collections.Generic.List[string]]::new();foreach($reason in $result.Truncation.Reasons){$reasons.Add($reason)}
        if($result.Projection){try{$projected=@(Invoke-QuietCallback $result.Projection @($result.Data,@{MaxItems=$MaxItems;MaxOutputBytes=$MaxOutputBytes}));$data=if($projected.Count -eq 1){$projected[0]}elseif($projected.Count){,$projected}else{$null}}catch{$data=$null;$reasons.Add('ProjectionFailed')}}
                $omitted=[long]$result.Truncation.Omitted
        if($data -and $data.PSObject.TypeNames -contains 'QuietCli.Projection' -and $data.PSObject.Properties['Omitted']){
            $reasons.Add('ProjectionItemLimit');foreach($property in $data.Omitted.PSObject.Properties){$omitted+=[long]$property.Value}
        }
        if($data -is [Collections.IEnumerable] -and $data -isnot [string] -and $data -isnot [Collections.IDictionary]){
            $all=@($data);if($all.Count -gt $MaxItems){$data=@($all|Select-Object -First $MaxItems);$omitted+=$all.Count-$MaxItems;$reasons.Add('ItemLimit')}
        }
        $state=@{Limited=$false;Redacted=$false};$safeData=Protect-QuietValue $data $state;$errorInfo=Protect-QuietValue $result.Error $state
        $execution=[ordered]@{}
        foreach($name in @('ExitCode','ElapsedMs','Steps','Issues')){if($result.Execution.PSObject.Properties[$name]){$execution[$name]=Protect-QuietValue $result.Execution.$name $state}}
        $document=[ordered]@{SchemaVersion=2;Summary=(Protect-QuietValue $result.Summary $state);Outcome=$result.Outcome;Data=$safeData
            Execution=[pscustomobject]$execution;Completeness=$result.Completeness;Error=$errorInfo
            Truncation=[ordered]@{Applied=($reasons.Count -gt 0);Reasons=@($reasons);Omitted=$omitted}}
        if($result.Outcome -ne 'Success' -and $result.Capture -and $ExcerptLines){
            $excerpt=[ordered]@{}
            foreach($stream in @('stdout','stderr')){
                $text=if($result.Capture.CaptureComplete){$result.Capture.ReadText($stream)}else{$result.Capture.ReadTail($stream) -join [char]10}
                if($text){$tail=@(($text -split '\r?\n')|Select-Object -Last $ExcerptLines|ForEach-Object{if($_.Length -gt 1000){$_.Substring(0,1000)+'…'}else{$_}});$excerpt[$stream]=Protect-QuietValue $tail $state}
            }
            if($excerpt.Count){$document['Excerpt']=$excerpt}
        }
        if($settings.Recall -and $result.Internal.Sources.Count -and !$result.RecordId){Save-QuietRecord $result|Out-Null}
        if($result.RecordId){$document['RecordId']=$result.RecordId}
        if($state.Limited){$reasons.Add('ProtectionLimit')}
        $document.Truncation.Applied=($reasons.Count -gt 0);$document.Truncation.Reasons=@($reasons|Select-Object -Unique)
        if($Envelope -eq 'compact'){
            if(!$document.Error){$document.Remove('Error')}
            if(!$document.Truncation.Applied){$document.Remove('Truncation')}
            if($result.Completeness.Source -and $result.Completeness.Analysis -and $result.Completeness.Capture){$document.Remove('Completeness')}
        }
        $yaml=$AsYaml -or (!$AsJson -and $settings.OutputFormat -eq 'yaml')
        $serialize={if($yaml){ConvertTo-QuietYaml ([pscustomobject]$document)}else{ConvertTo-Json -InputObject $document -Depth 64 -Compress}}
        $text=& $serialize
        if([Text.Encoding]::UTF8.GetByteCount($text) -gt $MaxOutputBytes){
            $document.Data=$null;$document['Truncation']=@{Applied=$true;Reasons=@($reasons)+@('OutputBudget');Omitted=$omitted}
            $document.Remove('Excerpt');$text=& $serialize
            if([Text.Encoding]::UTF8.GetByteCount($text) -gt $MaxOutputBytes){$document.Remove('Summary');$document.Execution=@{ExitCode=$result.Execution.ExitCode};$document.Error=if($result.Error){@{Code=$result.Error.Code}}else{$null};$text=& $serialize}
            if([Text.Encoding]::UTF8.GetByteCount($text) -gt $MaxOutputBytes){$document=[ordered]@{SchemaVersion=2;Outcome=$result.Outcome;Truncation=@{Applied=$true;Reasons=@('MetadataLimit')}};$text=& $serialize}
        }
        $result.Internal.PresentationMs=$deliveryWatch.Elapsed.TotalMilliseconds
        Save-QuietDelivery $result $text $document
        $text
    }
}
function ConvertTo-QuietJson {
    [CmdletBinding()]param([Parameter(Mandatory,ValueFromPipeline)]$InputObject,[int]$MaxOutputBytes=4096,[int]$MaxItems=20)
    process{Out-QuietResult -InputObject $InputObject -AsJson -MaxOutputBytes $MaxOutputBytes -MaxItems $MaxItems}
}
