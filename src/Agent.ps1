function Get-QuietAgentInstruction {
    [CmdletBinding()]param()
    @'
Use PowerShell Core 7.6+ and QuietCli 2. Define the question and business object first.
Read the executable's installed help or official documentation before writing its contract.
Use quiet -ContractPath <factory.ps1> [options] executable arguments, or an explicitly installed module.
Unknown commands return Unsupported without execution. QuietCli contains no CLI catalogue.
Keep local results in variables; send only a projection through Out-QuietResult.
Use -Record to retain explicit code, documentation and masked evidence. Replay records instead of rerunning commands.
Generate modules from explicit sources and independent assertions; test, then install explicitly.
Never output Capture or Internal. Existing authorization still applies to native commands.
'@
}
function Invoke-QuietHook {
    [CmdletBinding()]param([Parameter(Mandatory)][Alias('Event')]$HookInput,[ValidateSet('off','warn','deny','rewrite')][string]$Awareness='warn')
    $command=[string]$HookInput.tool_input.command
    if($Awareness -eq 'off' -or !$command){return @{}}
    # PowerShell AST inspects executable segments without evaluating the supplied command.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
    $names=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    $allowed=@('quiet','pump','FrenchExDev.QuietCli.PoSh\quiet','FrenchExDev.QuietCli.PoSh\pump','Invoke-QuietCli','Invoke-QuietTask','Out-QuietResult','Import-Module','Set-Location','cd')
    $uncovered=@($names|Where-Object {$_ -and $_ -notin $allowed})
    if(!$errors.Count -and !$uncovered.Count){return @{}}
    $message='Use QuietCli with a documented AI-authored contract or an installed module; never forward unbounded native output.'
    $specific=@{hookEventName='PreToolUse'}
    if($Awareness -eq 'deny' -and !$errors.Count){$specific.permissionDecision='deny';$specific.permissionDecisionReason=$message}
    elseif($Awareness -eq 'rewrite' -and !$errors.Count -and $names.Count -eq 1 -and $command -notmatch '[|;&<>$(){}*?]' -and $command.IndexOf([char]96) -lt 0 -and $command -notmatch '\\'){
        $first=($command.Trim() -split '\s+')[0]
        if(Resolve-QuietCommand $first){
            $manifest=(Join-Path $script:QuietRoot 'FrenchExDev.QuietCli.PoSh.psd1').Replace("'","''")
            $body="Import-Module '"+$manifest+"' -DisableNameChecking; quiet -- "+$command
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
            $specific.updatedInput=@{command='pwsh -NoProfile -EncodedCommand '+$encoded}
            $specific.permissionDecision='ask';$specific.permissionDecisionReason=$message
        }
        else{$specific.additionalContext=$message}
    }else{$specific.additionalContext=$message}
    @{hookSpecificOutput=$specific}
}
function Install-QuietHook {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$SettingsPath,[ValidateSet('off','warn','deny','rewrite')][string]$Awareness='warn')
    $path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SettingsPath)
    $settings=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
    if(!$settings.ContainsKey('hooks')){$settings.hooks=@{}}
    $entries=if($settings.hooks.ContainsKey('PreToolUse')){@($settings.hooks.PreToolUse)}else{@()}
    $entries=@($entries|Where-Object {($_|ConvertTo-Json -Depth 20 -Compress) -notmatch 'Invoke-QuietHook\.ps1'})
    $launcher=Join-Path $script:QuietRoot 'scripts/Invoke-QuietHook.ps1'
    $pwsh=(Get-Process -Id $PID).Path
    $entry=@{matcher='Bash|PowerShell';hooks=@(@{type='command';command=('"'+$pwsh+'" -NoProfile -File "'+$launcher+'" -Awareness '+$Awareness)})}
    $settings.hooks.PreToolUse=$entries+@($entry)
    if($PSCmdlet.ShouldProcess($path,'Install QuietCli hook')){
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,($settings|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    }
}
function Uninstall-QuietHook {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$SettingsPath)
    if(!(Test-Path $SettingsPath)){return}
    $settings=Get-Content $SettingsPath -Raw|ConvertFrom-Json -AsHashtable
    if($settings.hooks -and $settings.hooks.PreToolUse){
        $settings.hooks.PreToolUse=@($settings.hooks.PreToolUse|Where-Object {($_|ConvertTo-Json -Depth 20 -Compress) -notmatch 'Invoke-QuietHook\.ps1'})
        if($PSCmdlet.ShouldProcess($SettingsPath,'Remove QuietCli hook')){[IO.File]::WriteAllText([IO.Path]::GetFullPath($SettingsPath),($settings|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
    }
}
function Get-QuietSession {
    [CmdletBinding()]param([Parameter(Mandatory)][string[]]$Path,[switch]$AsObject)
    $sessions=@(foreach($item in $Path){
        $files=if(Test-Path $item -PathType Container){@(Get-ChildItem $item -Filter '*.jsonl' -File -Recurse)}else{@(Get-Item $item)}
        foreach($file in $files){
            $calls=0;$pumped=0;$unknown=0
            foreach($line in [IO.File]::ReadLines($file.FullName)){
                try{$HookInput=$line|ConvertFrom-Json -AsHashtable
                    $blocks=if($HookInput.message){@($HookInput.message.content)}elseif($HookInput.payload){@($HookInput.payload)}else{@($HookInput)}
                    foreach($block in $blocks){
                        if($block -isnot [Collections.IDictionary]){continue}
                        $text=if($block.input -and $block.input.command){[string]$block.input.command}elseif($block.arguments){$a=$block.arguments|ConvertFrom-Json -AsHashtable;[string]$a.cmd}else{''}
                        if($text){$calls++;if($text -match '(?i)(?:^|[\s;])(?:(?:FrenchExDev\.QuietCli\.PoSh\\)?(?:pump|quiet)|Invoke-QuietCli|Invoke-QuietTask)(?:\s|$)'){$pumped++}else{$unknown++}}
                    }
                }catch{$unknown++}
            }
            @{Path=$file.FullName;Calls=$calls;Pumped=$pumped;UnpumpedOrUnknown=$unknown;Adoption=$(if($calls){$pumped/$calls}else{$null})}
        }
    })
    $result=New-QuietResult -Data $sessions -NoRegister
    if($AsObject){$result}else{Out-QuietResult $result}
}
