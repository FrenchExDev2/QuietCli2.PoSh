#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,
      [string]$QuietCliRoot=(Join-Path $PSScriptRoot '..'),
      [ValidateRange(1024,65536)][int]$MaxOutputBytes=2048)
$ErrorActionPreference='Stop'
$QuietCliRoot=[IO.Path]::GetFullPath($QuietCliRoot)
Import-Module (Join-Path $QuietCliRoot 'FrenchExDev.QuietCli.PoSh.psd1') -ErrorAction Stop
$repo=[IO.Path]::GetFullPath($Repository)
# Reuse the supplied companion in a separate process. The outer task consumes its
# envelope as data, checks it, and records it as a step before using its fields.
$engine=(Get-Process -Id $PID).Path
$companion=Join-Path $QuietCliRoot 'examples/Generated-GitOverview.ps1'
Invoke-QuietTask -MaxOutputBytes $MaxOutputBytes -AsJson -ArgumentList @($repo,$engine,$companion) -ScriptBlock {
    param($repo,$engine,$companion)
    $capture=Invoke-QuietStep -Name 'execute-reused-companion' -ScriptBlock {
        Invoke-QuietCli -FilePath $engine -ArgumentList @('-NoLogo','-NoProfile','-File',$companion,'-Repository',$repo) `
            -WorkingDirectory $repo -TimeoutSeconds 60 -Parse {
                param($capture)
                ConvertFrom-Json -InputObject $capture.Stdout -ErrorAction Stop
            }
    }
    if ($capture.Outcome -ne 'Success') { return }
    $overview=Invoke-QuietStep -Name 'reused-domain-result' -ScriptBlock { $capture.Data }
    if ($overview.Outcome -ne 'Success' -or !$overview.Execution.AnalysisComplete -or !$overview.Data.AnswerComplete) { return }
    $head=Invoke-QuietStep -Name 'head' -ScriptBlock {
        Invoke-QuietCli -FilePath git -ArgumentList @('rev-parse','--verify','HEAD') -WorkingDirectory $repo -Parse {
            param($capture)
            if ($capture.ExitCode -ne 0) { return }
            $value=$capture.Stdout.Trim()
            if ($value -notmatch '^[0-9a-f]{40,64}$') { throw 'Unexpected Git object identifier.' }
            [pscustomobject]@{Commit=$value}
        }
    }
    if ($head.Outcome -ne 'Success') { return }
    [pscustomobject]@{
        Branch=$overview.Data.Branch;Head=$head.Data.Commit
        NeedsReview=(!$overview.Data.Clean);ChangedEntries=$overview.Data.Changed;UntrackedEntries=$overview.Data.Untracked
        Scope='Entire repository; Git --untracked-files=normal; two sequential observations, not an atomic snapshot'
        AnswerComplete=$true
    }
}
