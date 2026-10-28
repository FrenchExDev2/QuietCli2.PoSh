$script:QuietTokenizers=@{}
function Register-QuietTokenizer {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][scriptblock]$Count)
    $script:QuietTokenizers[$Name]=@{Version=$Version;Count=$Count}
}
function Measure-QuietToken {
    [CmdletBinding()]param([AllowEmptyString()][string]$Text,[Alias('Profile')][string]$TokenProfile=(Get-QuietConfiguration).Tokenizer)
    if($TokenProfile -eq 'off'){return $null}
    if(!$script:QuietTokenizers.ContainsKey($TokenProfile)){
        if($TokenProfile -notin @('o200k_base','cl100k_base')){throw "Unknown tokenizer: $TokenProfile"}
        $runtime=Join-Path $script:QuietRoot 'resources/runtime'
        foreach($name in @('Microsoft.Bcl.Memory','Microsoft.ML.Tokenizers','Microsoft.ML.Tokenizers.Data.O200kBase','Microsoft.ML.Tokenizers.Data.Cl100kBase')){[void][Reflection.Assembly]::LoadFrom((Join-Path $runtime "$name.dll"))}
        $tokenizer=[Microsoft.ML.Tokenizers.TiktokenTokenizer]::CreateForEncoding($TokenProfile,$null,$null)
        $counter={param($value) $tokenizer.CountTokens([string]$value)}.GetNewClosure()
        Register-QuietTokenizer -Name $TokenProfile -Version 'Microsoft.ML.Tokenizers/2.0.0' -Count $counter
    }
    $value=& $script:QuietTokenizers[$TokenProfile].Count $Text
    if($value -isnot [ValueType] -or $value -lt 0){throw 'Tokenizer must return a nonnegative count.'}
    [pscustomobject]@{Tokens=[long]$value;Profile=$TokenProfile;Version=$script:QuietTokenizers[$TokenProfile].Version}
}
function Save-QuietInvocation {
    param($Source)
    if(!(Get-QuietConfiguration).Tracking){return}
    try{Save-QuietEvent $Source.Id invocation $Source.Command @{Id=$Source.Id;Outcome=$Source.Outcome;Bytes=$Source.Bytes;ElapsedMs=$Source.ElapsedMs;Timing=$Source.Timing;CaptureComplete=[bool]($Source.Capture -and $Source.Capture.CaptureComplete)}}
    catch{$script:LastGainError=$_.Exception.GetBaseException().Message}
}
function Save-QuietDelivery {
    param($Result,[string]$Text,$Document)
    $settings=Get-QuietConfiguration
    if(!$settings.Tracking -or $script:QuietTasks.Count -or !$Result.Internal.Sources.Count){return}
    $path=Get-QuietDatabasePath
    if($Result.Internal.DeliveryPaths.Contains($path)){return}
    try{
        $measureWatch=[Diagnostics.Stopwatch]::StartNew();$processMs=0.0;$unknownDurations=0;$setupMs=0.0;
        $bytes=0L;$tokens=0L;$known=$true;$bytesKnown=$true;$TokenProfile=$settings.Tokenizer;$version=$null;$elapsed=0.0;$callbacks=0.0;$backpressure=0.0
        foreach($source in $Result.Internal.Sources.Values){
            $bytes+=$source.Bytes;if(!$source.SourceComplete -or $source.Delivered.Contains($path)){$bytesKnown=$false};$elapsed+=$source.ElapsedMs;if($null -eq $source.Timing.ProcessMs){$unknownDurations++}else{$processMs+=$source.Timing.ProcessMs};$setupMs+=$source.Timing.SetupMs;$callbacks+=$source.Timing.CallbackMs;$backpressure+=$source.Timing.BackpressureMs
            if(!$source.Capture -or !$source.Capture.CaptureComplete -or $source.Capture.Lossy -or $source.Delivered.Contains($path)){$known=$false;continue}
            foreach($stream in @('stdout','stderr')){
                try{$count=Measure-QuietToken -Text ($source.Capture.ReadText($stream)) -Profile $TokenProfile;if($null -eq $count){$known=$false}else{$tokens+=$count.Tokens;$version=$count.Version}}catch{$known=$false;$script:LastGainError=$_.Exception.Message}
            }
        }
        $output=try{Measure-QuietToken -Text $Text -Profile $TokenProfile}catch{$null}
        if(!$output){$known=$false}
        $saved=if($known){$tokens-$output.Tokens}else{$null}
        $origin=if($Result.Internal.Origin){$Result.Internal.Origin}else{@($Result.Internal.Sources.Values)[0].Request}
        $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($origin|ConvertTo-Json -Depth 10 -Compress))))
        $row=@{Id=$Result.Internal.Id;TimestampUtc=[DateTimeOffset]::UtcNow.ToString('o');Command=$(if($Result.Internal.Sources.Count -eq 1){@($Result.Internal.Sources.Values)[0].Command}else{'task'})
            Outcome=$Result.Outcome;NativeCalls=$Result.Internal.Sources.Count;InvocationIds=@($Result.Internal.Sources.Keys)
            InputBytes=$bytes;OutputBytes=[Text.Encoding]::UTF8.GetByteCount($Text);InputTokens=$(if($known){$tokens}else{$null});OutputTokens=$(if($known){$output.Tokens}else{$null});SavedTokens=$saved
            ByteMeasured=$bytesKnown;Method='exact';Profile=$TokenProfile;Version=$version;Measured=$known;AnalysisComplete=$Result.Completeness.Analysis
            Truncated=$Document.Contains('Truncation') -and $Document.Truncation.Applied;RecordId=$Result.RecordId
                        ElapsedMs=$elapsed;TotalMs=$elapsed+$Result.Internal.PresentationMs+$measureWatch.Elapsed.TotalMilliseconds
            ProcessMs=$(if(!$unknownDurations){$processMs}else{$null});SetupMs=$setupMs
            OverheadMs=$(if(!$unknownDurations){[Math]::Max(0,$elapsed+$Result.Internal.PresentationMs+$measureWatch.Elapsed.TotalMilliseconds-$processMs+$backpressure)}else{$null})
            UnknownDurations=$unknownDurations;TokenMeasurementMs=$measureWatch.Elapsed.TotalMilliseconds;CallbackMs=$callbacks;BackpressureMs=$backpressure;Fingerprint=$fingerprint
            Session=$env:QUIETCLI_SESSION;Format=$(if($Text.TrimStart().StartsWith('{')){'json'}else{'yaml'})}
        Save-QuietEvent $Result.Internal.Id delivery $row.Command $row
        [void]$Result.Internal.DeliveryPaths.Add($path)
        foreach($source in $Result.Internal.Sources.Values){[void]$source.Delivered.Add($path)}
        $Result.Measurement.Status=if($known){'Measured'}else{'CounterUnavailable'}
        $Result.Measurement.Profile=$TokenProfile;$Result.Measurement.Version=$version
    }catch{$Result.Measurement.Status='StorageUnavailable';$script:LastGainError=$_.Exception.GetBaseException().Message}
}
function Get-QuietHistoryRow {
    param([DateTimeOffset]$From,[DateTimeOffset]$To,[string]$DatabasePath)
    $fromMs=$From.ToUnixTimeMilliseconds();$toMs=$To.ToUnixTimeMilliseconds()
    $legacy=@(Invoke-QuietSql -Read -DatabasePath $DatabasePath -Sql 'SELECT * FROM quietcli_deliveries WHERE timestamp_ms>=? AND timestamp_ms<?' -Values @($fromMs,$toMs))
    foreach($r in $legacy){[pscustomobject]@{Id=$r.id;TimestampUtc=[DateTimeOffset]::FromUnixTimeMilliseconds($r.timestamp_ms).ToString('o');Command=$r.command;Outcome=$r.outcome
        NativeCalls=[long]$r.native_calls;InputBytes=[long]$r.input_bytes;OutputBytes=[long]$r.output_bytes;InputTokens=$r.input_tokens;OutputTokens=$r.output_tokens;SavedTokens=$r.saved_tokens
        ByteMeasured=[bool]$r.measured;Method='estimate';Profile='utf8-bytes/4';Version='1';Measured=[bool]$r.measured;AnalysisComplete=[bool]$r.analysis_complete;Truncated=[bool]$r.truncated
        ElapsedMs=$r.elapsed_ms;CallbackMs=$null;BackpressureMs=$null;RecordId=$null;Fingerprint=$null;Session=$null;Format='json'}}
    try{$rows=@(Invoke-QuietSql -Read -DatabasePath $DatabasePath -Sql "SELECT payload FROM quietcli_v2_events WHERE kind='delivery' AND timestamp_ms>=? AND timestamp_ms<?" -Values @($fromMs,$toMs));foreach($row in $rows){$row.payload|ConvertFrom-Json}}
    catch{if($_.Exception.Message -notmatch 'no such table'){throw}}
}
function Get-QuietTotal {
    param([object[]]$Rows)
    $measured=@($Rows|Where-Object Measured);$bytePairs=@($Rows|Where-Object {if($_.PSObject.Properties['ByteMeasured']){$_.ByteMeasured}else{$_.Measured}})
    $methods=@($measured|ForEach-Object {"$($_.Method)/$($_.Profile)/$($_.Version)"}|Select-Object -Unique)
    $data=[ordered]@{Deliveries=$Rows.Count;NativeCalls=0L;MeasuredDeliveries=$measured.Count;UnmeasuredDeliveries=$Rows.Count-$measured.Count
        ByteMeasuredDeliveries=$bytePairs.Count;FailedDeliveries=@($Rows|Where-Object Outcome -ne 'Success').Count;AnalysisIncompleteDeliveries=@($Rows|Where-Object {!$_.AnalysisComplete}).Count
        TruncatedDeliveries=@($Rows|Where-Object Truncated).Count;InputBytes=0L;OutputBytes=0L;InputTokens=$null;OutputTokens=$null;SavedTokens=$null;SavingsPercent=$null;ByteReductionPercent=$null}
    foreach($r in $Rows){$data.NativeCalls+=$r.NativeCalls}
    foreach($r in $bytePairs){$data.InputBytes+=$r.InputBytes;$data.OutputBytes+=$r.OutputBytes}
    if($methods.Count -eq 1 -or !$Rows.Count){foreach($name in @('InputTokens','OutputTokens','SavedTokens')){$data[$name]=[long](($measured|Measure-Object -Property $name -Sum).Sum)}}
    if($data.InputBytes){$data.ByteReductionPercent=[Math]::Round(100*($data.InputBytes-$data.OutputBytes)/$data.InputBytes,2)}
    if($data.InputTokens){$data.SavingsPercent=[Math]::Round(100*$data.SavedTokens/$data.InputTokens,2)}
    [pscustomobject]$data
}
function ConvertTo-QuietGainHtml {
    param($Report)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $encode={param($value) [Net.WebUtility]::HtmlEncode([string]$value)}
    $number={param($value) if($null -eq $value){'Unavailable'}else{([long]$value).ToString('N0',$culture)}}
    $percent={param($value) if($null -eq $value){'Unavailable'}else{([double]$value).ToString('0.##',$culture)+'%'}}
    $html=[Text.StringBuilder]::new()
    [void]$html.Append(@'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>QuietCli gain</title>
<style>
:root{color-scheme:light;--ink:#182b43;--muted:#52647b;--line:#dce4ee;--before:#637fa9;--after:#087f70;--loss:#bd3f49}
*{box-sizing:border-box}body{margin:0;background:#f3f6fa;color:var(--ink);font:15px/1.6 system-ui,sans-serif}
main{max-width:1240px;margin:auto;padding:36px 24px 60px}h1{font-size:36px;letter-spacing:-1px;margin:4px 0}h2{font-size:20px;margin:0 0 4px;overflow-wrap:anywhere}
.eyebrow{font-size:12px;font-weight:750;letter-spacing:2px;color:var(--after)}.muted,.period{color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px;margin:24px 0}
.card,.panel{background:#fff;border:1px solid var(--line);border-radius:16px}.card{padding:18px}.value{display:block;font-size:28px;font-weight:750;line-height:1.3;overflow-wrap:anywhere}
.label{font-size:13px;color:var(--muted)}.panel{padding:24px;margin:24px 0;box-shadow:0 6px 24px #182b4305}
.profile{font-size:13px;color:var(--muted);margin:0 0 16px}.metrics{display:flex;flex-wrap:wrap;gap:24px;margin:20px 0}
.metrics .value{font-size:24px}.positive{color:var(--after)}.negative{color:var(--loss)}
.notice{border-left:4px solid var(--before);background:#e9eff8;padding:12px 16px;margin:16px 0;overflow-wrap:anywhere}
.legend{display:flex;flex-wrap:wrap;gap:20px;font-size:13px;color:var(--muted)}.key{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px}
.before{fill:var(--before);background:var(--before)}.after{fill:var(--after);background:var(--after)}.loss{fill:var(--loss);background:var(--loss)}
.chart-frame,.table-frame{overflow-x:auto;margin-top:16px}svg{display:block;max-width:none}svg text{font:12px system-ui,sans-serif;fill:var(--muted)}.grid{stroke:var(--line);stroke-width:1}.axis{stroke:#9baabc;stroke-width:1}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:right;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}th:first-child,td:first-child{text-align:left;max-width:420px;white-space:normal;overflow-wrap:anywhere}th{color:var(--muted)}
details{margin-top:20px}summary{cursor:pointer;color:var(--muted);font-weight:600}pre{overflow:auto;font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;background:#f3f6fa;padding:16px;border-radius:8px}
.empty{padding:32px 16px;text-align:center;color:var(--muted)}footer{font-size:12px;color:var(--muted)}
@media(max-width:700px){main{padding:24px 16px}.cards{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.panel{padding:16px}.value{font-size:24px}h1{font-size:30px}}
</style></head><body><main><header><div class="eyebrow">QUIETCLI / OUTPUT VOLUME</div><h1>QuietCli gain</h1>
'@)
    $from=([DateTimeOffset]$Report.FromUtc).UtcDateTime.ToString('yyyy-MM-dd HH:mm',$culture)
    $to=([DateTimeOffset]$Report.ToUtc).UtcDateTime.ToString('yyyy-MM-dd HH:mm',$culture)
    [void]$html.Append("<p class='period'>$from &rarr; $to UTC &middot; Grouped by $(& $encode $Report.GroupBy)</p></header><div class='cards'>")
    foreach($card in @(
        @{Label='Deliveries';Value=(& $number $Report.Totals.Deliveries)},
        @{Label='Native calls';Value=(& $number $Report.Totals.NativeCalls)},
        @{Label='Measured byte reduction';Value=(& $percent $Report.Totals.ByteReductionPercent)},
        @{Label='Deliveries without token counts';Value=(& $number $Report.Totals.UnmeasuredDeliveries)}
    )){[void]$html.Append("<div class='card'><span class='value'>$($card.Value)</span><span class='label'>$($card.Label)</span></div>")}
    [void]$html.Append('</div>')
    if(!$Report.TrackingEnabled){[void]$html.Append("<p class='notice'>Tracking is disabled. This report shows previously recorded measurements.</p>")}
    if($Report.LastTrackingError){[void]$html.Append("<p class='notice'>Tracking issue: $(& $encode $Report.LastTrackingError)</p>")}
    [void]$html.Append("<p class='muted'>$($Report.Totals.FailedDeliveries) failed &middot; $($Report.Totals.AnalysisIncompleteDeliveries) incomplete analyses &middot; $($Report.Totals.TruncatedDeliveries) truncated deliveries. Byte totals cover $($Report.Totals.ByteMeasuredDeliveries) deliveries.</p>")
    if($Report.OmittedGroups){[void]$html.Append("<p class='notice'>$($Report.OmittedGroups) of $($Report.TotalGroups) groups are omitted by MaxItems. Summary totals cover the full period; charts show only the selected groups.</p>")}
    if(!$Report.Totals.Deliveries){[void]$html.Append("<section class='panel empty'><h2>No measurements in this period</h2><p>Run commands through QuietCli with tracking enabled, or select another date range or database.</p></section>")}
    $index=0
    foreach($method in $Report.Methods){
        $index++
        $groups=@($Report.Groups|Where-Object {(@($_.Method,$_.Profile,$_.Version) -join ', ') -eq $method.Label})
        $totals=$method.Totals
        $tokens=$totals.MeasuredDeliveries -gt 0
        $unit=if($tokens){'tokens'}else{'bytes'}
        $inputName=if($tokens){'InputTokens'}else{'InputBytes'}
        $outputName=if($tokens){'OutputTokens'}else{'OutputBytes'}
        $measuredName=if($tokens){'MeasuredDeliveries'}else{'ByteMeasuredDeliveries'}
        $available=@($groups|Where-Object {$_.Totals.$measuredName -gt 0})
        $saved=if($tokens){$totals.SavedTokens}elseif($totals.ByteMeasuredDeliveries){$totals.InputBytes-$totals.OutputBytes}else{$null}
        $savingPercent=if($tokens){$totals.SavingsPercent}else{$totals.ByteReductionPercent}
        $tone=if($null -ne $saved -and $saved -lt 0){'negative'}else{'positive'}
        [void]$html.Append("<section class='panel' data-profile='$(& $encode $method.Label)'><h2>$(& $encode $method.Label)</h2><p class='profile'>Each tokenizer, version and historical estimate is reported separately.</p><div class='metrics'>")
        foreach($metric in @(
            @{Label="Input $unit";Value=$(if($totals.$measuredName){& $number $totals.$inputName}else{'Unavailable'});Tone=''},
            @{Label="Delivered $unit";Value=$(if($totals.$measuredName){& $number $totals.$outputName}else{'Unavailable'});Tone=''},
            @{Label="Saved $unit";Value=(& $number $saved);Tone=$tone},
            @{Label='Reduction';Value=(& $percent $savingPercent);Tone=$tone}
        )){[void]$html.Append("<div><span class='value $($metric.Tone)'>$($metric.Value)</span><span class='label'>$($metric.Label)</span></div>")}
        [void]$html.Append("</div><p class='muted'>$($totals.$measuredName) of $($totals.Deliveries) deliveries have comparable $unit measurements.</p>")
        if(!$tokens){[void]$html.Append("<p class='notice'>Token counts are unavailable. This chart uses measured bytes.</p>")}
        if(!$available.Count){
            [void]$html.Append("<p class='empty'>No comparable measurements in the selected groups.</p>")
        }else{
            [void]$html.Append("<div class='legend'><span><i class='key before'></i>Native output</span><span><i class='key after'></i>QuietCli delivery</span><span><i class='key loss'></i>Delivery exceeds input</span></div><div class='chart-frame'>")
            $maximum=0.0
            foreach($group in $available){$maximum=[Math]::Max($maximum,[Math]::Max([double]$group.Totals.$inputName,[double]$group.Totals.$outputName))}
            $axisMax=if($maximum -gt 0){$magnitude=[Math]::Pow(10,[Math]::Floor([Math]::Log10($maximum)));[Math]::Ceiling($maximum/$magnitude)*$magnitude}else{1.0}
            $width=[Math]::Max(680,100+86*$available.Count)
            $plotWidth=$width-100
            [void]$html.Append("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 $width 330' width='$width' height='330' style='min-width:100%' role='img' aria-labelledby='chart-title-$index chart-desc-$index'><title id='chart-title-$index'>Input and delivered $unit by $(& $encode $Report.GroupBy)</title><desc id='chart-desc-$index'>Paired bars compare native output with QuietCli delivery. Red bars indicate increased output. Exact values are in the data table.</desc><text x='72' y='18'>$unit</text>")
            for($tick=0;$tick -le 4;$tick++){
                $y=240-50*$tick
                $label=($axisMax*$tick/4).ToString('0.##',$culture)
                [void]$html.Append("<line class='grid' x1='72' y1='$y' x2='$($width-20)' y2='$y'/><text x='64' y='$($y+4)' text-anchor='end'>$label</text>")
            }
            [void]$html.Append("<line class='axis' x1='72' y1='240' x2='$($width-20)' y2='240'/>")
            $position=0
            foreach($group in $available){
                $suffix=', '+$method.Label
                $label=[string]$group.Label
                if($label.EndsWith($suffix,[StringComparison]::Ordinal)){$label=$label.Substring(0,$label.Length-$suffix.Length)}
                if(!$label.Length){$label='(unspecified)'}
                $short=if($label.Length -gt 13){$label.Substring(0,12)+'...'}else{$label}
                $center=72+($position+0.5)*$plotWidth/$available.Count
                foreach($bar in @(
                    @{Name='Native output';Class='before';Value=[double]$group.Totals.$inputName;Offset=-25},
                    @{Name='QuietCli delivery';Class=$(if($group.Totals.$outputName -gt $group.Totals.$inputName){'loss'}else{'after'});Value=[double]$group.Totals.$outputName;Offset=3}
                )){
                    $height=(200*$bar.Value/$axisMax).ToString('0.###',$culture)
                    $y=(240-200*$bar.Value/$axisMax).ToString('0.###',$culture)
                    $x=($center+$bar.Offset).ToString('0.###',$culture)
                    $value=$bar.Value.ToString('0',$culture)
                    $title=& $encode ("{0}: {1} = {2} {3}" -f $label,$bar.Name,(& $number $bar.Value),$unit)
                    [void]$html.Append("<rect class='$($bar.Class)' x='$x' y='$y' width='22' height='$height' data-value='$value'><title>$title</title></rect>")
                }
                $x=$center.ToString('0.###',$culture)
                [void]$html.Append("<text x='$x' y='264' text-anchor='middle'><title>$(& $encode $label)</title>$(& $encode $short)</text>")
                $position++
            }
            [void]$html.Append('</svg></div>')
        }
        $unavailableGroups=@($groups|Where-Object {$_.Totals.$measuredName -eq 0}).Count
        if($unavailableGroups){[void]$html.Append("<p class='muted'>$unavailableGroups selected groups have no comparable $unit measurements and are excluded from the chart.</p>")}
        [void]$html.Append("<details><summary>Measurement details</summary><div class='table-frame'><table><thead><tr><th>Group</th><th>Deliveries</th><th>Input $unit</th><th>Delivered $unit</th><th>Saved $unit</th></tr></thead><tbody>")
        foreach($group in $groups){
            $known=$group.Totals.$measuredName -gt 0
            $inputValue=if($known){$group.Totals.$inputName}else{$null}
            $outputValue=if($known){$group.Totals.$outputName}else{$null}
            $savedValue=if($known){$inputValue-$outputValue}else{$null}
            [void]$html.Append("<tr><td>$(& $encode $group.Label)</td><td>$($group.Totals.Deliveries)</td><td>$(& $number $inputValue)</td><td>$(& $number $outputValue)</td><td>$(& $number $savedValue)</td></tr>")
        }
        [void]$html.Append('</tbody></table></div></details></section>')
    }
    $json=& $encode ($Report|ConvertTo-Json -Depth 20)
    [void]$html.Append("<details class='panel'><summary>Report data (JSON)</summary><pre>$json</pre></details><footer>These measurements describe command-output volume, not provider invoices or total agent cost. Dates and daily groups use UTC.</footer></main></body></html>")
    $html.ToString()
}

function QuietCliGain {
    [CmdletBinding(DefaultParameterSetName='Days')]param(
        [Parameter(ParameterSetName='Days')][int]$Days=7,[Parameter(Mandatory,ParameterSetName='Range')][DateTimeOffset]$From,
        [Parameter(ParameterSetName='Range')][DateTimeOffset]$To=[DateTimeOffset]::UtcNow,
        [ValidateSet('Command','Day','Session','Format','Outcome','Profile')][string]$GroupBy='Day',
        [ValidateSet('Object','Json','Text','Chart','Html')][string]$View='Text',[int]$MaxItems=31,[string]$DatabasePath,[string]$OutputPath,[switch]$Browse)
    if($PSCmdlet.ParameterSetName -eq 'Days'){$To=[DateTimeOffset]::UtcNow;$From=$To.AddDays(-$Days)}
    if($From -ge $To -or $MaxItems -lt 0){throw 'Invalid report window.'}
    $rows=@(Get-QuietHistoryRow $From $To $DatabasePath)
    $groups=@($rows|Group-Object -Property {$row=$_;switch($GroupBy){Day{([DateTimeOffset]$row.TimestampUtc).UtcDateTime.ToString('yyyy-MM-dd')}default{$row.$GroupBy}}},Method,Profile,Version|ForEach-Object{
        [pscustomobject]@{Label=$_.Name;Method=$_.Group[0].Method;Profile=$_.Group[0].Profile;Version=$_.Group[0].Version;Totals=(Get-QuietTotal @($_.Group))}})
    $methods=@($rows|Group-Object Method,Profile,Version|ForEach-Object {@{Label=$_.Name;Totals=(Get-QuietTotal @($_.Group))}})
    $reruns=@($rows|Where-Object Fingerprint|Group-Object Fingerprint|Where-Object Count -ge 3)
    $report=[pscustomobject]@{SchemaVersion=2;GroupBy=$GroupBy;FromUtc=$From.ToString('o');ToUtc=$To.ToString('o');DatabasePath=(Get-QuietDatabasePath $DatabasePath)
        TrackingEnabled=(Get-QuietConfiguration).Tracking;LastTrackingError=$script:LastGainError;Totals=(Get-QuietTotal $rows)
        Methods=$methods;Groups=@($groups|Sort-Object Label|Select-Object -First $MaxItems);TotalGroups=$groups.Count;OmittedGroups=[Math]::Max(0,$groups.Count-$MaxItems)
        Advice=@($reruns|ForEach-Object {@{Code='FrequentRerun';Command=$_.Group[0].Command;Runs=$_.Count;Action='Read existing records or reuse a documented contract.'}})}
    switch($View){
        Object{$report}
        Json{$report|ConvertTo-Json -Depth 20 -Compress}
        Html{
            if(!$OutputPath){throw 'Html requires OutputPath.'}
            $html=ConvertTo-QuietGainHtml $report
            [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$html,[Text.UTF8Encoding]::new($false))
            if($Browse){Start-Process ([Uri]::new([IO.Path]::GetFullPath($OutputPath))).AbsoluteUri}
            [IO.Path]::GetFullPath($OutputPath)
        }
        default{
            $lines=[Collections.Generic.List[string]]::new();$lines.Add("QuietCli gain: $($report.Totals.Deliveries) deliveries; profiles are separate.")
            foreach($g in $report.Groups){$saved=$g.Totals.SavedTokens;$bar=if($View -eq 'Chart'){(' '+('#'*[int][Math]::Min(40,[Math]::Abs([double]$saved)/100)))}else{''};$lines.Add("$($g.Label): $saved tokens saved$bar")}
            if($report.LastTrackingError){$lines.Add("Tracking issue: $($report.LastTrackingError)")}
            $lines -join [Environment]::NewLine
        }
    }
}
function Get-QuietAudit {
    [CmdletBinding()]param([int]$Days=7,[switch]$AsObject)
    $rows=@(Get-QuietHistoryRow ([DateTimeOffset]::UtcNow.AddDays(-$Days)) ([DateTimeOffset]::UtcNow))
    $data=@($rows|Group-Object Command|ForEach-Object {
        $group=$_.Group;$known=@($group|Where-Object {$null -ne $_.OverheadMs})
        $times=@($known.OverheadMs|Sort-Object);$total=0.0;$callbacks=0.0;$backpressure=0.0;$elapsed=0.0
        foreach($r in $group){$callbacks+=$r.CallbackMs;$backpressure+=$r.BackpressureMs;$elapsed+=$r.ElapsedMs}
        foreach($value in $times){$total+=$value}
        $p50=$null;$p95=$null
        if($times.Count){$p50=$times[[Math]::Max(0,[int][Math]::Ceiling($times.Count*0.5)-1)];$p95=$times[[Math]::Max(0,[int][Math]::Ceiling($times.Count*0.95)-1)]}
        $pairs=@($known|Where-Object {$_.Measured -and $_.Profile -eq (Get-QuietConfiguration).Tokenizer})
        $pairTokens=0L;$pairOverhead=0.0;foreach($r in $pairs){$pairTokens+=$r.SavedTokens;$pairOverhead+=$r.OverheadMs}
        [pscustomobject]@{Command=$_.Name;Calls=$group.Count;KnownOverheads=$known.Count;UnknownDurations=$group.Count-$known.Count
            ElapsedMs=$elapsed;OverheadMs=$(if($known.Count){$total}else{$null});P50Ms=$p50;P95Ms=$p95
            CallbackMs=$callbacks;BackpressureMs=$backpressure
            SavedTokensPerOverheadSecond=$(if($pairOverhead -gt 0){1000*$pairTokens/$pairOverhead}else{$null})}
    })
    $result=New-QuietResult -Data $data -NoRegister
    if($AsObject){$result}else{Out-QuietResult $result}
}
function Measure-QuietContract {
    [CmdletBinding()]param([Parameter(Mandatory)][string[]]$RecordId,[Parameter(Mandatory)][string]$ContractPath,[switch]$AsObject)
    $history=@(Get-QuietHistoryRow ([DateTimeOffset]::UtcNow.AddYears(-10)) ([DateTimeOffset]::UtcNow))
    $data=@(foreach($id in $RecordId){
        $result=Invoke-QuietRecord -Id $id -ContractPath $ContractPath -AsObject
        $text=Out-QuietResult $result -AsJson;$candidate=try{Measure-QuietToken -Text $text}catch{$null}
        $baseline=@($history|Where-Object {$_.RecordId -eq $id}|Select-Object -Last 1)
        $comparable=$baseline.Count -eq 1 -and $candidate -and $baseline[0].Measured -and $baseline[0].Profile -eq $candidate.Profile -and $baseline[0].Version -eq $candidate.Version
        @{RecordId=$id;Outcome=$result.Outcome;CandidateBytes=[Text.Encoding]::UTF8.GetByteCount($text)
            CandidateTokens=$(if($candidate){$candidate.Tokens}else{$null});BaselineKnown=[bool]$comparable
            BaselineTokens=$(if($comparable){$baseline[0].OutputTokens}else{$null})
            SavedTokens=$(if($comparable){$baseline[0].OutputTokens-$candidate.Tokens}else{$null})
            SemanticValidation='Independent business assertions are still required.';Error=$result.Error}
    })
    $report=New-QuietResult -Outcome $(if(@($data|Where-Object Outcome -ne 'Success').Count){'Failed'}else{'Success'}) -Data $data -NoRegister
    if($AsObject){$report}else{Out-QuietResult $report}
}
