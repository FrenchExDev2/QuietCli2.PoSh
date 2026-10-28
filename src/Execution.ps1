function Invoke-QuietCli {
    [CmdletBinding(DefaultParameterSetName='Document')]param(
        [Parameter(Mandatory)][string]$FilePath,[string[]]$ArgumentList=@(),[string]$WorkingDirectory=(Get-Location).Path,
        [Parameter(Mandatory,ParameterSetName='Document')][scriptblock]$Parse,
        [Parameter(Mandatory,ParameterSetName='Streaming')][scriptblock]$OnOutput,
        [Parameter(Mandatory,ParameterSetName='Batch')][scriptblock]$OnBatch,
        [object]$State,[scriptblock]$Complete,[scriptblock]$Projection,
        [char]$RecordDelimiter=[char]10,[char]$StdErrDelimiter=[char]10,[string]$Encoding='utf-8',
        [Collections.IDictionary]$Environment=@{},[AllowNull()][string]$InputText,
        [int[]]$SuccessExitCodes=@(0),[int]$TimeoutSeconds=600,
        [ValidateRange(1,10485760)][int]$MaxRecordCharacters=65536,[long]$MaxCaptureBytes=-1,
        [int]$MaxCaptureCharacters=0,[int]$MaxOutputBytes=4096,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,[string]$CancellationFile,
        [string]$Summary='Native command processed.',[string]$ObservedVersion,[switch]$Record)
        if($script:QuietBuildingContract){throw 'Factories construct contracts; put native calls in Execute or execute an explicit contract.'}
    $nativeWatch=[Diagnostics.Stopwatch]::StartNew()
    if($script:QuietReplay){
        if(!$script:QuietReplayContext -or !$script:QuietReplayContext.Count){throw 'Native execution is prohibited while replaying a record.'}
        $source=$script:QuietReplayContext.Dequeue()
        if($source.Request.FilePath -cne $FilePath -or (ConvertTo-Json -InputObject @($source.Request.ArgumentList) -Compress) -cne (ConvertTo-Json -InputObject @($ArgumentList) -Compress)){throw 'Replay invocation differs from the recorded command and argument vector.'}
        $options=@{Id='replay.step';FilePath=$FilePath;ArgumentList=$ArgumentList;State=$State;Complete=$Complete;Projection=$Projection;SuccessExitCodes=$SuccessExitCodes}
        if($Parse){$options.Parse=$Parse}elseif($OnBatch){$options.OnBatch=$OnBatch}else{$options.OnOutput=$OnOutput}
        return Invoke-QuietCapturedCall $source (New-QuietContract @options)
    }
    $settings=Get-QuietConfiguration
    if(!$PSBoundParameters.ContainsKey('TimeoutSeconds')){$TimeoutSeconds=$settings.TimeoutSeconds}
    if($MaxCaptureBytes -lt 0){$MaxCaptureBytes=$settings.MaxCaptureBytes}
    if($MaxCaptureCharacters -gt 0){$MaxCaptureBytes=[long]$MaxCaptureCharacters}
    if($TimeoutSeconds -lt 1 -or $MaxCaptureBytes -lt 0){throw 'Invalid execution limits.'}
    $directory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
    if($CancellationFile){$CancellationFile=[IO.Path]::GetFullPath($CancellationFile,$directory)}
    $inputValue=if($PSBoundParameters.ContainsKey('InputText')){$InputText}else{$null}
    $session=$null;$capture=$null;$parseError=$null;$finalizerError=$null;$data=$null
    $emissions=[Collections.Generic.List[object]]::new();$callbackWatch=[Diagnostics.Stopwatch]::new()
    try{
        $session=[QuietCliStack.V2.NativeSession]::new($FilePath,$ArgumentList,$directory,$Environment,$inputValue,$Encoding,
            $TimeoutSeconds,$MaxRecordCharacters,$MaxCaptureBytes,$RecordDelimiter,$StdErrDelimiter,$CancellationToken,$CancellationFile)
        while($null -ne ($frame=$session.Next())){
            if($PSCmdlet.ParameterSetName -ne 'Document' -and !$parseError){
                $callbackWatch.Start()
                try{
                    $items=if($OnBatch){@(Invoke-QuietCallback $OnBatch @((,@($frame)),$State))}else{@(Invoke-QuietCallback $OnOutput @($frame,$State))}
                    foreach($item in $items){$emissions.Add($item)}
                }catch{$parseError=@{Code='ParserFailed';Phase='Analyze';Message=$_.Exception.Message}}
                finally{$callbackWatch.Stop()}
            }
        }
        $capture=$session.Result
        if($PSCmdlet.ParameterSetName -eq 'Document'){
            if(!$capture.CaptureComplete){$parseError=@{Code='CaptureLimit';Phase='Analyze';Message='Document parsing requires a complete capture.'}}
            elseif(!$capture.StartError){
                try{$items=@(Invoke-QuietCallback $Parse @($capture));$data=if($items.Count -eq 1){$items[0]}elseif($items.Count){,$items}else{$null}}
                catch{$parseError=@{Code='ParserFailed';Phase='Analyze';Message=$_.Exception.Message}}
            }
        }elseif($Complete){
            try{$items=@(Invoke-QuietCallback $Complete @($State,$capture));$data=if($items.Count -eq 1){$items[0]}elseif($items.Count){,$items}else{$null}}
            catch{$finalizerError=@{Code='FinalizerFailed';Phase='Complete';Message=$_.Exception.Message}}
        }elseif($emissions.Count){$data=if($emissions.Count -eq 1){$emissions[0]}else{,$emissions.ToArray()}}
    }catch{$parseError=@{Code='ExecutionFailed';Phase='Execute';Message=$_.Exception.GetBaseException().Message}}
    finally{if($session){$session.Dispose()}}
    $outcome='Success';$errorInfo=$null
    if($capture -and $capture.Cancelled){$outcome='Cancelled';$errorInfo=@{Code='Cancelled';Phase='Execute'}}
    elseif($capture -and $capture.TimedOut){$outcome='Timeout';$errorInfo=@{Code='Timeout';Phase='Execute'}}
    elseif($capture -and $capture.StartError){$outcome='Failed';$errorInfo=@{Code='NativeStartOrReadFailed';Phase='Execute';Message=$capture.StartError}}
    elseif($capture -and $capture.ExitCode -notin $SuccessExitCodes){$outcome='Failed';$errorInfo=@{Code='NativeFailed';Phase='Execute'}}
    elseif($capture -and $capture.Lossy){$outcome='Failed';$errorInfo=@{Code='DecodeFailed';Phase='Decode';Message='Invalid bytes were replaced while decoding.'}}
    elseif($parseError){$outcome='Failed';$errorInfo=$parseError}
    elseif($capture -and $capture.LostRecords){$outcome='Failed';$errorInfo=@{Code='RecordLimit';Phase='Analyze'}}
    elseif($finalizerError){$outcome='Failed';$errorInfo=$finalizerError}
    $sourceComplete=[bool]($capture -and $capture.SourceComplete)
    $analysisComplete=$sourceComplete -and !$parseError -and !$finalizerError -and !$capture.LostRecords -and !$capture.Lossy
    $execution=@{ExitCode=$(if($capture){$capture.ExitCode}else{$null});ElapsedMs=$(if($capture){$capture.ElapsedMs}else{$null})
        AnalysisComplete=$analysisComplete;SourceComplete=$sourceComplete
        StdoutBytes=$(if($capture){$capture.StdoutBytes}else{0L});StderrBytes=$(if($capture){$capture.StderrBytes}else{0L})
        LostRecords=$(if($capture){$capture.LostRecords}else{0L});FinalizerError=$finalizerError;ParserError=$parseError
        Timing=@{SetupMs=$(if($capture){$capture.SetupMs}else{$null});ProcessMs=$(if($capture){$capture.ProcessMs}else{$null});CallbackMs=$callbackWatch.Elapsed.TotalMilliseconds;BackpressureMs=$(if($capture){$capture.BackpressureMs}else{$null})}}
    $result=New-QuietResult -Summary $Summary -Outcome $outcome -Data $data -Execution $execution -ErrorInfo $errorInfo -Projection $Projection
    $result.Capture=$capture;$result.Completeness.Source=$sourceComplete;$result.Completeness.Analysis=$analysisComplete
    $result.Completeness.Capture=[bool]($capture -and $capture.CaptureComplete)
    if($capture -and $capture.LostRecords){$result.Truncation.Applied=$true;$result.Truncation.Reasons=@('RecordLimit');$result.Truncation.Omitted=$capture.LostRecords}
    $source=@{Id=$result.Internal.Id;Command=(Get-QuietExecutableName $FilePath);Request=@{FilePath=$FilePath;ArgumentList=@($ArgumentList);WorkingDirectory=$directory}
        Capture=$capture;SourceComplete=$sourceComplete;AnalysisComplete=$analysisComplete;Outcome=$outcome
        ExitCode=$execution.ExitCode;Bytes=([long]$execution.StdoutBytes+[long]$execution.StderrBytes);Timing=$execution.Timing
        ElapsedMs=$nativeWatch.Elapsed.TotalMilliseconds;RecordDelimiter=[int]$RecordDelimiter;StdErrDelimiter=[int]$StdErrDelimiter;Encoding=$Encoding
        Contract=$null;SourcePaths=@();Documentation=@();ObservedVersion=$ObservedVersion;Delivered=[Collections.Generic.HashSet[string]]::new()}
    $result.Internal.Sources[$source.Id]=$source
    Save-QuietInvocation $source
    $wanted=$Record -or @($script:QuietTasks|Where-Object Record).Count -gt 0
    if($wanted){Save-QuietRecord $result -Explicit|Out-Null}
    $result
}
