function Save-QuietEvent {
    param([string]$Id,[string]$Kind,[string]$Command,$Payload)
    $json=ConvertTo-Json -InputObject $Payload -Depth 64 -Compress
    Invoke-QuietSql 'INSERT OR REPLACE INTO quietcli_v2_events(id,kind,timestamp_ms,command,payload) VALUES(?,?,?,?,?)' @($Id,$Kind,[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(),$Command,$json)
}
function Compress-QuietText {
    param([AllowNull()][string]$Text)
    $buffer=[IO.MemoryStream]::new();$zip=[IO.Compression.GZipStream]::new($buffer,[IO.Compression.CompressionLevel]::Optimal,$true)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($Text);$zip.Write($bytes,0,$bytes.Length)}finally{$zip.Dispose()}
    try{[Convert]::ToBase64String($buffer.ToArray())}finally{$buffer.Dispose()}
}
function Expand-QuietText {
    param([string]$Text)
    if(!$Text){return ''}
    $memory=[IO.MemoryStream]::new([Convert]::FromBase64String($Text))
    $zip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Decompress)
    $reader=[IO.StreamReader]::new($zip,[Text.UTF8Encoding]::new($false))
    try{$reader.ReadToEnd()}finally{$reader.Dispose()}
}
function Save-QuietRecord {
    param($Result,[switch]$Explicit)
    if(!$Result.Internal.Sources.Count -and !$Result.Internal.Records.Count){return}
    try{
        $settings=Get-QuietConfiguration;$protection=@{Limited=$false;Redacted=$false}
        $sources=@(foreach($source in $Result.Internal.Sources.Values){
                        $capture=$source.Capture
            $request=$source.Request.Clone();$argv=@($request.ArgumentList)
            for($i=0;$i -lt $argv.Count;$i++){
                if($argv[$i] -match '^--?(?:password|passwd|secret|token|api[-_]?key)$' -and $i+1 -lt $argv.Count){$argv[++$i]='[REDACTED]';$protection.Redacted=$true}
            }
            $request.ArgumentList=$argv
            $copies=@(foreach($path in @($source.SourcePaths|Select-Object -Unique)){
                if(!$path -or !(Test-Path -LiteralPath $path -PathType Leaf)){continue}
                $content=Get-Content -LiteralPath $path -Raw
                $maskState=@{Limited=$false;Redacted=$false}
                $safeContent=Protect-QuietValue $content $maskState
                @{Name=[IO.Path]::GetFileName($path);SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    Text=$safeContent;Bytes=$(if(!$maskState.Redacted -and !$maskState.Limited){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}else{$null});ModifiedByMasking=($maskState.Redacted -or $maskState.Limited);Path=(Resolve-Path -LiteralPath $path).Path}
            })
            $streams=@{}
            foreach($name in @('stdout','stderr')){$text=if($capture){$capture.ReadText($name)}else{''};$streams[$name]=Compress-QuietText (Protect-QuietValue $text $protection)}
            @{Id=$source.Id;Command=$source.Command;Request=(Protect-QuietValue $request $protection)
                                OriginalRequest=$(if($source.ContainsKey('OriginalRequest')){
                    $original=$source.OriginalRequest.Clone();$words=@($original.ArgumentList)
                    for($j=0;$j -lt $words.Count;$j++){if($words[$j] -match '^--?(?:password|passwd|secret|token|api[-_]?key)$' -and $j+1 -lt $words.Count){$words[++$j]='[REDACTED]';$protection.Redacted=$true}}
                    $original.ArgumentList=$words;Protect-QuietValue $original $protection
                }else{$null})
                Contract=$source.Contract;Documentation=@($source.Documentation);ObservedVersion=$source.ObservedVersion
                Sources=$copies;Promotable=($copies.Count -gt 0 -and $copies.Count -eq @($source.SourcePaths|Select-Object -Unique).Count -and @($copies|Where-Object ModifiedByMasking).Count -eq 0)
                Encoding=$source.Encoding;RecordDelimiter=$source.RecordDelimiter;StdErrDelimiter=$source.StdErrDelimiter
                SourceComplete=$source.SourceComplete;AnalysisComplete=$source.AnalysisComplete
                CaptureComplete=[bool]($capture -and $capture.CaptureComplete);Lossy=[bool]($capture -and $capture.Lossy)
                                Outcome=$source.Outcome;ExitCode=$source.ExitCode;Bytes=$source.Bytes;Streams=$streams
                RecordOrderComplete=[bool]($capture -and $capture.JournalComplete)
                                Frames=$(if($capture -and $capture.JournalComplete){
                    $frames=@($capture.ReadRecords()|ForEach-Object {[pscustomobject]@{Stream=$_.Stream;Text=$_.Text;Sequence=$_.Sequence;Truncated=$_.Truncated}})
                    $safeFrames=Protect-QuietValue $frames $protection
                    Compress-QuietText (ConvertTo-Json -InputObject $safeFrames -Depth 10 -Compress)
                }else{$null})}
        })
        $id=$Result.Internal.Id.Substring(0,12)
        $payload=@{SchemaVersion=2;Id=$id;TimestampUtc=[DateTimeOffset]::UtcNow.ToString('o');Explicit=[bool]$Explicit
            Outcome=$Result.Outcome;Completeness=$Result.Completeness;Sources=$sources;Children=@($Result.Internal.Records)
            Promotable=($sources.Count -gt 0 -and @($sources|Where-Object {!$_.Promotable}).Count -eq 0)
            Data=(Protect-QuietValue $Result.Data $protection);Masked=$protection.Redacted}
        if($protection.Limited){throw 'Masking could not preserve a complete record.'}
        $command=if($sources.Count -eq 1){$sources[0].Command}else{'task'}
        Save-QuietEvent $id record $command $payload
        $cutoff=[DateTimeOffset]::UtcNow.AddDays(-$settings.RecallRetentionDays).ToUnixTimeMilliseconds()
        Invoke-QuietSql "DELETE FROM quietcli_v2_events WHERE kind='record' AND (timestamp_ms < ? OR id NOT IN (SELECT id FROM quietcli_v2_events WHERE kind='record' ORDER BY timestamp_ms DESC,id DESC LIMIT ?))" @($cutoff,$settings.RecallMaxEntries)
        $Result.RecordId=$id
        return $id
    }catch{$script:LastGainError=$_.Exception.GetBaseException().Message;$Result.Measurement.Status='RecordUnavailable'}
}
function Read-QuietRecord {
    param([Parameter(Mandatory)][string]$Id)
    $rows=@(Invoke-QuietSql -Read -Sql "SELECT payload FROM quietcli_v2_events WHERE id=? AND kind='record'" -Values @($Id))
    if(!$rows.Count){throw "Unknown or expired QuietCli record: $Id"}
    $rows[0]['payload']|ConvertFrom-Json -AsHashtable -Depth 64
}
function Get-QuietRecord {
    [CmdletBinding()]param([string]$Id,[switch]$List,[switch]$AsObject,[ValidateSet('stdout','stderr')][string]$Stream,
        [int]$SourceIndex=0,[int]$From=1,[int]$Lines=20,[string]$Grep,[int]$MaxItems=20,[int]$MaxOutputBytes=4096)
    try{
        if($List -or !$Id){
            $rows=@(Invoke-QuietSql -Read -Sql "SELECT id,timestamp_ms,command,payload FROM quietcli_v2_events WHERE kind='record' ORDER BY timestamp_ms DESC,id DESC LIMIT ?" -Values @($MaxItems))
            $data=@($rows|ForEach-Object {$p=$_.payload|ConvertFrom-Json;[pscustomobject]@{Id=$_.id;Command=$_.command;TimestampUtc=$p.TimestampUtc;Outcome=$p.Outcome;Promotable=$p.Promotable;Explicit=$p.Explicit}})
        }else{
            $record=Read-QuietRecord $Id
            if($AsObject){return $record}
            if($Stream){
                if($From -lt 1 -or $Lines -lt 0 -or $SourceIndex -lt 0 -or $SourceIndex -ge $record.Sources.Count){throw 'Invalid record window.'}
                $text=Expand-QuietText $record.Sources[$SourceIndex].Streams[$Stream]
                $all=@($text -split '\r?\n');$selected=[Collections.Generic.List[object]]::new()
                for($i=$From-1;$i -lt $all.Count -and $selected.Count -lt $Lines;$i++){if(!$Grep -or $all[$i] -match $Grep){$selected.Add(@{Line=$i+1;Text=$all[$i]})}}
                $data=@{Id=$Id;Stream=$Stream;TotalLines=$all.Count;Lines=$selected.ToArray();CaptureComplete=$record.Sources[$SourceIndex].CaptureComplete}
            }else{$data=@{Id=$Id;Outcome=$record.Outcome;Completeness=$record.Completeness;Promotable=$record.Promotable;Sources=@($record.Sources|ForEach-Object {@{Command=$_.Command;Contract=$_.Contract;Request=$_.Request;Documentation=$_.Documentation;CaptureComplete=$_.CaptureComplete}})}}
            if((Get-QuietConfiguration).Tracking){Save-QuietEvent ([guid]::NewGuid().ToString('N')) recall 'record' @{RecordId=$Id}}
        }
        $result=New-QuietResult -Data $data -NoRegister
    }catch{$result=New-QuietResult -Outcome Failed -ErrorInfo @{Code='RecordReadFailed';Message=$_.Exception.Message} -NoRegister}
    if($AsObject){$result}else{Out-QuietResult $result -MaxItems $MaxItems -MaxOutputBytes $MaxOutputBytes}
}
function Invoke-QuietCapturedCall {
    param([Parameter(Mandatory)]$Source,[Parameter(Mandatory)]$Contract)
    if(!$Source.CaptureComplete -or $Source.Lossy){throw 'Cannot certify replay from an incomplete or lossy capture.'}
    $capture=[pscustomobject]@{Stdout=(Expand-QuietText $Source.Streams.stdout);Stderr=(Expand-QuietText $Source.Streams.stderr)
        SourceComplete=$Source.SourceComplete;CaptureComplete=$Source.CaptureComplete;ExitCode=$Source.ExitCode;LostRecords=0
        TimedOut=($Source.Outcome -eq 'Timeout');Cancelled=($Source.Outcome -eq 'Cancelled')}
    if($Contract.Parse){$values=@(Invoke-QuietCallback $Contract.Parse @($capture))}
    else{
        if(!$Source.RecordOrderComplete){throw 'Streaming replay requires a complete observed record order.'}
        $frames=Expand-QuietText $Source.Frames|ConvertFrom-Json
        $emissions=[Collections.Generic.List[object]]::new()
        foreach($frame in $frames){
            $items=if($Contract.OnBatch){@(Invoke-QuietCallback $Contract.OnBatch @((,@($frame)),$Contract.State))}else{@(Invoke-QuietCallback $Contract.OnOutput @($frame,$Contract.State))}
            foreach($item in $items){$emissions.Add($item)}
        }
        # Keep a single callback-produced dictionary as an item before indexing the result.
        if($Contract.Complete){$values=@(Invoke-QuietCallback $Contract.Complete @($Contract.State,$capture))}
        else{$values=@($emissions.ToArray())}
    }
    $data=if($values.Count -eq 1){$values[0]}elseif($values.Count){,$values}else{$null}
    $outcome=if($Source.ExitCode -in $Contract.SuccessExitCodes){'Success'}else{$Source.Outcome}
    $errorInfo=if($outcome -ne 'Success'){@{Code='NativeFailed';Phase='Replay'}}else{$null}
    $result=New-QuietResult -Data $data -Outcome $outcome -Projection $Contract.Projection -Execution @{ExitCode=$Source.ExitCode;Replay=$true} -ErrorInfo $errorInfo
    $result.Completeness.Source=$Source.SourceComplete;$result.Completeness.Analysis=$Source.SourceComplete
    $result
}
function Invoke-QuietRecord {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Id,[string]$ContractPath,[object]$Contract,[switch]$AsObject,[int]$MaxOutputBytes=4096)
    $previous=$script:QuietReplay;$previousContext=$script:QuietReplayContext;$script:QuietReplay=$true;$result=$null
    try{
        $record=Read-QuietRecord $Id;$results=[Collections.Generic.List[object]]::new()
        foreach($source in $record.Sources){
            $invocation=if($source.OriginalRequest){$source.OriginalRequest}else{$source.Request};$candidate=$Contract
            if($ContractPath){$candidate=Invoke-QuietFactory -Path $ContractPath -Invocation $invocation}
            elseif(!$candidate){$route=Resolve-QuietCommand $source.Command;if($route){$candidate=Invoke-QuietFactory -Factory $route.Factory -Invocation $invocation}}
            if(!$candidate -or $candidate.PSObject.TypeNames -notcontains 'QuietCli.Contract'){throw 'Replay requires an explicit applicable contract or an installed module.'}
            if($candidate.Execute){
                $queue=[Collections.Generic.Queue[object]]::new();foreach($step in $record.Sources){$queue.Enqueue($step)}
                $script:QuietReplayContext=$queue;$result=Invoke-QuietContract $candidate $invocation @{} $ContractPath
                if($queue.Count){throw 'The replay contract did not consume every recorded native call.'}
                break
            }
            $results.Add((Invoke-QuietCapturedCall $source $candidate))
        }
        if(!$result){
            if($results.Count -eq 1){$result=$results[0]}else{
                $failed=@($results|Where-Object Outcome -ne 'Success');$outcome=if($failed.Count){$failed[0].Outcome}else{'Success'}
                $result=New-QuietResult -Outcome $outcome -Data @($results|ForEach-Object Data) -NoRegister -Execution @{Steps=$results.Count;Replay=$true}
            }
        }
    }catch{$result=New-QuietResult -Outcome Failed -ErrorInfo @{Code='ReplayFailed';Message=$_.Exception.Message} -NoRegister}
    finally{$script:QuietReplay=$previous;$script:QuietReplayContext=$previousContext}
    if($AsObject){$result}else{Out-QuietResult $result -MaxOutputBytes $MaxOutputBytes}
}
