#requires -Version 7.6
BeforeAll {
    $script:QuietRoot=Split-Path -Parent $PSScriptRoot
    $script:Manifest=Join-Path $QuietRoot 'FrenchExDev.QuietCli.PoSh.psd1'
    $env:QUIETCLI_DB_PATH=Join-Path $TestDrive 'history.sqlite3'
    $env:QUIETCLI_CONFIG_PATH=Join-Path $TestDrive 'settings.json'
    $env:QUIETCLI_TRACKING='1';$env:QUIETCLI_RECALL='1'
    Import-Module $Manifest -DisableNameChecking
    $script:Pwsh=(Get-Process -Id $PID).Path
    $script:GitContract=Join-Path $QuietRoot 'examples/contracts/Git.Status.ps1'
    function Native {
        param([string]$Code,[hashtable]$Extra=@{})
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
        Invoke-QuietCli -FilePath $Pwsh -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) @Extra
    }
    function Git {
        param([string]$Repo,[string[]]$Words)
        $r=pump -AsObject -WorkingDirectory $Repo -OnOutput {param($r,$s)} git @Words
        if($r.Outcome -ne 'Success'){throw "Git fixture failed: $($Words -join ' ') exit=$($r.Execution.ExitCode)"}
    }
    function Repo {
        param([string]$Name,[switch]$Commit)
        $p=Join-Path $TestDrive $Name;[void][IO.Directory]::CreateDirectory($p)
        Git $p @('init','-q','--initial-branch=main')
        Git $p @('config','user.name','QuietCli Test');Git $p @('config','user.email','quietcli@example.invalid')
        if($Commit){[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'initial');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','initial')}
        $p
    }
    function Status {
        param([string]$Repo,[switch]$Record)
        pump -AsObject -WorkingDirectory $Repo -ContractPath $GitContract -Record:$Record git status
    }
}
Describe 'QuietCli V2 local values and delivery' {
    It 'retains all 1500 local items and limits only the delivery' {
        $r=New-QuietResult -Data @(1..1500)
        $r.Data.Count|Should -Be 1500
        $d=$r|ConvertTo-QuietJson -MaxItems 3|ConvertFrom-Json
        @($d.Data).Count|Should -Be 3
        $d.Truncation.Omitted|Should -Be 1497
        $r.Data.Count|Should -Be 1500
    }
    It 'keeps complete data when the final byte budget drops the projection' {
        $r=New-QuietResult -Data @{Text=('x'*10000)}
        $text=$r|ConvertTo-QuietJson -MaxOutputBytes 512
        [Text.Encoding]::UTF8.GetByteCount($text)|Should -BeLessOrEqual 512
        ($text|ConvertFrom-Json).Truncation.Applied|Should -BeTrue
        $r.Data.Text.Length|Should -Be 10000
    }
    It 'projects domain values without modifying the original object' {
        $r=New-QuietResult -Data @{Values=@(1..2000)} -Projection {param($d,$s) @{Total=$d.Values.Count}}
        ($r|ConvertTo-QuietJson|ConvertFrom-Json).Data.Total|Should -Be 2000
        $r.Data.Values.Count|Should -Be 2000
    }
    It 'preserves empty singleton and nested arrays' {
        $r=New-QuietResult -Data @{Empty=@();One=@(7);Nested=@(@{Values=@(1,2)})}
        $d=$r|ConvertTo-QuietJson|ConvertFrom-Json
        @($d.Data.Empty).Count|Should -Be 0
        @($d.Data.One).Count|Should -Be 1
        @($d.Data.Nested[0].Values).Count|Should -Be 2
    }
    It 'masks secrets only at delivery' {
        $r=New-QuietResult -Data @{Password='private-value';Message='token=abcdefghijk'}
        $text=$r|ConvertTo-QuietJson
        $text|Should -Not -Match 'private-value|abcdefghijk'
        $r.Data.Password|Should -Be 'private-value'
    }
    It 'supports YAML without serializing capture or internal metadata' {
        $r=New-QuietResult -Data @{Number=3;Items=@('a','b')}
        $text=$r|Out-QuietResult -AsYaml
        $text|Should -Match '"SchemaVersion": 2'
        $text|Should -Not -Match 'Internal|Capture'
    }
}
Describe 'Native execution and composition' {
    It 'drains both streams and parses a complete document' {
        $r=Native '[Console]::Write("alpha");[Console]::Error.Write("beta")' @{Parse={param($c) @{Out=$c.Stdout;Err=$c.Stderr}}}
        $r.Outcome|Should -Be Success;$r.Data.Out|Should -Be alpha;$r.Data.Err|Should -Be beta
        $r.Completeness.Source|Should -BeTrue
    }
    It 'preserves Unicode stdin and environment overrides' {
        $r=Native '[Console]::Write([Console]::In.ReadToEnd()+$env:QUIET_TEST)' @{InputText='été 🌍';Environment=@{QUIET_TEST='ok'};Parse={param($c) $c.Stdout}}
        $r.Data|Should -Be 'été 🌍ok'
    }
    It 'handles NUL framing and embedded newlines' {
        $s=@{Items=[Collections.Generic.List[string]]::new()}
        $r=Native '[Console]::Write("a"+[char]10+"b"+[char]0+"été"+[char]0)' @{RecordDelimiter=[char]0;State=$s;OnOutput={param($r,$s) $s.Items.Add($r.Text)};Complete={param($s,$c) ,$s.Items.ToArray()}}
        $r.Outcome|Should -Be Success
        $r.Data.Count|Should -Be 2
        $r.Data[0]|Should -Be ("a"+[char]10+"b")
    }
    It 'counts an assigned failed native call exactly once through an explicit step' {
        $r=Invoke-QuietTask {
            $step=Invoke-QuietStep named { Native 'exit 7' @{Parse={param($c) @{Seen=$true}}} }
            @{Done=$true}
        }
        $r.Outcome|Should -Be Failed;$r.Execution.Steps|Should -Be 1;$r.Execution.Issues[0].ExitCode|Should -Be 7
    }
    It 'counts an assigned failed native call without an explicit step' {
        $r=Invoke-QuietTask {$step=Native 'exit 8' @{Parse={param($c) $null}};@{Done=$true}}
        $r.Outcome|Should -Be Failed;$r.Execution.Steps|Should -Be 1
    }
    It 'continues streaming analysis after its saved capture fills' {
        $s=@{Count=0}
        $r=Native '1..200 | ForEach-Object {[Console]::WriteLine("record-$_")}' @{MaxCaptureBytes=64;State=$s;OnOutput={param($r,$s) $s.Count++};Complete={param($s,$c) @{Count=$s.Count}}}
        $r.Outcome|Should -Be Success;$r.Data.Count|Should -Be 200
        $r.Completeness.Analysis|Should -BeTrue;$r.Completeness.Capture|Should -BeFalse
    }
    It 'rejects incomplete document captures' {
        $r=Native '[Console]::Write("x"*1000)' @{MaxCaptureBytes=64;Parse={param($c) $c.Stdout}}
        $r.Outcome|Should -Be Failed;$r.Error.Code|Should -Be CaptureLimit
    }
    It 'reports oversized records while fully draining the source' {
        $r=Native '[Console]::WriteLine("x"*2000)' @{MaxRecordCharacters=1024;OnOutput={param($r,$s)};Complete={param($s,$c) @{Done=$true}}}
        $r.Error.Code|Should -Be RecordLimit;$r.Completeness.Source|Should -BeTrue
    }
    It 'retains callback failure and still drains stdout and stderr' {
        $r=Native '1..50|ForEach-Object {[Console]::WriteLine($_);[Console]::Error.WriteLine($_)}' @{OnOutput={param($r,$s) throw 'bad parser'};Complete={param($s,$c) @{Drained=$c.SourceComplete}}}
        $r.Error.Code|Should -Be ParserFailed;$r.Data.Drained|Should -BeTrue
    }
    It 'reports native failure separately from finalizer failure' {
        $r=Native 'exit 4' @{OnOutput={param($r,$s)};Complete={throw 'finalizer failed'}}
        $r.Error.Code|Should -Be NativeFailed;$r.Execution.FinalizerError.Code|Should -Be FinalizerFailed
    }
    It 'times out a quiet child' {
        $r=Native 'Start-Sleep -Seconds 5' @{TimeoutSeconds=1;Parse={param($c) $null}}
        $r.Outcome|Should -Be Timeout
    }
    It 'cancels before native startup' {
        $signal=[Threading.CancellationTokenSource]::new();$signal.Cancel()
        $marker=Join-Path $TestDrive 'must-not-start'
        $r=Native ("[IO.File]::WriteAllText('"+$marker+"','bad')") @{CancellationToken=$signal.Token;Parse={param($c) $null}}
        $r.Outcome|Should -Be Cancelled
        Test-Path $marker|Should -BeFalse
        $signal.Dispose()
    }
    It 'cancels a running quiet child' {
        $signal=[Threading.CancellationTokenSource]::new();$signal.CancelAfter(1000)
        try{$r=Native 'Start-Sleep -Seconds 5' @{CancellationToken=$signal.Token;Parse={param($c) $null}};$r.Outcome|Should -Be Cancelled}finally{$signal.Dispose()}
    }
    It 'does not run an uncovered executable even with RECORD' {
        $r=pump -AsObject -Record $Pwsh -NoProfile -Command 'throw "must not run"'
        $r.Outcome|Should -Be Unsupported;$r.Error.Code|Should -Be ContractNotFound
    }
}
Describe 'Documented Git status contracts' {
    It 'reports an unborn clean repository' {
        $p=Repo unborn;$r=Status $p
        $r.Outcome|Should -Be Success;$r.Data.Unborn|Should -BeTrue;$r.Data.Clean|Should -BeTrue;$r.Data.Branch|Should -Be main
    }
    It 'changes its observation with the repository and time' {
        $p=Repo dynamic -Commit;$clean=Status $p
        [IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'changed')
        [IO.File]::WriteAllText((Join-Path $p 'new file.txt'),'new')
        $changed=Status $p
        $clean.Data.Clean|Should -BeTrue;$changed.Data.Clean|Should -BeFalse
        $changed.Data.Counts.Unstaged|Should -Be 1;$changed.Data.Counts.Untracked|Should -Be 1
        Git $p @('add','tracked.txt')
        (Status $p).Data.Counts.Staged|Should -Be 1
    }
    It 'retains original and destination rename paths' {
        $p=Repo renamed -Commit;Git $p @('mv','tracked.txt','renamed file.txt')
        $r=Status $p
        $r.Data.Counts.Renamed|Should -Be 1;$r.Data.Entries[0].OriginalPath|Should -Be tracked.txt
        $r.Data.Entries[0].Path|Should -Be 'renamed file.txt'
    }
    It 'handles detached HEAD' {
        $p=Repo detached -Commit;Git $p @('checkout','--detach','-q')
        $r=Status $p;$r.Data.Detached|Should -BeTrue;$r.Data.Branch|Should -BeNullOrEmpty
    }
    It 'handles newline Unicode and leading dash pathnames' {
        $p=Repo unicode
        $name="été "+[char]10+'-file'
        [IO.File]::WriteAllText((Join-Path $p $name),'hello')
        $r=Status $p;$r.Data.Entries[0].Path|Should -Be $name
    }
    It 'rejects unsupported arguments before native execution' {
        $r=pump -AsObject -ContractPath $GitContract git status --verbose
        $r.Outcome|Should -Be Unsupported
    }
    It 'replays the stored observation without observing later repository changes' {
        $p=Repo replay -Commit;[IO.File]::WriteAllText((Join-Path $p 'new.txt'),'one')
        $original=Status $p -Record
        $original.RecordId|Should -Not -BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $p 'later.txt'),'two')
        $replayed=Invoke-QuietRecord -Id $original.RecordId -ContractPath $GitContract -AsObject
        $replayed.Outcome|Should -Be Success;$replayed.Data.Counts.Untracked|Should -Be 1
        (Status $p).Data.Counts.Untracked|Should -Be 2
        (Get-QuietRecord -Id $original.RecordId -AsObject).Promotable|Should -BeTrue
    }
}
Describe 'RECORD modules and measurement' {
    It 'generates a module validates independent assertions and installs explicitly' {
        $p=Repo packaged
        [IO.File]::WriteAllText((Join-Path $p 'proof.txt'),'one')
        $observed=Status $p -Record
        $assert=Join-Path $TestDrive 'Independent.Assertions.ps1'
        [IO.File]::WriteAllText($assert,'param($Cases) if($Cases.Count -ne 1 -or $Cases[0].Actual.Data.Counts.Untracked -ne 1 -or $Cases[0].Actual.Data.Entries[0].Path -ne "proof.txt"){throw "Expected the independently prepared one-file unborn fixture."}')
        $target=Join-Path $TestDrive 'generated'
        $generated=New-QuietModule -Command git -Name FrenchExDev.QuietCli.Git.PoSh -ContractPath $GitContract -RecordId $observed.RecordId -AssertionPath $assert -OutputPath $target
        $check=Test-QuietModule -Path $generated.Path -AsObject
        $check.Data.Success|Should -BeTrue -Because ($check.Data.Failures -join '; ')
        $installed=Install-QuietModule -Path $generated.Path -InstallRoot (Join-Path $TestDrive 'installed')
        $code="Import-Module '"+$Manifest+"' -DisableNameChecking; Set-Location '"+$p+"'; "+'$r=pump -AsObject git status; @{Outcome=$r.Outcome;Count=$r.Data.Counts.Untracked}|ConvertTo-Json -Compress'
        $fresh=Native $code @{Parse={param($c) $c.Stdout|ConvertFrom-Json}}
        $fresh.Outcome|Should -Be Success;$fresh.Data.Outcome|Should -Be Success;$fresh.Data.Count|Should -Be 1
        $second=Join-Path $TestDrive 'generated-again'
        $again=New-QuietModule -Command git -Name FrenchExDev.QuietCli.Git.PoSh -ContractPath $GitContract -RecordId $observed.RecordId -AssertionPath $assert -OutputPath $second
        $again.Hash|Should -Be $generated.Hash
    }
    It 'does not promote inline callback closures without explicit source files' {
        $r=Native '"hello"' @{Parse={param($c) @{Text=$c.Stdout}};Record=$true}
        (Get-QuietRecord -Id $r.RecordId -AsObject).Promotable|Should -BeFalse
    }
    It 'rejects replay that tries to execute another native command' {
        $r=Native '"saved"' @{Parse={param($c) $c.Stdout};Record=$true}
        $contract=New-QuietContract -Id forbidden -FilePath $Pwsh -Parse {param($c) Invoke-QuietCli -FilePath git -ArgumentList @('--version') -Parse {param($c) $c.Stdout}}
        $replay=Invoke-QuietRecord -Id $r.RecordId -Contract $contract -AsObject
        $replay.Outcome|Should -Be Failed;$replay.Error.Code|Should -Be ReplayFailed
    }
    It 'counts the final delivery once even when serialized twice' {
        $r=Native '"measured"' @{Parse={param($c) $c.Stdout}}
        $before=(QuietCliGain -View Object).Totals.Deliveries
        $null=$r|ConvertTo-QuietJson;$null=$r|ConvertTo-QuietJson
        (QuietCliGain -View Object).Totals.Deliveries|Should -Be ($before+1)
    }
    It 'keeps an invalid encoding visible and its exact token baseline unknown' {
        $r=Native '[Console]::OpenStandardOutput().Write([byte[]](255,10))' @{OnOutput={param($r,$s)};Complete={param($s,$c) @{Seen=$true}}}
        $r.Capture.Lossy|Should -BeTrue
        $null=$r|ConvertTo-QuietJson
        $r.Measurement.Status|Should -Be CounterUnavailable
    }
    It 'preserves business success when storage is unavailable' {
        $previous=$env:QUIETCLI_DB_PATH
        try{$env:QUIETCLI_DB_PATH='/proc/quietcli-impossible/history.sqlite3';$r=Native '"okay"' @{Parse={param($c) $c.Stdout};Record=$true};$r.Outcome|Should -Be Success;$null=$r|ConvertTo-QuietJson;$r.Measurement.Status|Should -Be StorageUnavailable}
        finally{$env:QUIETCLI_DB_PATH=$previous}
    }
    It 'installs hooks only on request and preserves unrelated settings' {
        $path=Join-Path $TestDrive 'claude-settings.json'
        [IO.File]::WriteAllText($path,'{"custom":42,"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[]}]}}')
        Install-QuietHook -SettingsPath $path
        $settings=Get-Content $path -Raw|ConvertFrom-Json
        $settings.custom|Should -Be 42;$settings.hooks.PreToolUse.Count|Should -Be 2
        Uninstall-QuietHook -SettingsPath $path
        (Get-Content $path -Raw|ConvertFrom-Json).hooks.PreToolUse.Count|Should -Be 1
    }
}

Describe 'Additional V2 qualification' {
    It 'replays the observed interleaving of stdout and stderr' {
        $state=@{Trace=[Collections.Generic.List[string]]::new()}
        $read={param($r,$s) $s.Trace.Add($r.Stream+':'+$r.Text)}
        $finish={param($s,$c) ,$s.Trace.ToArray()}
        $live=Native '[Console]::WriteLine("first");Start-Sleep -Milliseconds 40;[Console]::Error.WriteLine("second");Start-Sleep -Milliseconds 40;[Console]::WriteLine("third")' @{OnOutput=$read;State=$state;Complete=$finish;Record=$true}
        $contract=New-QuietContract -Id ordered -FilePath $Pwsh -State @{Trace=[Collections.Generic.List[string]]::new()} -OnOutput $read -Complete $finish
        $replayed=Invoke-QuietRecord -Id $live.RecordId -Contract $contract -AsObject
        $replayed.Outcome|Should -Be Success
        ($replayed.Data -join '|')|Should -Be ($live.Data -join '|')
    }
    It 'replays an explicit multi-call task and its original aggregation' {
        $path=Join-Path $TestDrive 'Composed.Contract.ps1'
        $code=@'
param($Invocation)
New-QuietContract -Id composed -SourcePath @($PSCommandPath) -Documentation @('fixture:two independent integers') -Execute {
    param($call)
    $first=Invoke-QuietCli -FilePath $call.FilePath -ArgumentList @('-NoProfile','-Command','[Console]::Write(12)') -Parse {param($c) [int]$c.Stdout}
    $second=Invoke-QuietCli -FilePath $call.FilePath -ArgumentList @('-NoProfile','-Command','[Console]::Write(30)') -Parse {param($c) [int]$c.Stdout}
    @{Total=$first.Data+$second.Data}
}
'@
        [IO.File]::WriteAllText($path,$code)
        $live=pump -AsObject -Record -ContractPath $path $Pwsh composed
        $live.Outcome|Should -Be Success;$live.Data.Total|Should -Be 42;$live.Execution.Steps|Should -Be 2
        $replayed=Invoke-QuietRecord -Id $live.RecordId -ContractPath $path -AsObject
        $replayed.Outcome|Should -Be Success;$replayed.Data.Total|Should -Be 42;$replayed.Execution.Steps|Should -Be 2
    }
    It 'reports a real Git merge conflict' {
        $p=Repo conflict -Commit;Git $p @('checkout','-qb','other')
        [IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'other');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','other')
        Git $p @('checkout','-q','main');[IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'main');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','main')
        $merge=Invoke-QuietCli -FilePath git -WorkingDirectory $p -ArgumentList @('merge','other') -SuccessExitCodes @(0,1) -Parse {param($c) @{Code=$c.ExitCode}}
        $merge.Data.Code|Should -Be 1
        $r=Status $p;$r.Data.Counts.Conflicted|Should -Be 1;$r.Data.Clean|Should -BeFalse
    }
    It 'reports divergence against local upstream refs without fetching' {
        $p=Repo upstream -Commit;Git $p @('branch','reference');Git $p @('branch','--set-upstream-to=reference','main')
        [IO.File]::WriteAllText((Join-Path $p 'tracked.txt'),'next');Git $p @('add','tracked.txt');Git $p @('-c','commit.gpgsign=false','commit','-qm','next')
        $r=Status $p;$r.Data.Upstream|Should -Be reference;$r.Data.Ahead|Should -Be 1;$r.Data.Behind|Should -Be 0
    }
    It 'migrates a V1 database and keeps estimator totals separate from exact profiles' {
        $previous=$env:QUIETCLI_DB_PATH;$env:QUIETCLI_DB_PATH=Join-Path $TestDrive 'legacy.sqlite3'
        try{
            $db=[QuietCliStack.GainV2.Database]::new($env:QUIETCLI_DB_PATH,$true)
            $db.Execute('DROP TABLE quietcli_v2_events',[object[]]@());$db.Execute('PRAGMA user_version=1',[object[]]@())
            $db.Execute('INSERT INTO quietcli_deliveries VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[object[]]@('old',[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(),'legacy','Success',1,1,1,0,400,40,100,10,90,5));$db.Dispose()
            $r=Native '"new exact output"' @{Parse={param($c) $c.Stdout}};$null=$r|ConvertTo-QuietJson
            $gain=QuietCliGain -View Object
            $gain.Totals.Deliveries|Should -Be 2;$gain.Methods.Count|Should -Be 2
            $gain.Totals.SavedTokens|Should -BeNullOrEmpty
            @($gain.Methods|Where-Object Label -Match estimate)[0].Totals.SavedTokens|Should -Be 90
        }finally{$env:QUIETCLI_DB_PATH=$previous}
    }
    It 'keeps literal native argv values including spaces and shell-looking text' {
        $r=Invoke-QuietCli -FilePath $Pwsh -ArgumentList @('-NoProfile','-CommandWithArgs','[Console]::Write(($args|ConvertTo-Json -Compress))','a space','--literal','$(not executed)') -Parse {param($c) ,@($c.Stdout|ConvertFrom-Json)}
        $r.Outcome|Should -Be Success
        $r.Data[0]|Should -Be 'a space';$r.Data[1]|Should -Be '--literal';$r.Data[2]|Should -Be '$(not executed)'
    }
    It 'keeps masked JSON captures parseable on replay' {
        $r=Native '[Console]::Write(''{"token":"unshared-secret","count":2}'')' @{Parse={param($c) $c.Stdout|ConvertFrom-Json};Record=$true}
        $contract=New-QuietContract -Id json -FilePath $Pwsh -Parse {param($c) $c.Stdout|ConvertFrom-Json}
        $replayed=Invoke-QuietRecord -Id $r.RecordId -Contract $contract -AsObject
        $replayed.Outcome|Should -Be Success;$replayed.Data.count|Should -Be 2
        $replayed.Data.token|Should -Be '[REDACTED]'
    }
}

Describe 'Packaging boundaries and presentation' {
    It 'preserves a literal separator and pathspec through pump' {
        $p=Repo pathspec;[IO.File]::WriteAllText((Join-Path $p 'one file.txt'),'one');[IO.File]::WriteAllText((Join-Path $p 'other.txt'),'two')
        $r=pump -AsObject -ContractPath $GitContract -WorkingDirectory $p -- git status -- 'one file.txt'
        $r.Outcome|Should -Be Success;$r.Data.Counts.Untracked|Should -Be 1;$r.Data.Entries[0].Path|Should -Be 'one file.txt'
    }
    It 'keeps late failure diagnostics after the capture file fills' {
        $r=Native '1..100|ForEach-Object {[Console]::WriteLine("long output $_")};[Console]::Error.WriteLine("late diagnostic");exit 9' @{MaxCaptureBytes=64;OnOutput={param($r,$s)}}
        $r.Outcome|Should -Be Failed
        $d=$r|ConvertTo-QuietJson|ConvertFrom-Json
        ($d.Excerpt.stderr -join ' ')|Should -Match 'late diagnostic'
        $r.Completeness.Capture|Should -BeFalse
    }
    It 'preserves declared relative source dependencies in the generated tree' {
        $codeRoot=Join-Path $TestDrive 'source-tree';[void][IO.Directory]::CreateDirectory((Join-Path $codeRoot 'factory'));[void][IO.Directory]::CreateDirectory((Join-Path $codeRoot 'lib'))
        $helper=Join-Path $codeRoot 'lib/Value.ps1'
        [IO.File]::WriteAllText($helper,'function Read-BusinessValue { param($c) @{Number=[int]$c.Stdout;Unit="items"} }')
        $factory=Join-Path $codeRoot 'factory/Count.ps1'
        $content=@'
param($Invocation)
$helper=Join-Path $PSScriptRoot '../lib/Value.ps1'
. $helper
$reader=Get-Command Read-BusinessValue -CommandType Function
$parse={param($c) & $reader $c}.GetNewClosure()
New-QuietContract -Id count -FilePath $Invocation.FilePath -ArgumentList @('-NoProfile','-Command','[Console]::Write(42)') -Parse $parse -SourcePath @($PSCommandPath,$helper) -Documentation @('fixture:42 independent items')
'@
        [IO.File]::WriteAllText($factory,$content)
        $r=pump -AsObject -Record -ContractPath $factory $Pwsh count
        $r.Outcome|Should -Be Success;$r.Data.Number|Should -Be 42
        $assert=Join-Path $TestDrive 'Count.Assertions.ps1'
        [IO.File]::WriteAllText($assert,'param($Cases) if($Cases[0].Actual.Data.Number -ne 42 -or $Cases[0].Actual.Data.Unit -ne "items"){throw "Expected 42 items from the fixture."}')
        $module=New-QuietModule -Command pwsh -ContractPath $factory -RecordId $r.RecordId -AssertionPath $assert -SourceRoot $codeRoot -OutputPath (Join-Path $TestDrive 'tree-module')
        Test-Path (Join-Path (Split-Path $module.Path) 'contracts/lib/Value.ps1')|Should -BeTrue
        $check=Test-QuietModule -Path $module.Path -AsObject
        $check.Outcome|Should -Be Success -Because ($check.Data.Failures -join ';')
    }
    It 'reports unknown tokens and known bytes separately when counting is off' {
        $previous=$env:QUIETCLI_DB_PATH;$counter=$env:QUIETCLI_TOKENIZER
        try{
            $env:QUIETCLI_DB_PATH=Join-Path $TestDrive 'bytes-only.sqlite3';$env:QUIETCLI_TOKENIZER='off'
            $r=Native '"known bytes"' @{Parse={param($c) $c.Stdout}};$null=$r|ConvertTo-QuietJson
            $report=QuietCliGain -View Object
            $report.Totals.InputBytes|Should -BeGreaterThan 0
            $report.Totals.SavedTokens|Should -BeNullOrEmpty
            $report.Totals.ByteMeasuredDeliveries|Should -Be 1
        }finally{$env:QUIETCLI_DB_PATH=$previous;$env:QUIETCLI_TOKENIZER=$counter}
    }
}

Describe 'Agent hook decisions' {
    It 'detects an unpumped command in a mixed invocation' {
        $eventInput=@{tool_name='PowerShell';tool_input=@{command='pump git status; git log -1'}}
        $decision=Invoke-QuietHook -Event $eventInput -Awareness deny
        $decision.hookSpecificOutput.permissionDecision|Should -Be deny
    }
    It 'asks approval for a self-contained rewrite without invoking the factory' {
        Register-QuietCommand -Command fixturehook -ModuleId hook-fixture -Factory {throw 'The hook must not execute the contract factory.'}
        $decision=Invoke-QuietHook -Event @{tool_name='Bash';tool_input=@{command='fixturehook status'}} -Awareness rewrite
        $decision.hookSpecificOutput.permissionDecision|Should -Be ask
        $line=$decision.hookSpecificOutput.updatedInput.command
        $line|Should -Match '^pwsh -NoProfile -EncodedCommand '
        $encoded=($line -split ' ')[-1]
        $body=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $body|Should -Match 'Import-Module'
        $body|Should -Match 'quiet -- fixturehook status'
    }
}

Describe 'YAML semantic verification' {
    It 'round trips empty maps arrays Unicode and nested objects through an independent parser' {
        Import-Module powershell-yaml -ErrorAction Stop
        $r=New-QuietResult -Data @{EmptyMap=@{};EmptyArray=@();Nested=@(@{},@{Name="été";Values=@(1,2)});Unknown=$null}
        $yaml=$r|Out-QuietResult -AsYaml
        $parsed=ConvertFrom-Yaml $yaml
        $parsed.SchemaVersion|Should -Be 2
        $parsed.Data.EmptyMap.Count|Should -Be 0
        @($parsed.Data.EmptyArray).Count|Should -Be 0
        $parsed.Data.Nested[1].Name|Should -Be 'été'
        @($parsed.Data.Nested[1].Values).Count|Should -Be 2
        $parsed.Data.Unknown|Should -BeNullOrEmpty
    }
}

Describe 'Factory construction boundaries' {
    It 'does not treat a declined candidate as a failed execution of the enclosing task' {
        Register-QuietCommand -Command fixturecandidate -ModuleId factory-test -Factory {
            $declined=New-QuietResult -Outcome Unsupported
            New-QuietContract -Id selected -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','[Console]::Write(42)') -Parse {param($c) [int]$c.Stdout}
        }
        $r=Invoke-QuietTask {$selected=pump -AsObject fixturecandidate run;@{Answer=$selected.Data}}
        $r.Outcome|Should -Be Success;$r.Data.Answer|Should -Be 42;$r.Execution.Steps|Should -Be 1
    }
    It 'keeps native launches out of contract selection' {
        Register-QuietCommand -Command fixtureselection -ModuleId factory-test -Factory {
            Invoke-QuietCli -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','throw "must not launch"') -Parse {param($c) $c.Stdout}
        }
        $r=pump -AsObject fixtureselection run
        $r.Outcome|Should -Be Failed
        $r.Error.Message|Should -Match 'Factories construct contracts'
    }
}

Describe 'Quiet command and output callback public interfaces' {
    It 'exports both public functions and exposes only the new streaming parameter' {
        foreach($name in @('quiet','pump')){
            (Get-Command $name -Module FrenchExDev.QuietCli.PoSh).CommandType|Should -Be Function
        }
        foreach($name in @('Invoke-QuietCli','New-QuietContract')){
            $command=Get-Command $name -Module FrenchExDev.QuietCli.PoSh
            $command.Parameters.ContainsKey('OnOutput')|Should -BeTrue
            $command.Parameters.ContainsKey('OnRecord')|Should -BeFalse
            @($command.Parameters.Values|Where-Object {$_.Aliases -contains 'OnRecord'}).Count|Should -Be 0
        }
        $contract=New-QuietContract -Id output.fixture -FilePath $Pwsh -OnOutput {param($output,$state)}
        $contract.OnOutput|Should -BeOfType scriptblock
        $contract.PSObject.Properties['OnRecord']|Should -BeNullOrEmpty
    }
    It 'passes flags colon values spaces empty values and native array splatting identically' {
        $child=Join-Path $TestDrive 'arguments.ps1'
        [IO.File]::WriteAllText($child,'[pscustomobject]@{Arguments=@($args)}|ConvertTo-Json -Compress')
        $tail=@('-c','-v','-o','-name:value','a file with spaces','','--','-path')
        $expected=@('-NoProfile','-File',$child)+$tail
        $a=quiet -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} -- $Pwsh -NoProfile -File $child @tail
        $b=pump -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} -- $Pwsh -NoProfile -File $child @tail
        foreach($result in @($a,$b)){
            $result.Outcome|Should -Be Success
            $source=@($result.Internal.Sources.Values)[0]
            $source.Request.ArgumentList|Should -Be $expected
        }
        $a.Data.Arguments|Should -Be $b.Data.Arguments
    }
    It 'handles literal native separators through both module-qualified functions' {
        $child=Join-Path $TestDrive 'qualified-arguments.ps1'
        [IO.File]::WriteAllText($child,'[pscustomobject]@{Arguments=@($args)}|ConvertTo-Json -Compress')
        $a=FrenchExDev.QuietCli.PoSh\quiet -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} -- $Pwsh -NoProfile -File $child -- -literal
        $b=FrenchExDev.QuietCli.PoSh\pump -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} -- $Pwsh -NoProfile -File $child -- -literal
        $expected=@('-NoProfile','-File',$child,'--','-literal')
        foreach($result in @($a,$b)){
            $result.Outcome|Should -Be Success
            (@($result.Internal.Sources.Values)[0]).Request.ArgumentList|Should -Be $expected
        }
    }
    It 'rejects a removed native separator before execution for all public spellings' {
        $marker=Join-Path $TestDrive 'separator-must-not-run'
        $child=Join-Path $TestDrive 'separator-child.ps1'
        [IO.File]::WriteAllText($child,("[IO.File]::WriteAllText('"+$marker+"','started')"))
        foreach($name in @('quiet','pump','FrenchExDev.QuietCli.PoSh\quiet','FrenchExDev.QuietCli.PoSh\pump')){
            $call=[scriptblock]::Create($name+' -AsObject -OnOutput {} $Pwsh -NoProfile -File $child -- -literal')
            {& $call}|Should -Throw '*PowerShell removed*'
        }
        Test-Path $marker|Should -BeFalse
    }
    It 'delivers stdout stderr and the same caller state to the output callback' {
        $state=@{Identity='caller-state';Items=[Collections.Generic.List[object]]::new()}
        $code='[Console]::WriteLine("business");[Console]::Error.WriteLine("diagnostic")'
        $r=quiet -AsObject -State $state -OnOutput {
            param($output,$state)
            $state.Items.Add([pscustomobject]@{Stream=$output.Stream;Text=$output.Text})
        } -Complete {param($state,$capture) @{Identity=$state.Identity;Items=$state.Items.ToArray();Drained=$capture.SourceComplete}} $Pwsh -NoProfile -Command $code
        $r.Outcome|Should -Be Success
        $r.Data.Identity|Should -BeExactly 'caller-state'
        $r.Data.Drained|Should -BeTrue
        @($r.Data.Items|Where-Object {$_.Stream -eq 'stdout' -and $_.Text -eq 'business'}).Count|Should -Be 1
        @($r.Data.Items|Where-Object {$_.Stream -eq 'stderr' -and $_.Text -eq 'diagnostic'}).Count|Should -Be 1
        $state.Items.Count|Should -Be 2
    }
    It 'rejects the retired parameter without starting a native process' {
        $marker=Join-Path $TestDrive 'retired-must-not-run'
        $code="[IO.File]::WriteAllText('"+$marker+"','started')"
        {Invoke-QuietCli -FilePath $Pwsh -ArgumentList @('-NoProfile','-Command',$code) -Parse {} -OnRecord {}}|Should -Throw '*OnRecord*'
        {New-QuietContract -Id retired -FilePath $Pwsh -Parse {} -OnRecord {}}|Should -Throw '*OnRecord*'
        {quiet -AsObject -OnRecord {} $Pwsh -NoProfile -Command $code}|Should -Throw '*OnRecord*'
        {pump -AsObject -OnRecord {} $Pwsh -NoProfile -Command $code}|Should -Throw '*OnRecord*'
        Test-Path $marker|Should -BeFalse
    }
    It 'preserves callback failure diagnostics and drains both streams through quiet' {
        $code='1..20|ForEach-Object{[Console]::WriteLine($_);[Console]::Error.WriteLine($_)}'
        $r=quiet -AsObject -OnOutput {param($output,$state) throw 'output callback failed'} -Complete {param($state,$capture) @{Drained=$capture.SourceComplete}} $Pwsh -NoProfile -Command $code
        $r.Outcome|Should -Be Failed
        $r.Error.Code|Should -Be ParserFailed
        $r.Completeness.Source|Should -BeTrue
        $r.Completeness.Analysis|Should -BeFalse
        $r.Data.Drained|Should -BeTrue
    }
    It 'preserves quiet timeouts and pre-start cancellation' {
        $r=quiet -AsObject -TimeoutSeconds 1 -OnOutput {} $Pwsh -NoProfile -Command 'Start-Sleep -Seconds 5'
        $r.Outcome|Should -Be Timeout
        $signal=[Threading.CancellationTokenSource]::new()
        $signal.Cancel()
        try {
            $marker=Join-Path $TestDrive 'cancelled-quiet-must-not-run'
            $code="[IO.File]::WriteAllText('"+$marker+"','started')"
            $r=quiet -AsObject -CancellationToken $signal.Token -OnOutput {} $Pwsh -NoProfile -Command $code
            $r.Outcome|Should -Be Cancelled
            Test-Path $marker|Should -BeFalse
        }finally{$signal.Dispose()}
    }
}
Describe 'Output callback replay and agent recognition' {
    It 'replays a source-declared output contract without relaunching its native producer' {
        $marker=Join-Path $TestDrive 'streaming-launches.txt'
        $factory=Join-Path $TestDrive 'Streaming.Output.ps1'
        $factoryLines=@(
            'param($Invocation)'
            '$state=@{Items=[Collections.Generic.List[object]]::new()}'
            'New-QuietContract -Id streaming.output -FilePath $Invocation.FilePath -ArgumentList $Invocation.ArgumentList -State $state -OnOutput {param($output,$state) $state.Items.Add([pscustomobject]@{Stream=$output.Stream;Text=$output.Text})} -Complete {param($state,$capture) @{Frames=$state.Items.ToArray()}} -SourcePath @($PSCommandPath) -Documentation @("fixture: one stdout line, one stderr line, producer launch marker")'
        )
        [IO.File]::WriteAllText($factory,($factoryLines -join [Environment]::NewLine))
        $code="[IO.File]::AppendAllText('"+$marker+"','launch'+[char]10);[Console]::WriteLine('saved-out');[Console]::Error.WriteLine('saved-err')"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $recorded=quiet -AsObject -Record -ContractPath $factory $Pwsh -NoProfile -EncodedCommand $encoded
        $recorded.Outcome|Should -Be Success
        $replayed=Invoke-QuietRecord -Id $recorded.RecordId -ContractPath $factory -AsObject
        $replayed.Outcome|Should -Be Success
        $replayed.Execution.Replay|Should -BeTrue
        @($replayed.Data.Frames).Count|Should -Be 2
        ($replayed.Data.Frames|ConvertTo-Json -Compress)|Should -BeExactly ($recorded.Data.Frames|ConvertTo-Json -Compress)
        @([IO.File]::ReadAllLines($marker)).Count|Should -Be 1
    }
    It 'recognizes both entry points in hook decisions and measured adoption' {
        foreach($line in @('quiet git status','pump git status','FrenchExDev.QuietCli.PoSh\quiet git status','FrenchExDev.QuietCli.PoSh\pump git status')){
            (Invoke-QuietHook -Event @{tool_input=@{command=$line}} -Awareness deny).Count|Should -Be 0
        }
        $transcript=Join-Path $TestDrive 'entrypoint-session.jsonl'
        $lines=@(foreach($line in @('quiet git status','pump git status','FrenchExDev.QuietCli.PoSh\quiet git status','git status')){
            @{input=@{command=$line}}|ConvertTo-Json -Compress
        })
        [IO.File]::WriteAllLines($transcript,[string[]]$lines)
        $audit=Get-QuietSession -Path $transcript -AsObject
        $audit.Data[0].Calls|Should -Be 4
        $audit.Data[0].Pumped|Should -Be 3
        $audit.Data[0].UnpumpedOrUnknown|Should -Be 1
    }
}
Describe 'Graphical gain HTML' {
    BeforeAll {
        function Add-GainHtmlSample {
            param([hashtable]$Values=@{})
            $row=@{Id=[Guid]::NewGuid().ToString('N');TimestampUtc=[DateTimeOffset]::UtcNow.ToString('o')
                Command='sample';Outcome='Success';NativeCalls=1;Measured=$true;ByteMeasured=$true
                Method='exact';Profile='o200k_base';Version='fixture/1';InputTokens=1000;OutputTokens=200;SavedTokens=800
                InputBytes=4000;OutputBytes=800;AnalysisComplete=$true;Truncated=$false;Fingerprint=$null}
            foreach($key in $Values.Keys){$row[$key]=$Values[$key]}
            & (Get-Module -All QuietCli) {param($row) Save-QuietEvent $row.Id delivery $row.Command $row} $row
        }
        function Read-GainHtmlSvg {
            param([string]$Html)
            foreach($match in [regex]::Matches($Html,'(?s)<svg\b.*?</svg>')){[xml]$match.Value}
        }
    }
    BeforeEach {
        $script:PreviousHtmlDatabase=$env:QUIETCLI_DB_PATH
        $env:QUIETCLI_DB_PATH=Join-Path $TestDrive ("html-"+[Guid]::NewGuid().ToString('N')+'.sqlite3')
        $script:HtmlPath=Join-Path $TestDrive 'gain.html'
    }
    AfterEach {$env:QUIETCLI_DB_PATH=$script:PreviousHtmlDatabase}
    It 'renders measured token bars to scale and marks increased output' {
        Add-GainHtmlSample @{Command='a'}
        Add-GainHtmlSample @{Command='b';InputTokens=100;OutputTokens=250;SavedTokens=-150}
        $path=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -GroupBy Command -View Html -OutputPath $HtmlPath
        $path|Should -Be $HtmlPath
        $html=[IO.File]::ReadAllText($path)
        $charts=@(Read-GainHtmlSvg $html)
        $charts.Count|Should -Be 1
        $bars=$charts[0].SelectNodes('//*[local-name()="rect"]')
        $bars.Count|Should -Be 4
        $bars[0].GetAttribute('data-value')|Should -Be '1000'
        $bars[0].height|Should -Be '200'
        $bars[1].height|Should -Be '40'
        $bars[2].height|Should -Be '20'
        $bars[3].height|Should -Be '50'
        $bars[3].class|Should -Be 'loss'
        $html|Should -Match "class='value positive'>650</span>"
        $html|Should -Not -Match '<script\b|<link\b|<canvas\b'
        $html|Should -Match 'aria-labelledby='
    }
    It 'keeps historical estimates and different token profiles in separate charts' {
        Add-GainHtmlSample
        Add-GainHtmlSample @{Method='estimate';Profile='utf8-bytes/4';Version='1';InputTokens=400;OutputTokens=40;SavedTokens=360}
        Add-GainHtmlSample @{Profile='cl100k_base';InputTokens=300;OutputTokens=30;SavedTokens=270}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $charts=@(Read-GainHtmlSvg $html)
        $charts.Count|Should -Be 3
        foreach($chart in $charts){$chart.SelectNodes('//*[local-name()="rect"]').Count|Should -Be 2}
        $html|Should -Match "data-profile='estimate, utf8-bytes/4, 1'"
        $html|Should -Match "data-profile='exact, o200k_base, fixture/1'"
        $html|Should -Match "data-profile='exact, cl100k_base, fixture/1'"
        (QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Object).Totals.SavedTokens|Should -BeNullOrEmpty
    }
    It 'uses measured bytes when token counting is unavailable' {
        Add-GainHtmlSample @{Measured=$false;InputTokens=$null;OutputTokens=$null;SavedTokens=$null;InputBytes=400;OutputBytes=100}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $html|Should -Match 'Token counts are unavailable'
        $chart=@(Read-GainHtmlSvg $html)[0]
        $chart.SelectSingleNode('//*[local-name()="title"]').InnerText|Should -Be 'Input and delivered bytes by Day'
        $bars=$chart.SelectNodes('//*[local-name()="rect"]')
        $bars[0].GetAttribute('data-value')|Should -Be '400'
        $bars[1].GetAttribute('data-value')|Should -Be '100'
        $html|Should -Match "class='value positive'>300</span>"
    }
    It 'explains empty and unknown measurements without drawing invented zero bars' {
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $html|Should -Match 'No measurements in this period'
        @(Read-GainHtmlSvg $html).Count|Should -Be 0
        Add-GainHtmlSample @{Measured=$false;ByteMeasured=$false;InputTokens=$null;OutputTokens=$null;SavedTokens=$null}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $html|Should -Match 'No comparable measurements in the selected groups'
        $html|Should -Match '<td>Unavailable</td>'
        @(Read-GainHtmlSvg $html).Count|Should -Be 0
    }
    It 'escapes command labels in the HTML and SVG' {
        Add-GainHtmlSample @{Command='<img src=x onerror="alert(1)"> & quoted'}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -GroupBy Command -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $html|Should -Not -Match '<img\b'
        $html|Should -Match '&lt;img'
        $chart=@(Read-GainHtmlSvg $html)[0]
        $chart.SelectSingleNode('//*[local-name()="rect"]/*[local-name()="title"]').InnerText|Should -Match '<img src=x'
    }
    It 'makes omitted chart groups explicit while retaining the full period totals' {
        Add-GainHtmlSample @{Command='a'}
        Add-GainHtmlSample @{Command='b';InputTokens=500;OutputTokens=100;SavedTokens=400}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -GroupBy Command -MaxItems 1 -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $html|Should -Match '1 of 2 groups are omitted by MaxItems'
        $chart=@(Read-GainHtmlSvg $html)[0]
        $chart.SelectNodes('//*[local-name()="rect"]').Count|Should -Be 2
        $raw=[Net.WebUtility]::HtmlDecode([regex]::Match($html,'(?s)<pre>(.*?)</pre>').Groups[1].Value)|ConvertFrom-Json
        $raw.Totals.Deliveries|Should -Be 2
        $raw.Totals.InputTokens|Should -Be 1500
        $raw.Groups.Count|Should -Be 1
        $raw.OmittedGroups|Should -Be 1
    }
    It 'draws genuine zero measurements without invalid SVG coordinates' {
        Add-GainHtmlSample @{InputTokens=0;OutputTokens=0;SavedTokens=0}
        $null=QuietCliGain -From ([DateTimeOffset]::UtcNow.AddDays(-30)) -To ([DateTimeOffset]::UtcNow.AddMinutes(1)) -View Html -OutputPath $HtmlPath
        $html=[IO.File]::ReadAllText($HtmlPath)
        $chart=@(Read-GainHtmlSvg $html)[0]
        foreach($bar in $chart.SelectNodes('//*[local-name()="rect"]')){
            $bar.height|Should -Be '0'
            $bar.GetAttribute('data-value')|Should -Be '0'
        }
        $html|Should -Not -Match 'NaN|Infinity'
    }
}

Describe 'Canonical module distribution' {
    It 'keeps consumer sources separate and validates the runtime inventory without making a ZIP' {
        Test-Path (Join-Path $QuietRoot 'modules')|Should -BeFalse
        Test-Path (Join-Path $QuietRoot 'downloads')|Should -BeFalse
        $report=& (Join-Path $QuietRoot 'scripts/New-QuietCliArchive.ps1') -ValidateOnly|ConvertFrom-Json
        $report.Outcome|Should -Be Success
        $report.Data.Mode|Should -Be InventoryOnly
        @($report.Data.Manifest.Files|Where-Object {$_.Path -match '^modules/|^downloads/'}).Count|Should -Be 0
    }
    It 'refuses local release ZIP creation before writing an archive' {
        $old=$env:GITHUB_ACTIONS
        try{
            $env:GITHUB_ACTIONS='false'
            $destination=Join-Path $TestDrive 'blocked-distribution'
            {& (Join-Path $QuietRoot 'scripts/New-QuietCliArchive.ps1') -OutputDirectory $destination}|Should -Throw '*GitHub Actions*'
            Test-Path $destination|Should -BeFalse
        }finally{$env:GITHUB_ACTIONS=$old}
    }
}