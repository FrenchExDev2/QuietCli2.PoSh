#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([string]$Python='python3', [switch]$RuntimeOnly, [string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$moduleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1') -ErrorAction Stop
$pwsh=(Get-Process -Id $PID).Path

function Invoke-TestSuite {
    param([string]$Executable,[string[]]$Arguments,[string]$Name)
    try {
    $native=Invoke-QuietCli -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $moduleRoot `
        -SuccessExitCodes @(0,1,2) -TimeoutSeconds 180 -MaxOutputBytes 16384 `
        -Summary $Name -Parse {param($capture) ConvertFrom-Json $capture.Stdout -ErrorAction Stop}
    if ($native.Outcome -ne 'Success') { return $native }
    $report=$native.Data
    $payload=if ($report.PSObject.Properties['SchemaVersion']) { $report.Data } else { $report }
    $errorInfo=if ($report.PSObject.Properties['Error']) { $report.Error } else { $null }
    # A child test report owns its outcome; exit codes 1 and 2 are parsed, never treated as passing tests.
    New-QuietResult -Summary $Name -Outcome $report.Outcome -Data $payload -ErrorInfo $errorInfo `
        -Execution @{ExitCode=$native.Execution.ExitCode;AnalysisComplete=($report.Outcome -eq 'Success')} -MaxOutputBytes 16384
    } catch {
        New-QuietResult -Summary "$Name could not produce a valid test report." -Outcome Failed `
            -ErrorInfo @{Code='TestRunnerFailed';Message=$_.Exception.Message} -Execution @{AnalysisComplete=$false}
    }
}

$result=Invoke-QuietTask -MaxOutputBytes 8192 {
    $suites=[Collections.Generic.List[object]]::new()
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Smoke.Tests.ps1'),'-Python',$Python)
    if ($RuntimeOnly) { $arguments+=@('-RuntimeOnly') }
    $smoke=Invoke-QuietStep smoke { Invoke-TestSuite -Executable $pwsh -Arguments $arguments -Name 'Smoke' }
    $suites.Add(@{Name='Smoke';Result=$smoke})
    if (!$RuntimeOnly -and $smoke.Outcome -eq 'Success') {
        $integration=Invoke-QuietStep integration {
            Invoke-TestSuite -Executable $Python -Arguments @((Join-Path $PSScriptRoot 'test_examples.py'),'--pwsh',$pwsh) -Name 'Integration'
        }
        $suites.Add(@{Name='Integration';Result=$integration})
    }
    $summaries=@(foreach ($suite in $suites) {
        $data=$suite.Result.Data
        $passed=0; $failed=0; $skipped=0; $checks=@()
        if ($null -ne $data) {
            if ($data.PSObject.Properties['Passed']) { $passed=$data.Passed }
            if ($data.PSObject.Properties['Failed']) { $failed=$data.Failed }
            if ($data.PSObject.Properties['Skipped']) { $skipped=$data.Skipped }
            if ($data.PSObject.Properties['Checks']) { $checks=@($data.Checks) }
        }
        [pscustomobject]@{Name=$suite.Name;Outcome=$suite.Result.Outcome;Passed=$passed;Failed=$failed;Skipped=$skipped;Error=$suite.Result.Error
            Details=@($checks | Where-Object { ($_.PSObject.Properties['Passed'] -and !$_.Passed) -or $_.PSObject.Properties['Skipped'] })}
    })
    $hashes=[ordered]@{}
    foreach ($file in @('src/QuietCli.psm1','src/NativeSession.cs','test/Smoke.Tests.ps1','test/test_examples.py','test/Invoke-Tests.ps1','examples/Generated-GitOverview.ps1')) {
        $hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $moduleRoot $file) -Algorithm SHA256).Hash
    }
    [pscustomobject]@{Platform=[Environment]::OSVersion.Platform.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()
        OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        DotNet=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        PythonVersion=$(if ($smoke.Data -and $smoke.Data.PSObject.Properties['PythonVersion']) {$smoke.Data.PythonVersion} else {$null})
        ExecutedAtUtc=[DateTime]::UtcNow.ToString('o');SourceSHA256=[pscustomobject]$hashes
        RuntimeOnly=[bool]$RuntimeOnly;Suites=$summaries}
}
$json=ConvertTo-QuietJson $result -MaxOutputBytes 8192
if ($OutputPath) {
    $target=[IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::WriteAllText($target,$json,[Text.UTF8Encoding]::new($false))
}
$json
if ($result.Outcome -eq 'Unsupported') { exit 2 }
if ($result.Outcome -ne 'Success') { exit 1 }
