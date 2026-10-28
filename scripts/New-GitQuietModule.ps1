#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([string]$OutputPath=(Join-Path $PSScriptRoot '../../FrenchExDev.QuietCli.Git.PoSh'),[string]$ReadmePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-git-module-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
$previous=@{};foreach($key in @('QUIETCLI_DB_PATH','QUIETCLI_CONFIG_PATH','QUIETCLI_TRACKING','QUIETCLI_RECALL')){$previous[$key]=[Environment]::GetEnvironmentVariable($key)}
$records=[Collections.Generic.List[string]]::new()
function Git {
    param([string]$Repo,[string[]]$Words)
    $r=quiet -AsObject -WorkingDirectory $Repo -OnOutput {param($r,$s)} git @Words
    if($r.Outcome -ne 'Success'){throw "Fixture Git failure: $($Words -join ' ') / $($r.Execution.ExitCode)"}
    $r.Capture.Dispose()
}
function Repo {
    param([string]$Name,[switch]$Commit)
    $p=Join-Path $temporary $Name;[void][IO.Directory]::CreateDirectory($p)
    Git $p @('init','-q','--initial-branch=main');Git $p @('config','user.name','QuietCli fixture');Git $p @('config','user.email','quietcli@example.invalid')
    if($Commit){[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'initial');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','initial')}
    $p
}
function Record-Case {
    param([string]$Repo)
    $r=quiet -AsObject -Record -WorkingDirectory $Repo -ContractPath (Join-Path $root 'examples/contracts/Git.Status.ps1') git status
    if($r.Outcome -ne 'Success' -or !$r.RecordId){throw "Unable to record fixture: $($r.Error.Message)"}
    $records.Add($r.RecordId)
    foreach($source in $r.Internal.Sources.Values){$source.Capture.Dispose()}
}
try{
    $env:QUIETCLI_DB_PATH=Join-Path $temporary 'history.sqlite3';$env:QUIETCLI_CONFIG_PATH=Join-Path $temporary 'settings.json';$env:QUIETCLI_TRACKING='1';$env:QUIETCLI_RECALL='0'
    Record-Case (Repo 'unborn-clean')
    Record-Case (Repo 'clean' -Commit)
    $p=Repo 'untracked';[IO.File]::WriteAllText((Join-Path $p 'new file.txt'),'new');Record-Case $p
    $p=Repo 'unstaged' -Commit;[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'modified');Record-Case $p
    $p=Repo 'staged' -Commit;[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'modified');Git $p @('add','tracked.txt');Record-Case $p
    $p=Repo 'renamed' -Commit;Git $p @('mv','tracked.txt','renamed file.txt');Record-Case $p
    $p=Repo 'detached' -Commit;Git $p @('checkout','--detach','-q');Record-Case $p
    $p=Repo 'unicode';[IO.File]::WriteAllText((Join-Path $p ("été "+[char]10+'-file')),'unicode');Record-Case $p
    $p=Repo 'upstream' -Commit;Git $p @('branch','reference');Git $p @('branch','--set-upstream-to=reference','main')
    [IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'next');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','next');Record-Case $p
    $p=Repo 'conflict' -Commit;Git $p @('checkout','-qb','other')
    [IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'other');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','other')
    Git $p @('checkout','-q','main');[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'main');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','main')
    $merge=Invoke-QuietCli -FilePath git -WorkingDirectory $p -ArgumentList @('merge','other') -SuccessExitCodes @(0,1) -Parse {param($c) $c.ExitCode}
    if($merge.Data -ne 1){throw 'Conflict fixture did not conflict.'};Record-Case $p
    $assertions=Join-Path $temporary 'Git.Status.Assertions.ps1'
    $assertionCode=@'
# Expectations follow the fixture preparation, not a snapshot of the candidate.
param($Cases)
if($Cases.Count -ne 10){throw 'Expected all ten independently prepared Git scenarios.'}
foreach($case in $Cases){
    $d=$case.Actual.Data
    if($case.Actual.Outcome -ne 'Success' -or !$d.AnswerComplete -or !$d.GitVersion){throw 'Incomplete Git observation.'}
    $name=Split-Path -Leaf $case.Record.Sources[0].OriginalRequest.WorkingDirectory
    switch($name){
        unborn-clean{if(!$d.Clean -or !$d.Unborn -or $d.Branch -ne 'main'){throw 'Unborn clean fixture.'}}
        clean{if(!$d.Clean -or $d.Unborn -or !$d.HeadOid){throw 'Committed clean fixture.'}}
        untracked{if($d.Counts.Untracked -ne 1 -or $d.Entries[0].Path -ne 'new file.txt'){throw 'Untracked fixture.'}}
        unstaged{if($d.Counts.Unstaged -ne 1 -or $d.Counts.Staged -ne 0){throw 'Unstaged fixture.'}}
        staged{if($d.Counts.Staged -ne 1 -or $d.Counts.Unstaged -ne 0){throw 'Staged fixture.'}}
        renamed{if($d.Counts.Renamed -ne 1 -or $d.Entries[0].OriginalPath -ne 'tracked.txt' -or $d.Entries[0].Path -ne 'renamed file.txt'){throw 'Rename fixture.'}}
        detached{if(!$d.Detached -or $null -ne $d.Branch){throw 'Detached fixture.'}}
        unicode{if($d.Entries[0].Path -ne ("été "+[char]10+'-file')){throw 'Unicode/NUL fixture.'}}
        upstream{if($d.Upstream -ne 'reference' -or $d.Ahead -ne 1 -or $d.Behind -ne 0){throw 'Local upstream fixture.'}}
        conflict{if($d.Counts.Conflicted -ne 1 -or $d.Clean){throw 'Merge conflict fixture.'}}
        default{throw 'Unknown fixture scenario.'}
    }
}
'@
    [IO.File]::WriteAllText($assertions,$assertionCode,[Text.UTF8Encoding]::new($true))
    $module=New-QuietModule -Command git -Name FrenchExDev.QuietCli.Git.PoSh -ContractPath (Join-Path $root 'examples/contracts/Git.Status.ps1') -RecordId $records.ToArray() -AssertionPath $assertions -OutputPath $OutputPath
    if($ReadmePath){
        $readme=(Resolve-Path -LiteralPath $ReadmePath -ErrorAction Stop).ProviderPath
        [IO.File]::Copy($readme,(Join-Path (Split-Path $module.Path) 'README.md'),$true)
    }
    $validation=Test-QuietModule -Path $module.Path -AsObject
    if($validation.Outcome -ne 'Success'){throw ($validation.Data.Failures -join '; ')}
    @{Outcome='Success';Data=@{Module=$module.Path;Fixtures=$records.Count;Checks=$validation.Data.Checks;Hash=$validation.Data.Hash}}|ConvertTo-Json -Depth 8 -Compress
}finally{
    foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key])}
    if($temporary.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::Ordinal) -and (Split-Path -Leaf $temporary).StartsWith('quietcli-git-module-')){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
