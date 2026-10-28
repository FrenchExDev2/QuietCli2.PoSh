$script:QuietTasks = [Collections.Generic.Stack[object]]::new()
$script:QuietCommands = @{}
$script:QuietMaskers = [Collections.Generic.List[object]]::new()
$script:QuietSources = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
$script:QuietReplay = $false
$script:QuietBuildingContract = $false
$script:QuietReplayContext = $null
$script:LastGainError = $null
$script:QuietDefaults = @{
    MaxItems=20; MaxOutputBytes=4096; TimeoutSeconds=600; ExcerptLines=20; MaxCaptureBytes=10485760L
    Recall=$true; RecallMaxEntries=200; RecallRetentionDays=30; OutputFormat='json'; Envelope='compact'
    Tracking=$true; Tokenizer='o200k_base'; Modules=@(); HookAwareness='warn'
}
function Get-QuietConfiguration {
    [CmdletBinding()]param()
    $settings=$script:QuietDefaults.Clone()
    $path=if($env:QUIETCLI_CONFIG_PATH){$env:QUIETCLI_CONFIG_PATH}else{Join-Path $HOME '.quietcli/config.json'}
    if(Test-Path -LiteralPath $path){$document=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable;foreach($key in $document.Keys){if(!$settings.ContainsKey($key)){throw "Unknown QuietCli setting: $key"};$settings[$key]=$document[$key]}}
    if($env:QUIETCLI_TRACKING -in @('0','off','false')){$settings.Tracking=$false}
    if($env:QUIETCLI_RECALL -in @('0','off','false')){$settings.Recall=$false}
    if($env:QUIETCLI_TOKENIZER){$settings.Tokenizer=$env:QUIETCLI_TOKENIZER}
    if($settings.MaxItems -lt 0 -or $settings.MaxOutputBytes -lt 256 -or $settings.TimeoutSeconds -lt 1 -or $settings.MaxCaptureBytes -lt 0){throw 'Invalid QuietCli limits.'}
    return $settings
}
function Get-QuietDatabasePath {
    param([string]$Path)
    if(!$Path){$Path=$env:QUIETCLI_DB_PATH};if(!$Path){$Path=Join-Path $HOME '.quietcli/gain.sqlite3'}
    if($Path.StartsWith('~/')){$Path=Join-Path $HOME $Path.Substring(2)}
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}
function Invoke-QuietSql {
    param([Parameter(Mandatory)][string]$Sql,[object[]]$Values=@(),[switch]$Read,[string]$DatabasePath)
    $path=Get-QuietDatabasePath $DatabasePath
    if($Read -and !(Test-Path -LiteralPath $path)){return}
    $database=[QuietCliStack.GainV2.Database]::new($path,!$Read)
    try{if($Read){$database.Query($Sql,$Values)}else{$database.Execute($Sql,$Values)}}finally{$database.Dispose()}
}
function Register-QuietObfuscator {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][scriptblock]$Transform)
    if(@($script:QuietMaskers|Where-Object Id -eq $Id).Count){throw "Duplicate obfuscator: $Id"}
    $script:QuietMaskers.Add(@{Id=$Id;Transform=$Transform})
}
function Protect-QuietValue {
    param($Value,[hashtable]$State=@{Limited=$false;Redacted=$false},[int]$Depth=0)
    if($null -eq $Value){return $null}
    if($Depth -gt 48){$State.Limited=$true;return '[OMITTED:DEPTH]'}
    if($Value -is [string]){
        $text=$Value -replace '\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)',''
        $before=$text
                if(!$State.ContainsKey('Secrets')){$State.Secrets=@(Get-ChildItem Env:|Where-Object {$_.Name -match '(?i)password|secret|token|api_?key|connectionstring' -and $_.Value.Length -ge 8}|ForEach-Object Value)}
        foreach($secret in $State.Secrets){$text=$text.Replace($secret,'[REDACTED]',[StringComparison]::Ordinal)}
        $text=$text -replace '(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|$)','[REDACTED]'
        $text=$text -replace '(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+','[REDACTED]'
        $text=$text -replace '(?i)\b(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,}|AKIA[A-Z0-9]{16})\b','[REDACTED]'
        $text=$text -replace '(?i)"(password|passwd|secret|token|api[_-]?key|authorization)"\s*:\s*"(?:\\.|[^"\\])*"','"$1":"[REDACTED]"'
        $text=$text -replace '(?i)((?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;&"'']+)','$1[REDACTED]'
        $text=$text -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s@?#]+@','$1[REDACTED]@'
        foreach($masker in $script:QuietMaskers){
            try{$items=@(& $masker.Transform $text);if($items.Count -ne 1 -or $items[0] -isnot [string]){throw 'Obfuscator must return one string.'};$text=$items[0]}catch{$State.Limited=$true;$text='[OBFUSCATION FAILED]'}
        }
        if($text -cne $before){$State.Redacted=$true}
        return $text
    }
    if($Value -is [datetime] -or $Value -is [datetimeoffset]){return $Value.ToString('o')}
    if($Value -is [ValueType]){return $Value}
    if($Value -is [Collections.IDictionary] -or ($Value -is [pscustomobject] -and $Value -isnot [Collections.IEnumerable])){
        $map=[ordered]@{};$keys=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
        foreach($key in $keys){
            $safeKey=Protect-QuietValue ([string]$key) $State ($Depth+1)
            if([string]$key -match '(?i)^(password|passwd|secret|token|api[_-]?key|authorization|credential|connectionstring|environment)$'){$map[$safeKey]='[REDACTED]';$State.Redacted=$true}
            else{$map[$safeKey]=Protect-QuietValue $Value.$key $State ($Depth+1)}
        }
        return [pscustomobject]$map
    }
    if($Value -is [Collections.IEnumerable]){
        $items=[Collections.Generic.List[object]]::new();foreach($item in $Value){$items.Add((Protect-QuietValue $item $State ($Depth+1)))}
        return ,$items.ToArray()
    }
    $State.Limited=$true;return '[OMITTED:TYPE]'
}
function Invoke-QuietCallback {
    param([scriptblock]$Callback,[object[]]$Arguments)
    & $Callback @Arguments *>&1|ForEach-Object{
        if($_ -is [Management.Automation.ErrorRecord] -or $_ -is [Management.Automation.InformationalRecord] -or $_ -is [Management.Automation.InformationRecord]){throw 'Callbacks must return domain values, not diagnostics.'}
        ,$_
    }
}

function Get-QuietExecutableName {
    param([string]$Path)
    ([IO.Path]::GetFileName($Path)) -replace '(?i)\.(exe|cmd|bat|com)$',''
}

function Invoke-QuietFactory {
    param([scriptblock]$Factory,[string]$Path,[hashtable]$Invocation)
    $previous=$script:QuietBuildingContract;$script:QuietBuildingContract=$true
    try{if($Path){& $Path $Invocation}else{Invoke-QuietCallback $Factory @($Invocation)}}
    finally{$script:QuietBuildingContract=$previous}
}