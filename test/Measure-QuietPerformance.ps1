#requires -Version 7.6
#requires -PSEdition Core
[CmdletBinding()]
param([int[]]$Records=@(2000,20000),[ValidateRange(1,10)][int]$Samples=2,[string]$OutputPath=(Join-Path $PSScriptRoot '../verification/v2-performance.json'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('quietcli-benchmark-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary)
$previous=@{};foreach($key in @('QUIETCLI_DB_PATH','QUIETCLI_CONFIG_PATH','QUIETCLI_TRACKING','QUIETCLI_RECALL')){$previous[$key]=[Environment]::GetEnvironmentVariable($key)}
$sourceHashes=[ordered]@{};foreach($file in Get-ChildItem (Join-Path $root 'src') -File|Sort-Object Name){$sourceHashes[$file.Name]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash}
$results=[Collections.Generic.List[object]]::new()
try{
    $env:QUIETCLI_DB_PATH=Join-Path $temporary 'history.sqlite3';$env:QUIETCLI_CONFIG_PATH=Join-Path $temporary 'settings.json';$env:QUIETCLI_TRACKING='1';$env:QUIETCLI_RECALL='0'
    $engine=(Get-Process -Id $PID).Path
    foreach($count in $Records){
        foreach($recording in @($false,$true)){
            foreach($tokenizer in @('off','o200k_base')){
                [IO.File]::WriteAllText($env:QUIETCLI_CONFIG_PATH,(@{Recall=$false;Tokenizer=$tokenizer}|ConvertTo-Json))
                for($sample=0;$sample -le $Samples;$sample++){
                    $code='for($i=0;$i -lt '+$count+';$i++){[Console]::WriteLine("item-"+$i)}'
                    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code));$state=@{Count=0L}
                    $watch=[Diagnostics.Stopwatch]::StartNew()
                    $result=Invoke-QuietCli -FilePath $engine -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -State $state -OnOutput {param($r,$s) if($r.Stream -eq 'stdout'){$s.Count++}} -Complete {param($s,$c) @{Count=$s.Count}} -Record:$recording
                    $text=$result|ConvertTo-QuietJson;$watch.Stop()
                    if($result.Outcome -ne 'Success' -or $result.Data.Count -ne $count){throw 'Benchmark semantic assertion failed.'}
                    $results.Add(@{Records=$count;Record=$recording;Tokenizer=$tokenizer;Sample=$sample;Warmup=($sample -eq 0);ElapsedMs=$watch.Elapsed.TotalMilliseconds
                        DeliveredBytes=[Text.Encoding]::UTF8.GetByteCount($text);Observed=$result.Data.Count;CaptureComplete=$result.Completeness.Capture;Measurement=$result.Measurement.Status})
                    $result.Capture.Dispose()
                }
            }
        }
    }
}finally{foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key])}}
$groups=@($results|Where-Object {!$_.Warmup}|Group-Object Records,Record,Tokenizer|ForEach-Object {
    $sorted=@($_.Group.ElapsedMs|Sort-Object);$middle=[int][Math]::Floor($sorted.Count/2)
    $median=if($sorted.Count%2){$sorted[$middle]}else{($sorted[$middle-1]+$sorted[$middle])/2}
    @{Case=$_.Name;Samples=$sorted.Count;MedianMs=$median;MinMs=$sorted[0];MaxMs=$sorted[-1]}
})
$report=@{SchemaVersion=2;ExecutedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Platform=$PSVersionTable.OS;PowerShell=$PSVersionTable.PSVersion.ToString()
    SourceSHA256=$sourceHashes;Note='Fresh native PowerShell child per sample; first sample per case excluded. This is a local workload measurement, not an overall speedup claim.';Groups=$groups;Samples=$results.ToArray()}
[void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))))
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
@{Outcome='Success';Data=@{Groups=$groups;Report=[IO.Path]::GetFullPath($OutputPath)}}|ConvertTo-Json -Depth 10 -Compress
