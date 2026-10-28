#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$OutputPath,[ValidateSet('QuietCli','.')][string]$ModuleDirectory='QuietCli')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-distribution-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary)|Out-Null
try{
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($ArchivePath),$temporary)
    $runtime=[IO.Path]::GetFullPath((Join-Path $temporary $ModuleDirectory))
    $package=Get-Content (Join-Path $runtime 'package-manifest.json') -Raw|ConvertFrom-Json
    $verified=0
    foreach($file in $package.Files){
        $target=[IO.Path]::GetFullPath((Join-Path $runtime $file.Path))
        if(!$target.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){throw 'Package manifest escapes extraction directory.'}
        if((Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.SHA256){throw "Package hash mismatch: $($file.Path)"}
        $verified++
    }
    if(Test-Path -LiteralPath (Join-Path $runtime 'modules')){throw 'The runtime archive must not contain consumer module copies.'}
    $body=@'
$ErrorActionPreference='Stop'
$runtime='__RUNTIME__';$work='__WORK__'
$env:QUIETCLI_DB_PATH=Join-Path $work 'history.sqlite3'
$env:QUIETCLI_CONFIG_PATH=Join-Path $work 'settings.json'
$env:QUIETCLI_TRACKING='0';$env:QUIETCLI_RECALL='0';$env:QUIETCLI_TOKENIZER='o200k_base'
Set-Location $work
Import-Module (Join-Path $runtime 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
$module=Get-Module FrenchExDev.QuietCli.PoSh
foreach($name in @('quiet','pump')){
    if(!$module.ExportedFunctions.ContainsKey($name)){throw "Missing standalone public function: $name"}
    $state=@{Lines=[Collections.Generic.List[string]]::new()}
    $result=& $name -AsObject -State $state -OnOutput {param($output,$state) if($output.Stream -eq 'stdout'){$state.Lines.Add($output.Text)}} -Complete {param($state,$capture) @{Lines=$state.Lines.ToArray()}} (Get-Process -Id $PID).Path -NoProfile -Command '[Console]::WriteLine("standalone")'
    if($result.Outcome -ne 'Success' -or $result.Data.Lines.Count -ne 1 -or $result.Data.Lines[0] -cne 'standalone'){throw "Standalone command failed: $name"}
}
$token=Measure-QuietToken -Text hello
if($token.Tokens -ne 1){throw 'Bundled tokenizer verification failed.'}
@{Outcome='Success';Version=$module.Version.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Platform=$PSVersionTable.OS
    PublicCommands=@('quiet','pump');CallbackParameter='OnOutput';RequiredModules=@($module.RequiredModules|ForEach-Object Name)
    Output='standalone';Tokenizer=$token.Profile;TokenizerVersion=$token.Version}|ConvertTo-Json -Depth 8 -Compress
'@
    $body=$body.Replace('__RUNTIME__',$runtime.Replace("'","''")).Replace('__WORK__',$temporary.Replace("'","''"))
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $child=pump -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} (Get-Process -Id $PID).Path -NoProfile -EncodedCommand $encoded
    if($child.Outcome -ne 'Success'){throw 'Standalone runtime verification failed; inspect the bounded child diagnostics.'}
    $observation=$child.Data
    $report=@{SchemaVersion=2;Outcome='Success';ArchiveSHA256=(Get-FileHash $ArchivePath -Algorithm SHA256).Hash;VerifiedFiles=$verified;FreshProcess=$true;Observation=$observation}
}finally{
    $expected=Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf $temporary)
    if([IO.Path]::GetFullPath($temporary) -cne [IO.Path]::GetFullPath($expected)){throw 'Unexpected extraction cleanup target.'}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{Outcome=$report.Outcome;Data=@{VerifiedFiles=$verified;Observation=$report.Observation;Report=[IO.Path]::GetFullPath($OutputPath)}}|ConvertTo-Json -Depth 10 -Compress
