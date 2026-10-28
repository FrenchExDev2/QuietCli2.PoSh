#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,[string]$QuietCliRoot=(Join-Path $PSScriptRoot '..'),[int]$MaxOutputBytes=2048)
$QuietCliRoot=[IO.Path]::GetFullPath($QuietCliRoot)
Import-Module (Join-Path $QuietCliRoot 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking -ErrorAction Stop
Invoke-QuietTask -AsJson -MaxOutputBytes $MaxOutputBytes -ArgumentList @($Repository,$QuietCliRoot) {
    param($repo,$runtime)
    $status=quiet -AsObject -WorkingDirectory $repo -ContractPath (Join-Path $runtime 'examples/contracts/Git.Status.ps1') git status
    if($status.Outcome -ne 'Success'){return}
    @{NeedsReview=(!$status.Data.Clean);ChangedEntries=$status.Data.Counts.Changed;HeadOid=$status.Data.HeadOid;Scope=$status.Data.Scope;AnswerComplete=$status.Data.AnswerComplete}
}
