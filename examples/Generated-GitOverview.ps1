#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,
      [ValidateRange(1024,65536)][int]$MaxOutputBytes=2048)
Import-Module (Join-Path $PSScriptRoot '../FrenchExDev.QuietCli.PoSh.psd1') -ErrorAction Stop
$repositoryPath=[IO.Path]::GetFullPath($Repository)

Invoke-QuietTask -MaxOutputBytes $MaxOutputBytes -AsJson -ArgumentList @($repositoryPath) -ScriptBlock {
    param($repo)
    $branch=Invoke-QuietStep branch {
        Invoke-QuietCli -FilePath git -ArgumentList @('branch','--show-current') -WorkingDirectory $repo `
            -Summary 'Current branch extracted.' -Parse {
                param($capture)
                $name=$capture.Stdout.TrimEnd("`r","`n")
                [pscustomobject]@{Name=$(if ($name.Length) { $name } else { $null });Detached=($name.Length -eq 0)}
            }
    }
    if ($branch.Outcome -ne 'Success') { return }
    $state=@{Changed=0L;Untracked=0L;SkipRenameSource=$false}
    $status=Invoke-QuietStep status {
        Invoke-QuietCli -FilePath git -ArgumentList @('status','--porcelain=v1','-z','--untracked-files=normal') `
            -WorkingDirectory $repo -RecordDelimiter ([char]0) -State $state -Summary 'Git status counted locally.' `
            -OnRecord {
                param($record,$state)
                if ($record.Stream -ne 'stdout' -or $record.Truncated) { return }
                if ($state.SkipRenameSource) { $state.SkipRenameSource=$false;return }
                if ($record.Text.Length -lt 4 -or $record.Text[2] -ne ' ') { throw 'Unsupported Git status record.' }
                $code=$record.Text.Substring(0,2)
                if ($code -eq '??') { $state.Untracked++ }
                else {
                    $state.Changed++
                    if ($code.Contains('R') -or $code.Contains('C')) { $state.SkipRenameSource=$true }
                }
            } -Complete {
                param($state,$capture)
                if ($state.SkipRenameSource) { throw 'Incomplete rename record.' }
                [pscustomobject]@{Changed=$state.Changed;Untracked=$state.Untracked}
            }
    }
    if ($status.Outcome -ne 'Success') { return }
    [pscustomobject]@{
        Branch=$branch.Data.Name
        Detached=$branch.Data.Detached
        Changed=$status.Data.Changed
        Untracked=$status.Data.Untracked
        Clean=($status.Data.Changed -eq 0 -and $status.Data.Untracked -eq 0)
        AnswerComplete=$true
    }
}
