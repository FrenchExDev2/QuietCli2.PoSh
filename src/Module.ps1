function ConvertTo-QuietDataLiteral {
    param($Value)
    if($null -eq $Value){return '$null'}
    if($Value -is [bool]){return $(if($Value){'$true'}else{'$false'})}
    if($Value -is [Collections.IDictionary]){
        $parts=foreach($key in @($Value.Keys|Sort-Object)){"'"+([string]$key).Replace("'","''")+"' = "+(ConvertTo-QuietDataLiteral $Value[$key])}
        return '@{'+($parts -join ';')+'}'
    }
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){
        $parts=foreach($item in $Value){ConvertTo-QuietDataLiteral $item}
        return '@('+($parts -join ',')+')'
    }
    return "'"+([string]$Value).Replace("'","''")+"'"
}
function Get-QuietModuleHash {
    param([Parameter(Mandatory)][string]$Path)
    $root=if(Test-Path -LiteralPath $Path -PathType Leaf){Split-Path -Parent $Path}else{$Path}
    $root=[IO.Path]::GetFullPath($root)
    $text=(@(Get-ChildItem -LiteralPath $root -Recurse -File|Where-Object Name -ne '.quietcli-validation.json'|Sort-Object FullName|ForEach-Object{
        [IO.Path]::GetRelativePath($root,$_.FullName)+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join [char]10
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}
function New-QuietModule {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Command,
        [Parameter(Mandatory)][string[]]$ContractPath,[string[]]$RecordId=@(),[string[]]$AssertionPath=@(),[string[]]$LiveTestPath=@(),
        [Parameter(Mandatory)][string]$OutputPath,[string]$Name,[string]$SourceRoot,[version]$Version='1.0.0')
    if(!$Name){$Name="FrenchExDev.QuietCli.$Command.PoSh"}
    if($Name -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Invalid module name.'}
    $destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if(Test-Path -LiteralPath $destination){throw 'Generation never overwrites an existing directory.'}
    if(!$PSCmdlet.ShouldProcess($destination,'Generate explicit QuietCli module sources')){return}
    foreach($path in @($ContractPath)+@($AssertionPath)+@($LiveTestPath)){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing source: $path"}}
    $records=@(foreach($id in $RecordId){$r=Read-QuietRecord $id;if(!$r.Promotable){throw "Record $id has implicit, missing or masked dependencies."};$r})
        $allPaths=@($ContractPath|ForEach-Object {(Resolve-Path -LiteralPath $_).Path})+@($records|ForEach-Object {foreach($s in $_.Sources){foreach($copy in $s.Sources){$copy.Path}}})
    if(!$SourceRoot){
        $SourceRoot=Split-Path -Parent $allPaths[0]
        foreach($p in $allPaths){
            while(([IO.Path]::GetRelativePath($SourceRoot,$p)).StartsWith('..'+[IO.Path]::DirectorySeparatorChar)){
                $parent=Split-Path -Parent $SourceRoot;if(!$parent -or $parent -eq $SourceRoot){throw 'Provide a common SourceRoot for all declared files.'};$SourceRoot=$parent
            }
        }
    }
    $SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
    $relativePath={
        param($p)
        $relative=[IO.Path]::GetRelativePath($SourceRoot,[IO.Path]::GetFullPath($p))
        if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar)){throw 'Declared source escapes SourceRoot.'}
        $relative.Replace([char]92,[char]47)
    }
    $staging=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-module-'+[guid]::NewGuid().ToString('N'))
    try{
        foreach($dir in @('contracts','test','fixtures')){[void][IO.Directory]::CreateDirectory((Join-Path $staging $dir))}
        foreach($path in $ContractPath){
            $relative=& $relativePath (Resolve-Path -LiteralPath $path).Path
            $target=Join-Path $staging ('contracts/'+$relative)
            if(Test-Path $target){throw 'Duplicate contract path.'}
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath $path -Destination $target
        }
        foreach($record in $records){
            foreach($s in $record.Sources){foreach($copy in $s.Sources){
                $target=Join-Path $staging ('contracts/'+(& $relativePath $copy.Path));[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                if(Test-Path $target){if((Get-FileHash $target -Algorithm SHA256).Hash -cne $copy.SHA256){throw "Source changed since RECORD: $($copy.Name)"}}
                else{if($copy.Bytes){[IO.File]::WriteAllBytes($target,[Convert]::FromBase64String($copy.Bytes))}else{[IO.File]::WriteAllText($target,$copy.Text,[Text.UTF8Encoding]::new($false))}}
            }}
            [IO.File]::WriteAllText((Join-Path $staging ('fixtures/'+$record.Id+'.json')),($record|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))
        }
        $assertions=@(foreach($p in $AssertionPath){$leaf=[IO.Path]::GetFileName($p);Copy-Item -LiteralPath $p -Destination (Join-Path $staging "test/$leaf");"test/$leaf"})
        $live=@(foreach($p in $LiveTestPath){$leaf=[IO.Path]::GetFileName($p);Copy-Item -LiteralPath $p -Destination (Join-Path $staging "test/$leaf");"test/$leaf"})
        $files=@($ContractPath|ForEach-Object {'contracts/'+(& $relativePath (Resolve-Path -LiteralPath $_).Path)})
        $factory='New-'+($Command -replace '[^a-zA-Z0-9]','')+'QuietContract'
        $quoted=(@($files|ForEach-Object {"'"+$_.Replace("'","''")+"'"})) -join ','
        $body=@'
# Generated from explicit, documented PowerShell contracts.
#requires -Version 7.6
#requires -PSEdition Core
$script:ContractFiles=@(__FILES__)
function __FACTORY__ {
    param($Invocation)
    foreach($relative in $script:ContractFiles){
        $candidate=& (Join-Path $PSScriptRoot $relative) $Invocation
        if($candidate -and $candidate.PSObject.TypeNames -contains 'QuietCli.Contract'){return $candidate}
        if($candidate -and $candidate.Outcome -ne 'Unsupported'){return $candidate}
    }
    New-QuietResult -Outcome Unsupported -Summary 'Arguments outside the documented module scope.' -Execution @{ExitCode=$null} -ErrorInfo @{Code='ArgumentsUnsupported'}
}
Register-QuietCommand -Command '__COMMAND__' -Factory (Get-Command __FACTORY__ -CommandType Function).ScriptBlock -ModuleId '__NAME__'
Export-ModuleMember -Function __FACTORY__
'@
        $body=$body.Replace('__FILES__',$quoted).Replace('__FACTORY__',$factory).Replace('__COMMAND__',$Command).Replace('__NAME__',$Name)
        [IO.File]::WriteAllText((Join-Path $staging "$Name.psm1"),$body,[Text.UTF8Encoding]::new($false))
        $guid=[guid]::new([Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes($Name)))
        $runtimeManifest=Import-PowerShellDataFile (Join-Path $script:QuietRoot 'FrenchExDev.QuietCli.PoSh.psd1')
        $manifestData=@{RootModule="$Name.psm1";ModuleVersion=[string]$Version;GUID=[string]$guid;Author=$runtimeManifest.Author;CompanyName=$runtimeManifest.CompanyName;Copyright=$runtimeManifest.Copyright;Description=('Documented '+$Command+' contracts for QuietCli.');PowerShellVersion='7.6'
            CompatiblePSEditions=@('Core');FunctionsToExport=@($factory);CmdletsToExport=@();AliasesToExport=@();VariablesToExport=@()
            RequiredModules=@(@{ModuleName='FrenchExDev.QuietCli.PoSh';ModuleVersion='2.0.0'})
            PrivateData=@{PSData=@{Tags=@('QuietCli',$Command,'PowerShell7');ProjectUri=$runtimeManifest.PrivateData.PSData.ProjectUri;LicenseUri=$runtimeManifest.PrivateData.PSData.LicenseUri};QuietCli=@{SchemaVersion=2;Command=$Command;Contracts=$files;Assertions=$assertions;LiveTests=$live;Factory=$factory}}}
        $manifest=Join-Path $staging "$Name.psd1"
        [IO.File]::WriteAllText($manifest,(ConvertTo-QuietDataLiteral $manifestData),[Text.UTF8Encoding]::new($false))
        $readme="# $Name"+[Environment]::NewLine+"Requires QuietCli 2.0+ and PowerShell Core 7.6+. Sources declare documentation and supported arguments. Fixtures are observations; independent assertions are required. Run Test-QuietModule, then Install-QuietModule explicitly."
        [IO.File]::WriteAllText((Join-Path $staging 'README.md'),$readme,[Text.UTF8Encoding]::new($false))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));Move-Item -LiteralPath $staging -Destination $destination
        [pscustomobject]@{Path=(Join-Path $destination "$Name.psd1");Command=$Command;Hash=(Get-QuietModuleHash $destination);Validated=$false}
    }finally{if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}}
}
function Test-QuietModule {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[switch]$IncludeLiveTests,[switch]$AsObject)
    $manifest=if(Test-Path -LiteralPath $Path -PathType Leaf){[IO.Path]::GetFullPath($Path)}else{@(Get-ChildItem -LiteralPath $Path -Filter '*.psd1' -File)[0].FullName}
    $root=Split-Path -Parent $manifest;$meta=(Import-PowerShellDataFile $manifest).PrivateData.QuietCli
    $failures=[Collections.Generic.List[string]]::new();$checks=0;$snapshot=$script:QuietCommands.Clone();$cases=[Collections.Generic.List[object]]::new()
    try{
        foreach($file in Get-ChildItem $root -Recurse -File|Where-Object Extension -in '.ps1','.psm1','.psd1'){
            $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            if($errors.Count){throw "Parse error in $($file.Name): $($errors[0].Message)"};$checks++
        }
        if(!$meta.Assertions.Count){throw 'Validation requires independent business assertions.'}
        $script:QuietCommands.Remove($meta.Command);Import-Module -Name $manifest -Force -ErrorAction Stop
        foreach($fixture in Get-ChildItem (Join-Path $root 'fixtures') -Filter '*.json' -File){
            $record=Get-Content $fixture.FullName -Raw|ConvertFrom-Json -AsHashtable -Depth 64
            Save-QuietEvent $record.Id record $meta.Command $record
            $actual=Invoke-QuietRecord -Id $record.Id -AsObject
            if($actual.Outcome -ne $record.Outcome){throw "Replay outcome mismatch: $($fixture.Name)"}
            $cases.Add(@{Record=$record;Actual=$actual});$checks++
        }
        $previous=$script:QuietReplay;$script:QuietReplay=$true
        try{foreach($test in $meta.Assertions){$null=Invoke-QuietCallback {param($p,$items) & $p $items} @((Join-Path $root $test),$cases.ToArray());$checks++}}
        finally{$script:QuietReplay=$previous}
        if($IncludeLiveTests){foreach($test in $meta.LiveTests){$null=Invoke-QuietCallback {param($p,$m) & $p $m} @((Join-Path $root $test),$manifest);$checks++}}
    }catch{$failures.Add($_.Exception.Message)}
    finally{$script:QuietCommands=$snapshot}
    $report=@{SchemaVersion=2;Hash=(Get-QuietModuleHash $root);Success=($failures.Count -eq 0);Checks=$checks;Failures=$failures.ToArray();LiveTestsRun=[bool]$IncludeLiveTests;PowerShell=$PSVersionTable.PSVersion.ToString();Platform=$PSVersionTable.OS}
    [IO.File]::WriteAllText((Join-Path $root '.quietcli-validation.json'),($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    $result=New-QuietResult -Outcome $(if($report.Success){'Success'}else{'Failed'}) -Data $report -NoRegister
    if($AsObject){$result}else{Out-QuietResult $result}
}
function Install-QuietModule {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$Path,[string]$InstallRoot)
    $root=if(Test-Path -LiteralPath $Path -PathType Leaf){Split-Path -Parent ([IO.Path]::GetFullPath($Path))}else{[IO.Path]::GetFullPath($Path)}
    $validationPath=Join-Path $root '.quietcli-validation.json'
    if(!(Test-Path $validationPath)){throw 'Run Test-QuietModule before installation.'}
    $report=Get-Content $validationPath -Raw|ConvertFrom-Json
    if(!$report.Success -or $report.Hash -cne (Get-QuietModuleHash $root)){throw 'Validation failed or module sources changed.'}
    $manifest=@(Get-ChildItem $root -Filter '*.psd1' -File)[0];$data=Import-PowerShellDataFile $manifest.FullName;$command=$data.PrivateData.QuietCli.Command
    $settings=Get-QuietConfiguration
    if(@($settings.Modules|Where-Object Command -eq $command).Count){throw "A module is already configured for $command."}
    if(!$InstallRoot){$InstallRoot=Join-Path $HOME '.quietcli/modules'}
    $target=Join-Path $InstallRoot ($manifest.BaseName+'/'+$data.ModuleVersion)
    if(Test-Path $target){throw 'Installation directory already exists.'}
    if(!$PSCmdlet.ShouldProcess($target,'Install validated QuietCli module')){return}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath $root -Destination $target -Recurse
    $installed=Join-Path $target $manifest.Name;$settings.Modules=@($settings.Modules)+@(@{Command=$command;Path=$installed;Hash=$report.Hash})
    $config=if($env:QUIETCLI_CONFIG_PATH){$env:QUIETCLI_CONFIG_PATH}else{Join-Path $HOME '.quietcli/config.json'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($config))))
    $temporary=$config+'.'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($settings|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$config,$true)
    [pscustomobject]@{Command=$command;Path=$installed;Hash=$report.Hash}
}
