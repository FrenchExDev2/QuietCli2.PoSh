#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([string]$Python='python3', [ValidateRange(1,100000)][int]$Records=2000,
      [ValidateRange(1024,65536)][int]$MaxOutputBytes=2048)

Import-Module (Join-Path $PSScriptRoot '../QuietCli.PoSh.psd1') -ErrorAction Stop
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../fixtures/noisy-job.py'))

# This companion executes the intended native command in each stage, consumes its
# stdout/stderr internally, and lets the model read only one final JSON document.
Invoke-QuietTask -MaxOutputBytes $MaxOutputBytes -AsJson -ArgumentList @($Python,$fixture,$Records) -ScriptBlock {
    param($python,$fixture,$records)
    $completed=[Collections.Generic.List[object]]::new()
    foreach ($stage in @('prepare','validate')) {
        $state=@{Stage=$stage;Observed=0L;Reported=$null;Done=$false;Diagnostics=0L}
        $result=Invoke-QuietStep -Name $stage -ScriptBlock {
            Invoke-QuietCli -FilePath $python -ArgumentList @($fixture,'--stage',$stage,'--records',[string]$records) `
                -TimeoutSeconds 60 -Summary "Stage $stage processed locally." -State $state -OnRecord {
                    param($record,$state)
                    if ($record.Truncated) { return }
                    if ($record.Stream -eq 'stderr') { $state.Diagnostics++;return }
                    $event=ConvertFrom-Json -InputObject $record.Text -AsHashtable -ErrorAction Stop
                    switch ($event.type) {
                        progress { $state.Observed++ }
                        completed { $state.Reported=[long]$event.processed;$state.Done=$true }
                        default { throw 'Unsupported event type.' }
                    }
                } -Complete {
                    param($state,$capture)
                    if (!$state.Done -or $state.Reported -ne $state.Observed) { throw 'Missing or inconsistent completion evidence.' }
                    [pscustomobject]@{
                        Stage=$state.Stage
                        Processed=$state.Reported
                        DiagnosticRecords=$state.Diagnostics
                    }
                }
        }
        if ($result.Outcome -ne 'Success' -or !$result.Execution.AnalysisComplete) { return }
        $completed.Add($result.Data)
    }
    # Data is an arbitrary companion object, not a fixed Items collection.
    [pscustomobject]@{
        Operation='prepare-and-validate'
        AnswerComplete=$true
        Prepared=$completed[0].Processed
        Validated=$completed[1].Processed
        Stages=$completed.ToArray()
    }
}
