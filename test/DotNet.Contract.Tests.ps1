#requires -Version 7.6
# Objectif : verifier que le contrat dotnet refuse les resultats ambigus ou hors scenario.
BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
    $script:DotNetFactory=Join-Path $root 'test/integration/contracts/DotNet.Serilog.ps1'
    $script:DotNetArguments=@('test','test/Serilog.Tests/Serilog.Tests.csproj','-c','Release','-f','net10.0','--tl:off')
}
Describe 'Documented dotnet integration contract' {
    It 'preserves independent successful, failed and skipped counts' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=$DotNetArguments;WorkingDirectory=$TestDrive}
        $text=@('Total tests: 7','Passed: 4','Failed: 2','Skipped: 1') -join [Environment]::NewLine
        $data=& $contract.Parse ([pscustomobject]@{Stdout=$text;Stderr=''})
        $data.Counts.Total|Should -Be 7
        $data.Counts.Passed|Should -Be 4
        $data.Counts.Failed|Should -Be 2
        $data.Counts.Skipped|Should -Be 1
    }
    It 'rejects an empty test run rather than certifying success' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=$DotNetArguments;WorkingDirectory=$TestDrive}
        { & $contract.Parse ([pscustomobject]@{Stdout='Total tests: 0';Stderr=''}) }|Should -Throw '*non-empty*'
    }
    It 'rejects inconsistent test counters' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=$DotNetArguments;WorkingDirectory=$TestDrive}
        $text=@('Total tests: 7','Passed: 6','Failed: 2') -join [Environment]::NewLine
        { & $contract.Parse ([pscustomobject]@{Stdout=$text;Stderr=''}) }|Should -Throw '*summary*'
    }
    It 'rejects output without a test summary' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=$DotNetArguments;WorkingDirectory=$TestDrive}
        { & $contract.Parse ([pscustomobject]@{Stdout='Build succeeded.';Stderr=''}) }|Should -Throw '*summary*'
    }
    It 'rejects a project outside its documented scope' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=@('test','other.csproj');WorkingDirectory=$TestDrive}
        $contract.Outcome|Should -BeExactly Unsupported
    }
    It 'rejects a target framework outside its documented scope' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=@('build','test/Serilog.Tests/Serilog.Tests.csproj','-c','Release','-f','net9.0','--tl:off');WorkingDirectory=$TestDrive}
        $contract.Outcome|Should -BeExactly Unsupported
    }
    It 'keeps the compiler error identity when the MSBuild summary repeats it' {
        $contract=& $DotNetFactory @{FilePath='dotnet';ArgumentList=@('build','test/Serilog.Tests/Serilog.Tests.csproj','-c','Release','-f','net10.0','--tl:off');WorkingDirectory=$TestDrive}
        $line='fixture.cs(1,8): error CS1029: #error: QUIETCLI_EXPECTED_BUILD_FAILURE'
        $data=& $contract.Parse ([pscustomobject]@{Stdout=($line+[Environment]::NewLine+$line);Stderr=''})
        $data.DiagnosticCount|Should -Be 1
        $data.Diagnostics[0].Code|Should -BeExactly CS1029
        $data.CompilerFailureMarker|Should -BeTrue
    }
}
