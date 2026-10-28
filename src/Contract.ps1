function New-QuietContract {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs fresh in-memory contract state.')]
    [CmdletBinding(DefaultParameterSetName='Document')]param(
        [Parameter(Mandatory)][string]$Id,[string]$FilePath,[string[]]$ArgumentList=@(),
        [Parameter(Mandatory,ParameterSetName='Task')][scriptblock]$Execute,
        [Parameter(Mandatory,ParameterSetName='Document')][scriptblock]$Parse,
        [Parameter(Mandatory,ParameterSetName='Streaming')][scriptblock]$OnOutput,
        [Parameter(Mandatory,ParameterSetName='Batch')][scriptblock]$OnBatch,
        [object]$State,[scriptblock]$Complete,[scriptblock]$Projection,
        [string]$Summary='Contract completed.',[char]$RecordDelimiter=[char]10,[char]$StdErrDelimiter=[char]10,
        [string]$Encoding='utf-8',[Collections.IDictionary]$Environment=@{},[int[]]$SuccessExitCodes=@(0),
        [string[]]$Documentation=@(),[string[]]$SourcePath=@(),[string[]]$SupportedForms=@(),[string]$ObservedVersion)
    [pscustomobject]@{PSTypeName='QuietCli.Contract';Execute=$Execute;Id=$Id;FilePath=$FilePath;ArgumentList=@($ArgumentList);Parse=$Parse;OnOutput=$OnOutput;OnBatch=$OnBatch
        State=$State;Complete=$Complete;Projection=$Projection;Summary=$Summary;RecordDelimiter=$RecordDelimiter;StdErrDelimiter=$StdErrDelimiter
        Encoding=$Encoding;Environment=$Environment;SuccessExitCodes=$SuccessExitCodes;Documentation=$Documentation;SourcePath=$SourcePath
        SupportedForms=$SupportedForms;ObservedVersion=$ObservedVersion}
}
function Register-QuietCommand {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Command,[Parameter(Mandatory)][scriptblock]$Factory,[string]$ModuleId='session')
    $key=(Get-QuietExecutableName $Command)
    if($script:QuietCommands.ContainsKey($key)){
        if($script:QuietCommands[$key].ModuleId -eq $ModuleId){$script:QuietCommands[$key].Factory=$Factory;return}
        throw "QuietCli command conflict: $key is already provided by $($script:QuietCommands[$key].ModuleId)."
    }
    $script:QuietCommands[$key]=@{Factory=$Factory;ModuleId=$ModuleId}
}
function Resolve-QuietCommand {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Command)
    $key=(Get-QuietExecutableName $Command)
    if(!$script:QuietCommands.ContainsKey($key)){
        $modules=@((Get-QuietConfiguration).Modules|Where-Object Command -eq $key)
        if($modules.Count -gt 1){throw "Multiple configured modules for $key."}
        if($modules.Count){
            $module=$modules[0]
            if((Get-QuietModuleHash $module.Path) -cne $module.Hash){throw 'Installed QuietCli module has changed; validate and install it again.'}
            Import-Module -Name $module.Path -Force -ErrorAction Stop
        }
    }
    if($script:QuietCommands.ContainsKey($key)){return $script:QuietCommands[$key]}
}
function Invoke-QuietContract {
    param($Contract,[hashtable]$Invocation,[hashtable]$Options=@{},[string]$ContractPath)
    if($Contract.PSObject.TypeNames -notcontains 'QuietCli.Contract'){throw 'A factory must return one QuietCli contract.'}
    $call=@{FilePath=$Contract.FilePath;ArgumentList=$Contract.ArgumentList;WorkingDirectory=$Invocation.WorkingDirectory;State=$Contract.State
        Summary=$Contract.Summary;Projection=$Contract.Projection;RecordDelimiter=$Contract.RecordDelimiter;StdErrDelimiter=$Contract.StdErrDelimiter
        Encoding=$Contract.Encoding;SuccessExitCodes=$Contract.SuccessExitCodes;Environment=$Contract.Environment}
    if($Contract.Parse){$call.Parse=$Contract.Parse}elseif($Contract.OnBatch){$call.OnBatch=$Contract.OnBatch}else{$call.OnOutput=$Contract.OnOutput}
    if($Contract.Complete){$call.Complete=$Contract.Complete}
    foreach($name in @('TimeoutSeconds','CancellationToken','CancellationFile','MaxCaptureBytes','MaxRecordCharacters','InputText')){if($Options.ContainsKey($name)){$call[$name]=$Options[$name]}}
        if($Contract.Execute){$result=Invoke-QuietTask -ScriptBlock $Contract.Execute -ArgumentList @($Invocation) -AsObject}
    else{$result=Invoke-QuietCli @call}
    $result.Internal.Origin=$Invocation;$result.Projection=$Contract.Projection;$result.Summary=$Contract.Summary
    foreach($source in $result.Internal.Sources.Values){
        $source.Contract=$Contract.Id;$source.Documentation=$Contract.Documentation;if($Contract.ObservedVersion){$source.ObservedVersion=$Contract.ObservedVersion}
        $source.SourcePaths=@($Contract.SourcePath)+@($ContractPath|Where-Object {$_})
        $source.OriginalRequest=$Invocation
    }
    if($Options.Record){Save-QuietRecord $result -Explicit|Out-Null}
    $result
}
function Invoke-QuietPump {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Command,[string[]]$ArgumentList=@(),
        [string]$ContractPath,[string]$WorkingDirectory=(Get-Location).Path,[switch]$Record,[switch]$AsObject,[switch]$AsJson,[switch]$AsYaml,
        [int]$MaxItems=20,[int]$MaxOutputBytes=4096,[int]$TimeoutSeconds=600,[long]$MaxCaptureBytes=-1,
        [int]$MaxRecordCharacters=65536,[int]$ExcerptLines=20,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,[string]$CancellationFile,
        [AllowNull()][string]$InputText,[scriptblock]$OnOutput,[scriptblock]$OnBatch,[object]$State,[scriptblock]$Complete,[scriptblock]$Parse,[scriptblock]$Projection)
        if(@($AsObject,$AsJson,$AsYaml|Where-Object {$_}).Count -gt 1){throw 'AsObject, AsJson and AsYaml are exclusive.'}
    $settings=Get-QuietConfiguration
    if(!$PSBoundParameters.ContainsKey('MaxItems')){$MaxItems=$settings.MaxItems}
    if(!$PSBoundParameters.ContainsKey('MaxOutputBytes')){$MaxOutputBytes=$settings.MaxOutputBytes}
    if(!$PSBoundParameters.ContainsKey('TimeoutSeconds')){$TimeoutSeconds=$settings.TimeoutSeconds}
    $invocation=@{FilePath=$Command;ArgumentList=@($ArgumentList);WorkingDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)}
    try{
        if($OnOutput -or $OnBatch -or $Parse){
            $direct=@{FilePath=$Command;ArgumentList=$ArgumentList;WorkingDirectory=$invocation.WorkingDirectory;State=$State
                TimeoutSeconds=$TimeoutSeconds;CancellationToken=$CancellationToken;MaxCaptureBytes=$MaxCaptureBytes;MaxRecordCharacters=$MaxRecordCharacters;Record=$Record}
            if($OnOutput){$direct.OnOutput=$OnOutput}elseif($OnBatch){$direct.OnBatch=$OnBatch}else{$direct.Parse=$Parse}
            if($Complete){$direct.Complete=$Complete};if($Projection){$direct.Projection=$Projection}
            if($PSBoundParameters.ContainsKey('InputText')){$direct.InputText=$InputText};if($CancellationFile){$direct.CancellationFile=$CancellationFile}
            $result=Invoke-QuietCli @direct
        }else{
            $contract=$null
            if($ContractPath){$ContractPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ContractPath);$contract=Invoke-QuietFactory -Path $ContractPath -Invocation $invocation}
            else{$route=Resolve-QuietCommand $Command;if($route){$contract=Invoke-QuietFactory -Factory $route.Factory -Invocation $invocation}}
            if(!$contract){$result=New-QuietResult -Outcome Unsupported -Summary 'No applicable contract. Ask the agent to read the command documentation and provide a contract.' -ErrorInfo @{Code='ContractNotFound';Phase='Routing'} -Execution @{ExitCode=$null}}
            elseif($contract.PSObject.TypeNames -contains 'QuietCli.Result'){$result=$contract;Add-QuietTaskResult $result}
            else{$options=@{};foreach($key in $PSBoundParameters.Keys){$options[$key]=$PSBoundParameters[$key]};$result=Invoke-QuietContract $contract $invocation $options $ContractPath}
        }
    }catch{$result=New-QuietResult -Outcome Failed -Summary 'Contract invocation failed.' -ErrorInfo @{Code='ContractFailed';Phase='Routing';Message=$_.Exception.Message} -Execution @{ExitCode=$null}}
    if($AsObject){return $result}
    Out-QuietResult -InputObject $result -AsJson:$AsJson -AsYaml:$AsYaml -MaxItems $MaxItems -MaxOutputBytes $MaxOutputBytes -ExcerptLines $ExcerptLines
}
