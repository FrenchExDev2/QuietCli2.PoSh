#requires -Version 7.6
#requires -PSEdition Core
param([Parameter(Mandatory)][hashtable]$Invocation)
# Source: https://git-scm.com/docs/git-status, porcelain v2 and NUL framing.
# Scope: git status [-- pathspec...]. One observed local worktree, no fetch.
$native=@($Invocation.ArgumentList)
if(!$native.Count -or $native[0] -cne 'status'){
    return New-QuietResult -Outcome Unsupported -Execution @{ExitCode=$null} -ErrorInfo @{Code='ArgumentsUnsupported'}
}
$paths=@()
if($native.Count -gt 1){
    if($native[1] -cne '--'){return New-QuietResult -Outcome Unsupported -Summary 'Supported: git status [-- pathspec...].' -Execution @{ExitCode=$null} -ErrorInfo @{Code='ArgumentsUnsupported'}}
    if($native.Count -gt 2){$paths=@($native[2..($native.Count-1)])}
}
$state=@{Branch=$null;HeadOid=$null;Unborn=$false;Detached=$false;Upstream=$null;Ahead=$null;Behind=$null;Pending=$null
    Entries=[Collections.Generic.List[object]]::new();Counts=@{Changed=0L;Staged=0L;Unstaged=0L;Untracked=0L;Conflicted=0L;Renamed=0L}
    Scope=@{WorkingDirectory=$Invocation.WorkingDirectory;Pathspec=@($paths);UntrackedFiles='all';IgnoreSubmodules='none';RemoteState='local refs only'}}
$parse={
    param($record,$state)
    if($record.Truncated){throw 'A status record was truncated.'}
    if($record.Stream -ne 'stdout'){return}
    $text=$record.Text
    if($state.Pending){
        if(!$text.Length){throw 'Missing rename source path.'}
        $state.Pending.OriginalPath=$text;$state.Pending=$null;return
    }
    if($text.StartsWith('# ')){
        if($text -match '^# branch\.(\S+) (.*)$'){
            $kind=$Matches[1];$value=$Matches[2]
            switch($kind){
                head{$state.Detached=$value -eq '(detached)';$state.Branch=if($state.Detached){$null}else{$value}}
                oid{$state.Unborn=$value -eq '(initial)';$state.HeadOid=if($state.Unborn){$null}else{$value}}
                upstream{$state.Upstream=$value}
                ab{if($value -notmatch '^\+(\d+) -(\d+)$'){throw 'Invalid branch divergence.'};$state.Ahead=[long]$Matches[1];$state.Behind=[long]$Matches[2]}
            }
        }
        return # Porcelain v2 explicitly permits unknown extension headers.
    }
    $entry=$null
    if($text.StartsWith('? ')){
        $entry=[ordered]@{Kind='Untracked';Status='??';Path=$text.Substring(2);OriginalPath=$null;Submodule=$null}
        $state.Counts.Untracked++;$state.Counts.Changed++
    }elseif($text.StartsWith('1 ') -or $text.StartsWith('2 ') -or $text.StartsWith('u ')){
        $kind=$text[0];$fields=if($kind -eq '1'){9}elseif($kind -eq '2'){10}else{11}
        $parts=$text.Split([char[]]' ',$fields)
        if($parts.Count -ne $fields -or $parts[1] -notmatch '^[.MADRCUT]{2}$' -or !$parts[-1].Length){throw 'Malformed porcelain v2 entry.'}
        $entry=[ordered]@{Kind=$(if($kind -eq 'u'){'Conflicted'}elseif($kind -eq '2'){'RenamedOrCopied'}else{'Tracked'})
            Status=$parts[1];Path=$parts[-1];OriginalPath=$null;Submodule=$parts[2]}
        $state.Counts.Changed++
        if($kind -eq 'u'){$state.Counts.Conflicted++}
        else{
            if($parts[1][0] -ne '.'){$state.Counts.Staged++}
            if($parts[1][1] -ne '.'){$state.Counts.Unstaged++}
        }
        if($kind -eq '2'){$state.Pending=$entry;if($parts[8].StartsWith('R')){$state.Counts.Renamed++}}
    }elseif($text.StartsWith('! ')){return}
    else{throw 'Unknown porcelain v2 record type.'}
    if(!$entry.Path.Length){throw 'Missing status path.'}
    $entry=[pscustomobject]$entry;if($state.Pending){$state.Pending=$entry};$state.Entries.Add($entry)
}
$complete={
    param($state,$capture)
    if($state.Pending){throw 'Incomplete rename record.'}
    [pscustomobject]@{Branch=$state.Branch;HeadOid=$state.HeadOid;Unborn=$state.Unborn;Detached=$state.Detached
        Upstream=$state.Upstream;Ahead=$state.Ahead;Behind=$state.Behind;Clean=($state.Counts.Changed -eq 0)
        Counts=[pscustomobject]$state.Counts;Entries=$state.Entries.ToArray();Scope=[pscustomobject]$state.Scope
        AnswerComplete=[bool]($capture.SourceComplete -and !$capture.Lossy)}
}
$projection={param($data,$settings) Limit-QuietProjection -Data $data -Property Entries -MaxItems $settings.MaxItems}
$arguments=@('--no-optional-locks','status','--porcelain=v2','-z','--branch','--untracked-files=all','--ignore-submodules=none')
if($paths.Count){$arguments+=@('--')+$paths}
# Version discovery belongs to this AI-authored Git contract, never to the engine.
$execute={
    param($call)
    $version=Invoke-QuietCli -FilePath $call.FilePath -ArgumentList @('--version') -WorkingDirectory $call.WorkingDirectory -Parse {
        param($capture)
        if($capture.Stdout -notmatch '^git version (\S+)'){throw 'Unexpected Git version response.'}
        $Matches[1]
    }
    if($version.Outcome -ne 'Success'){return}
    foreach($source in $version.Internal.Sources.Values){$source.ObservedVersion=$version.Data}
    $status=Invoke-QuietCli -FilePath $call.FilePath -ArgumentList $arguments -WorkingDirectory $call.WorkingDirectory -State $state -OnOutput $parse -Complete $complete -RecordDelimiter ([char]0) -ObservedVersion $version.Data
    if($status.Outcome -ne 'Success'){return}
    $status.Data|Add-Member -NotePropertyName GitVersion -NotePropertyValue $version.Data -Force
    $status.Data
}.GetNewClosure()
New-QuietContract -Id git.status -Execute $execute -Projection $projection -Summary 'Local Git worktree status.' -Documentation @('https://git-scm.com/docs/git-status','https://git-scm.com/docs/git#Documentation/git.txt---version') -SourcePath @($PSCommandPath) -SupportedForms @('git status','git status -- <pathspec>...')
