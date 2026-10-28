#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$moduleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-gain-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$oldPath=$env:QUIETCLI_DB_PATH; $oldTracking=$env:QUIETCLI_TRACKING
$env:QUIETCLI_DB_PATH=Join-Path $testRoot 'initial.sqlite3'; $env:QUIETCLI_TRACKING='1'
Import-Module (Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1') -ErrorAction Stop
$engine=(Get-Process -Id $PID).Path
$checks=[Collections.Generic.List[object]]::new()
function Assert([bool]$Condition,[string]$Message='Assertion failed') { if (!$Condition) { throw $Message } }
function Check([string]$Name,[scriptblock]$Body) {
    $env:QUIETCLI_DB_PATH=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.sqlite3')
    $env:QUIETCLI_TRACKING='1'
    try { & $Body; $checks.Add(@{Name=$Name;Passed=$true}) }
    catch { $checks.Add(@{Name=$Name;Passed=$false;Message=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber}) }
}
function Invoke-Fixture {
    param([string]$Code="[Console]::Out.Write(('x'*12000))",[switch]$Streaming,[int]$Timeout=10,[scriptblock]$Parse)
    $codePrefix='[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);'
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($codePrefix+$Code)))
    if ($Streaming) {
        Invoke-QuietCli -FilePath $engine -ArgumentList $arguments -TimeoutSeconds $Timeout -State @{Records=0} `
            -OnRecord {param($r,$s) $s.Records++} -Complete {param($s,$c) [pscustomobject]@{Records=$s.Records}}
    } else {
        if (!$Parse) { $Parse={param($c) [pscustomobject]@{Bytes=[Text.Encoding]::UTF8.GetByteCount($c.Stdout)}} }
        Invoke-QuietCli -FilePath $engine -ArgumentList $arguments -TimeoutSeconds $Timeout -Parse $Parse
    }
}
function Seed-Delivery($Database,[string]$Id,[DateTimeOffset]$Timestamp,[string]$Command,[long]$InputTokens,[long]$OutputTokens) {
    $Database.Execute(@'
INSERT INTO quietcli_deliveries
(id,timestamp_ms,command,outcome,native_calls,measured,analysis_complete,truncated,input_bytes,output_bytes,input_tokens,output_tokens,saved_tokens,elapsed_ms)
VALUES (?,?,?,'Success',1,1,1,0,?,?,?,?,?,1)
'@,[object[]]@($Id,$Timestamp.ToUnixTimeMilliseconds(),$Command,(4*$InputTokens),(4*$OutputTokens),$InputTokens,$OutputTokens,($InputTokens-$OutputTokens)))
}

try {
    Check 'Six public functions; empty history is readable without creating a database' {
        Assert (@(Get-Command -Module FrenchExDev.QuietCli.PoSh).Count -eq 6)
        $gain=QuietCliGain -View Object
        Assert ($gain.Totals.Deliveries -eq 0 -and $null -eq $gain.Totals.SavingsPercent)
        Assert (!(Test-Path -LiteralPath $env:QUIETCLI_DB_PATH))
        Assert ((QuietCliGain -View Text) -match 'No recorded deliveries')
    }
    Check 'UTF-8 counts include both streams and match RTK ceiling, including split surrogate pairs' {
        $native=Invoke-Fixture -Code "[Console]::Out.Write(('é😀'*5000));[Console]::Error.Write('err')"
        Assert ($native.Outcome -eq 'Success')
        Assert ($native.Data.Bytes -eq 30000) 'Fixture did not emit the expected Unicode bytes.'
        Assert ($native.Execution.StdoutBytes -eq 30000 -and $native.Execution.StderrBytes -eq 3) 'Unicode byte counter differs from a complete UTF-8 encoding.'
        Assert ((QuietCliGain -View Object).Totals.Deliveries -eq 0) 'An intermediate object was counted.'
        $json=ConvertTo-QuietJson $native
        $gain=QuietCliGain -View Object
        Assert ($gain.Totals.InputBytes -eq 30003 -and $gain.Totals.InputTokens -eq 7501)
        $expected=[long][Math]::Ceiling([Text.Encoding]::UTF8.GetByteCount($json)/4.0)
        Assert ($gain.Totals.OutputTokens -eq $expected -and $gain.Totals.SavedTokens -eq (7501-$expected))
        Assert (!$gain.LastTrackingError)
        $header=[IO.File]::ReadAllBytes($env:QUIETCLI_DB_PATH)
        Assert ([Text.Encoding]::ASCII.GetString($header,0,15) -eq 'SQLite format 3')
    }
    Check 'Repeated serialization counts the same result once and queries do not count themselves' {
        $native=Invoke-Fixture
        $first=ConvertTo-QuietJson $native -MaxOutputBytes 1024
        $second=ConvertTo-QuietJson $native -MaxOutputBytes 2048
        $one=QuietCliGain -View Object
        $two=QuietCliGain -View Json | ConvertFrom-Json
        Assert ($one.Totals.Deliveries -eq 1 -and $two.Totals.Deliveries -eq 1)
        Assert ($one.Totals.OutputBytes -eq [Text.Encoding]::UTF8.GetByteCount($first))
    }
    Check 'Nested tasks and assigned steps account for two native calls in one final delivery' {
        $json=Invoke-QuietTask -AsJson -MaxOutputBytes 1024 {
            $first=Invoke-QuietStep first {Invoke-Fixture -Code "[Console]::Out.Write(('a'*12000))"}
            $nested=Invoke-QuietTask -AsJson {
                $second=Invoke-QuietStep second {Invoke-Fixture -Code "[Console]::Out.Write(('b'*8000))"}
                [pscustomobject]@{Count=2}
            }
            [pscustomobject]@{Answer=2}
        }
        $gain=QuietCliGain -View Object
        Assert (($json|ConvertFrom-Json).Outcome -eq 'Success')
        Assert ($gain.Totals.Deliveries -eq 1 -and $gain.Totals.NativeCalls -eq 2)
        Assert ($gain.Totals.InputBytes -eq 20000 -and $gain.Totals.OutputBytes -eq [Text.Encoding]::UTF8.GetByteCount($json))
    }
    Check 'Previously delivered sources are not credited again by a new task' {
        $native=Invoke-Fixture
        $first=ConvertTo-QuietJson $native
        $before=QuietCliGain -View Object
        $taskJson=Invoke-QuietTask -AsJson {$step=Invoke-QuietStep reused {$native};[pscustomobject]@{Answer=1}}
        $after=QuietCliGain -View Object
        Assert ($after.Totals.Deliveries -eq 2 -and $after.Totals.UnmeasuredDeliveries -eq 1)
        Assert ($after.Totals.SavedTokens -eq $before.Totals.SavedTokens)
    }
    Check 'Streaming counts delimiters and all records without retaining the log' {
        $native=Invoke-Fixture -Code 'for($i=0;$i -lt 3000;$i++){[Console]::Out.Write("é😀`n")}' -Streaming
        Assert ($native.Outcome -eq 'Success' -and $native.Data.Records -eq 3000)
        Assert ($native.Execution.StdoutBytes -eq 21000)
        $json=ConvertTo-QuietJson $native
        Assert ((QuietCliGain -View Object).Totals.InputBytes -eq 21000)
    }
    Check 'Expansion is negative in objects, terminal charts and HTML' {
        $native=Invoke-Fixture -Code "[Console]::Out.Write('x')"
        $json=ConvertTo-QuietJson $native
        $gain=QuietCliGain -View Object
        Assert ($gain.Totals.InputTokens -eq 1 -and $gain.Totals.SavedTokens -lt 0)
        Assert ((QuietCliGain -View Chart) -match '\[-+\|')
        $htmlPath=QuietCliGain -View Html -OutputPath (Join-Path $testRoot 'negative.html')
        $html=Get-Content -LiteralPath $htmlPath -Raw
        Assert ($html -match '<svg' -and $html -match '#fb923c' -and $html -notmatch '<script')
    }
    Check 'The counter uses the final bounded JSON including an omitted projection' {
        $native=Invoke-Fixture -Parse {param($c) [pscustomobject]@{Large=('z'*6000)}}
        $json=ConvertTo-QuietJson $native -MaxOutputBytes 1024
        $decoded=$json|ConvertFrom-Json
        $gain=QuietCliGain -View Object
        Assert ($null -eq $decoded.Data -and $decoded.Truncation.Applied)
        Assert ($gain.Totals.OutputBytes -eq [Text.Encoding]::UTF8.GetByteCount($json) -and $gain.Totals.TruncatedDeliveries -eq 1)
    }
    Check 'Start failure and timeout are retained as unmeasured, not invented savings' {
        $missing=Invoke-QuietCli -FilePath '__quietcli_missing_gain_fixture__' -Parse {param($c) @{Never=$true}}
        $missingJson=ConvertTo-QuietJson $missing
        $timeout=Invoke-Fixture -Code "[Console]::Out.Write('partial');Start-Sleep -Seconds 5" -Timeout 1
        $timeoutJson=ConvertTo-QuietJson $timeout
        $gain=QuietCliGain -View Object
        Assert ($timeout.Outcome -eq 'Timeout')
        Assert ($gain.Totals.Deliveries -eq 2 -and $gain.Totals.UnmeasuredDeliveries -eq 2)
        Assert ($gain.Totals.SavedTokens -eq 0 -and $gain.Totals.FailedDeliveries -eq 2)
    }
    Check 'Parse failures preserve measured volume and failure counters' {
        $native=Invoke-Fixture -Parse {param($c) throw 'Unsupported format'}
        $json=ConvertTo-QuietJson $native
        $gain=QuietCliGain -View Object
        Assert ($native.Outcome -eq 'Failed')
        Assert ($gain.Totals.InputBytes -eq 12000 -and $gain.Totals.FailedDeliveries -eq 1 -and $gain.Totals.AnalysisIncompleteDeliveries -eq 1)
    }
    Check 'Tracking opt-out and runtime database path changes are respected immediately' {
        $env:QUIETCLI_TRACKING='0'
        $native=Invoke-Fixture; $json=ConvertTo-QuietJson $native
        Assert (!(Test-Path -LiteralPath $env:QUIETCLI_DB_PATH))
        Assert (!(QuietCliGain -View Object).TrackingEnabled)
        $env:QUIETCLI_TRACKING='1'
        $json=ConvertTo-QuietJson $native
        Assert ((QuietCliGain -View Object).Totals.Deliveries -eq 1)
        $env:QUIETCLI_DB_PATH=Join-Path $testRoot 'changed-path.sqlite3'
        $second=Invoke-Fixture; $json=ConvertTo-QuietJson $second
        Assert ((QuietCliGain -View Object).Totals.Deliveries -eq 1)
    }
    Check 'An unwritable database cannot change the business envelope and is observable' {
        $env:QUIETCLI_DB_PATH=$testRoot
        $native=Invoke-Fixture; $json=ConvertTo-QuietJson $native
        Assert (($json|ConvertFrom-Json).Outcome -eq 'Success')
        $report=QuietCliGain -View Object -DatabasePath (Join-Path $testRoot 'missing.sqlite3')
        Assert ([bool]$report.LastTrackingError)
        $failed=$false
        try { $ignored=QuietCliGain -View Object } catch {$failed=$true}
        Assert $failed 'An invalid database was silently reported as empty history.'
    }
    Check 'UTC boundaries, weighted totals, top groups and HTML escaping are correct' {
        $database=[QuietCliStack.GainV1.Database]::new($env:QUIETCLI_DB_PATH,$true)
        try {
            Seed-Delivery $database 'start' ([DateTimeOffset]'2026-01-01T00:00:00Z') 'tool<script>' 1000 100
            Seed-Delivery $database 'middle' ([DateTimeOffset]'2026-01-02T00:00:00Z') 'other' 100 200
            Seed-Delivery $database 'end' ([DateTimeOffset]'2026-01-03T00:00:00Z') 'excluded' 9000 1
        } finally {$database.Dispose()}
        $range=@{From=[DateTimeOffset]'2026-01-01T01:00:00+01:00';To=[DateTimeOffset]'2026-01-03T00:00:00Z'}
        $gain=QuietCliGain @range -View Object -MaxItems 1
        Assert ($gain.Totals.Deliveries -eq 2 -and $gain.Totals.SavedTokens -eq 800)
        Assert ($gain.Totals.SavingsPercent -eq 72.73 -and $gain.TotalGroups -eq 2 -and $gain.OmittedGroups -eq 1)
        Assert ($gain.Groups[0].Label -eq '2026-01-02') 'Day limit did not keep the latest group.'
        $byCommand=QuietCliGain @range -View Object -GroupBy Command
        Assert ($byCommand.Groups[0].Label -eq 'tool<script>')
        $htmlPath=QuietCliGain @range -View Html -GroupBy Command -OutputPath (Join-Path $testRoot 'safe.html')
        $html=Get-Content -LiteralPath $htmlPath -Raw
        Assert ($html -match 'tool&lt;script&gt;' -and $html -notmatch 'tool<script>')
    }
    Check 'Native child companions do not independently record the parent delivery' {
        $manifest=(Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1').Replace("'","''")
        $childCode="Import-Module '$manifest'; Invoke-QuietTask -AsJson {`$s=Invoke-QuietStep native {Invoke-QuietCli -FilePath '__missing__' -Parse {param(`$c) @{}}};@{Done=`$true}}"
        $native=Invoke-Fixture -Code $childCode -Parse {param($c) $c.Stdout|ConvertFrom-Json}
        Assert ((QuietCliGain -View Object).Totals.Deliveries -eq 0)
        $json=ConvertTo-QuietJson $native
        Assert ((QuietCliGain -View Object).Totals.Deliveries -eq 1)
    }
    Check 'History persists across a fresh PowerShell process and contains no arguments or raw output' {
        $native=Invoke-Fixture -Code "[Console]::Out.Write(('PRIVATE_SENTINEL'*1000))"
        $json=ConvertTo-QuietJson $native
        $manifest=(Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1').Replace("'","''")
        $fresh=Invoke-Fixture -Code "Import-Module '$manifest';QuietCliGain -View Json" -Parse {param($c) $c.Stdout|ConvertFrom-Json}
        Assert ($fresh.Outcome -eq 'Success' -and $fresh.Data.Totals.Deliveries -eq 1)
        $content=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($env:QUIETCLI_DB_PATH))
        Assert ($content -notmatch 'PRIVATE_SENTINEL|-EncodedCommand|StandardOutput')
    }
    Check 'Invalid periods and unsupported output combinations fail explicitly' {
        foreach($arguments in @(
            @{From='2026-02-02T00:00:00Z';To='2026-02-01T00:00:00Z'},
            @{View='Html'},
            @{View='Text';OutputPath='ignored.html'})) {
            $failed=$false
            try {$ignored=QuietCliGain @arguments} catch {$failed=$true}
            Assert $failed
        }
    }
    Check 'Browse opens only a saved HTML report, escapes its URI, and preserves the file on launch failure' {
        $gainModule=(Get-Command QuietCliGain).ScriptBlock.Module
        & $gainModule {
            $script:BrowserTest=@{Calls=[Collections.Generic.List[string]]::new();Fail=$false}
            function script:Start-Process {
                [CmdletBinding()]
                param([string]$FilePath)
                if (!(Test-Path -LiteralPath ([Uri]$FilePath).LocalPath)) { throw 'Browser launched before the report existed.' }
                $script:BrowserTest.Calls.Add($FilePath)
                if ($script:BrowserTest.Fail) { throw 'Browser unavailable in this test.' }
            }
        }
        try {
            $destination=Join-Path $testRoot 'gain é # report.html'
            $path=QuietCliGain -View Html -OutputPath $destination
            Assert ((& $gainModule {$script:BrowserTest.Calls.Count}) -eq 0) 'HTML opened without an explicit Browse switch.'
            $path=QuietCliGain -View Html -OutputPath $destination -Browse
            $calls=@(& $gainModule {$script:BrowserTest.Calls.ToArray()})
            Assert ($calls.Count -eq 1 -and $path -eq [IO.Path]::GetFullPath($destination))
            $uri=[Uri]$calls[0]
            Assert ($uri.IsFile -and $uri.LocalPath -eq $path -and $calls[0] -match '%23' -and $calls[0] -match '%20')
            foreach ($view in @('Text','Chart','Object','Json')) {
                $rejected=$false
                try {$ignored=QuietCliGain -View $view -Browse} catch {$rejected=$_.Exception.Message -match '-Browse'}
                Assert $rejected ('Browse was accepted with '+$view)
            }
            $rejected=$false
            try {$ignored=QuietCliGain -View Html -OutputPath $testRoot -Browse} catch {$rejected=$true}
            Assert ($rejected -and (& $gainModule {$script:BrowserTest.Calls.Count}) -eq 1) 'Browser launched after HTML generation failed.'
            & $gainModule {$script:BrowserTest.Fail=$true}
            $failure=$null
            try {$ignored=QuietCliGain -View Html -OutputPath $destination -Browse} catch {$failure=$_.Exception.Message}
            Assert ($failure -and $failure.Contains($path) -and (Test-Path -LiteralPath $path))
        } finally {
            & $gainModule {
                Remove-Item -LiteralPath 'Function:script:Start-Process' -Force
                Remove-Variable BrowserTest -Scope Script
            }
        }
    }
    Check 'An unrelated SQLite database is preserved rather than initialized as gain history' {
        $database=[QuietCliStack.GainV1.Database]::new($env:QUIETCLI_DB_PATH,$true)
        try {
            $database.Execute('DROP TABLE quietcli_deliveries',[object[]]@())
            $database.Execute('PRAGMA user_version=0',[object[]]@())
            $database.Execute('CREATE TABLE preserve_me(value TEXT)',[object[]]@())
            $database.Execute('INSERT INTO preserve_me VALUES (?)',[object[]]@('original'))
            $native=Invoke-Fixture; $json=ConvertTo-QuietJson $native
            Assert (($json|ConvertFrom-Json).Outcome -eq 'Success')
            Assert ($database.Query('PRAGMA user_version',[object[]]@())[0]['user_version'] -eq 0)
            Assert ($database.Query('SELECT value FROM preserve_me',[object[]]@())[0]['value'] -eq 'original')
        } finally {$database.Dispose()}
    }
    Check 'Concurrent writers initialize and update one real SQLite history without lost rows' {
        $manifest=Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1'
        $sharedPath=$env:QUIETCLI_DB_PATH
        $writerErrors=@(1..4 | ForEach-Object -Parallel {
            $ErrorActionPreference='Stop'
            $connection=$null
            try {
                Import-Module $using:manifest -ErrorAction Stop
                $connection=[QuietCliStack.GainV1.Database]::new($using:sharedPath,$true)
                $connection.Execute(@'
INSERT INTO quietcli_deliveries
(id,timestamp_ms,command,outcome,native_calls,measured,analysis_complete,truncated,input_bytes,output_bytes,input_tokens,output_tokens,saved_tokens,elapsed_ms)
VALUES (?,?,'concurrent','Success',1,1,1,0,4000,400,1000,100,900,1)
'@,[object[]]@([guid]::NewGuid().ToString('N'),[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
            } catch {$_.Exception.Message}
            finally {if($connection){$connection.Dispose()}}
        } -ThrottleLimit 4)
        Assert ($writerErrors.Count -eq 0) ($writerErrors -join '; ')
        $gain=QuietCliGain -View Object
        Assert ($gain.Totals.Deliveries -eq 4 -and $gain.Totals.SavedTokens -eq 3600)
    }
} finally {
    $env:QUIETCLI_DB_PATH=$oldPath; $env:QUIETCLI_TRACKING=$oldTracking
}
$failed=@($checks|Where-Object {!$_.Passed}).Count
$report=[pscustomobject]@{Outcome=$(if($failed){'Failed'}else{'Success'});Passed=($checks.Count-$failed);Failed=$failed;
    Checks=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();ExecutedAtUtc=[DateTime]::UtcNow.ToString('o')}
$json=ConvertTo-Json -InputObject $report -Depth 6 -Compress
if (!$failed) {
    $resolvedRoot=(Get-Item -LiteralPath $testRoot).FullName
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolvedRoot) -eq $tempParent -and
        [IO.Path]::GetFileName($resolvedRoot) -like 'quietcli-gain-tests-*' -and
        !((Get-Item -LiteralPath $resolvedRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.UTF8Encoding]::new($false))}
$json
if($failed){exit 1}
