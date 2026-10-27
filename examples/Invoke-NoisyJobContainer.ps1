#requires -Version 7.4
#requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PythonImage,
      [string]$QuietCliRoot=(Join-Path $PSScriptRoot '..'),
      [ValidateRange(1,100000)][int]$Records=2000,
      [ValidateRange(1024,65536)][int]$MaxOutputBytes=2048)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $QuietCliRoot 'FrenchExDev.QuietCli.PoSh.psd1') -ErrorAction Stop
$fixtures=[IO.Path]::GetFullPath((Join-Path $QuietCliRoot 'fixtures'))
# Adapter for machines without host Python: use the original Python fixture and
# the supplied companion's event reduction/completion rules. Only execution is
# adapted to a pre-existing, offline image; no image is installed or pulled.
Invoke-QuietTask -MaxOutputBytes $MaxOutputBytes -AsJson -ArgumentList @($PythonImage,$fixtures,$Records) -ScriptBlock {
    param($image,$fixtures,$records)
    $completed=[Collections.Generic.List[object]]::new()
    foreach($stage in @('prepare','validate')) {
        $state=@{Stage=$stage;Observed=0L;Reported=$null;Done=$false;Diagnostics=0L}
        $result=Invoke-QuietStep -Name $stage -ScriptBlock {
            Invoke-QuietCli -FilePath podman -ArgumentList @('run','--rm','--pull=never','--network=none','--volume',"${fixtures}:/fixture:ro",'--entrypoint','python3',$image,'-u','/fixture/noisy-job.py','--stage',$stage,'--records',[string]$records) `
                -TimeoutSeconds 60 -State $state -OnRecord {
                    param($record,$state)
                    if($record.Truncated){return}
                    if($record.Stream -eq 'stderr'){$state.Diagnostics++;return}
                    $event=ConvertFrom-Json -InputObject $record.Text -AsHashtable -ErrorAction Stop
                    switch($event.type){
                        progress {$state.Observed++}
                        completed {$state.Reported=[long]$event.processed;$state.Done=$true}
                        default {throw 'Unsupported event type.'}
                    }
                } -Complete {
                    param($state,$capture)
                    if(!$state.Done -or $state.Reported -ne $state.Observed){throw 'Missing or inconsistent completion evidence.'}
                    [pscustomobject]@{Stage=$state.Stage;Processed=$state.Reported;DiagnosticRecords=$state.Diagnostics}
                }
        }
        if($result.Outcome -ne 'Success' -or !$result.Execution.AnalysisComplete){return}
        $completed.Add($result.Data)
    }
    [pscustomobject]@{Operation='prepare-and-validate';AnswerComplete=$true;Prepared=$completed[0].Processed;Validated=$completed[1].Processed;Stages=$completed.ToArray()}
}
