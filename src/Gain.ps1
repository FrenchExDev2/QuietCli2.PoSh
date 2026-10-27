# Private measurement state is deliberately separate from the transport envelope.
# Object-only intermediate work is not a delivery. Track the final serialized JSON.
$script:GainResults = [Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
$script:LastGainError = $null

function Get-QuietDatabasePath {
    param([string]$Path)
    if (!$Path) { $Path = $env:QUIETCLI_DB_PATH }
    if (!$Path) { $Path = Join-Path $HOME '.quietcli/gain.sqlite3' }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) { $Path = Join-Path $HOME $Path.Substring(2) }
    if (![IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
    [IO.Path]::GetFullPath($Path)
}

function Set-QuietGainSources {
    param($Result, $Sources, [string]$Command)
    $metadata = @{
        Id = [guid]::NewGuid().ToString('N'); Command = $Command; Sources = $Sources
        RecordedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    $script:GainResults.Add($Result, $metadata)
    if ($script:Tasks.Count) {
        foreach ($source in $Sources.Values) { $script:Tasks.Peek().Sources[$source.Id] = $source }
    }
}

function Set-QuietNativeGain {
    param($Result, [string]$FilePath, $Capture)
    $source = @{
        Id = [guid]::NewGuid().ToString('N')
        Bytes = $(if ($Capture) { [long]$Capture.StdoutBytes + [long]$Capture.StderrBytes } else { 0L })
        Complete = [bool]($Capture -and $Capture.SourceComplete)
        CountedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    $sources = [Collections.Generic.Dictionary[string,object]]::new()
    $sources[$source.Id] = $source
    Set-QuietGainSources $Result $sources ([IO.Path]::GetFileName($FilePath))
}

function Save-QuietGain {
    param($Result, [string]$Json)
    if ($script:Tasks.Count -or $env:QUIETCLI_TRACKING -in @('0','off','false')) { return }
    $metadata = $null
    if (!$script:GainResults.TryGetValue($Result, [ref]$metadata) -or !$metadata.Sources.Count) { return }
    $database = $null
    try {
        $path = Get-QuietDatabasePath
        if ($metadata.RecordedPaths.Contains($path)) { return }
        $bytes = 0L; $measured = $true
        foreach ($source in $metadata.Sources.Values) {
            $bytes += $source.Bytes
            # Previously delivered sources cannot be credited a second time in a new task.
            if (!$source.Complete -or $source.CountedPaths.Contains($path)) { $measured = $false }
        }
        $outputBytes = [long][Text.Encoding]::UTF8.GetByteCount($Json)
        $inputTokens = $null; $outputTokens = $null; $saved = $null
        if ($measured) {
            # RTK: https://github.com/rtk-ai/rtk/blob/develop/src/core/tracking.rs
            $inputTokens = [long][Math]::Ceiling($bytes / 4.0)
            $outputTokens = [long][Math]::Ceiling($outputBytes / 4.0)
            $saved = $inputTokens - $outputTokens
        }
        $elapsed = 0L
        if ($Result.Execution.PSObject.Properties['ElapsedMs']) { $elapsed = [long]$Result.Execution.ElapsedMs }
        $analysis = [bool]($Result.Execution.PSObject.Properties['AnalysisComplete'] -and $Result.Execution.AnalysisComplete)
        $database = [QuietCliStack.GainV1.Database]::new($path, $true)
        $database.Execute(@'
INSERT OR IGNORE INTO quietcli_deliveries
(id,timestamp_ms,command,outcome,native_calls,measured,analysis_complete,truncated,
 input_bytes,output_bytes,input_tokens,output_tokens,saved_tokens,elapsed_ms)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
'@, [object[]]@($metadata.Id, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $metadata.Command,
            $Result.Outcome, $metadata.Sources.Count, [int]$measured, [int]$analysis,
            [int][bool]$Result.Truncation.Applied, $bytes, $outputBytes, $inputTokens, $outputTokens, $saved, $elapsed))
        [void]$metadata.RecordedPaths.Add($path)
        foreach ($source in $metadata.Sources.Values) { [void]$source.CountedPaths.Add($path) }
        $script:LastGainError = $null
    } catch {
        # Observability must not change business outcomes or corrupt a single JSON document.
        $script:LastGainError = $_.Exception.GetBaseException().Message
    } finally { if ($database) { $database.Dispose() } }
}

function ConvertTo-QuietGainTotals {
    param($Row)
    $data = [ordered]@{}
    foreach ($name in @('Deliveries','NativeCalls','MeasuredDeliveries','UnmeasuredDeliveries',
            'FailedDeliveries','AnalysisIncompleteDeliveries','TruncatedDeliveries',
            'InputBytes','OutputBytes','InputTokens','OutputTokens','SavedTokens')) {
        $data[$name] = $(if ($Row -and $null -ne $Row[$name]) { [long]$Row[$name] } else { 0L })
    }
    $data.SavingsPercent = $(if ($data.InputTokens -gt 0) {
        [Math]::Round(100.0 * $data.SavedTokens / $data.InputTokens, 2)
    } else { $null })
    $data.ByteReductionPercent = $(if ($data.InputBytes -gt 0) {
        [Math]::Round(100.0 * ($data.InputBytes - $data.OutputBytes) / $data.InputBytes, 2)
    } else { $null })
    [pscustomobject]$data
}

function Format-QuietGainText {
    param($Report, [switch]$Chart)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $total = $Report.Totals
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('QuietCli gain — estimated tokens (ceil(UTF-8 bytes / 4))')
    $lines.Add(('UTC period: {0} <= timestamp < {1}' -f $Report.FromUtc, $Report.ToUtc))
    $lines.Add(('Deliveries: {0}; native calls: {1}; measured: {2}; unmeasured: {3}' -f
        $total.Deliveries, $total.NativeCalls, $total.MeasuredDeliveries, $total.UnmeasuredDeliveries))
    $percent = if ($null -eq $total.SavingsPercent) { 'n/a' } else { $total.SavingsPercent.ToString('0.00', $culture) + '%' }
    $lines.Add(('Input: {0}; output: {1}; saved: {2}; reduction: {3}' -f
        $total.InputTokens, $total.OutputTokens, $total.SavedTokens, $percent))
    $lines.Add(('Failed deliveries: {0}; incomplete analyses: {1}; truncated/redacted: {2}' -f
        $total.FailedDeliveries, $total.AnalysisIncompleteDeliveries, $total.TruncatedDeliveries))
    if (!$total.Deliveries) { $lines.Add('No recorded deliveries in this period.') }
    if ($Report.LastTrackingError) { $lines.Add('Last tracking error in this process: ' + $Report.LastTrackingError) }
    if (!$Report.TrackingEnabled) { $lines.Add('Recording is disabled by QUIETCLI_TRACKING; existing history is still readable.') }
    $max = 1.0
    foreach ($group in $Report.Groups) { $max = [Math]::Max($max, [Math]::Abs([double]$group.Totals.SavedTokens)) }
    foreach ($group in $Report.Groups) {
        $saved = $group.Totals.SavedTokens
        $bar = ''
        if ($Chart) {
            $width = [int][Math]::Ceiling(20 * [Math]::Abs([double]$saved) / $max)
            $negative = if ($saved -lt 0) { '-' * $width } else { '' }
            $positive = if ($saved -gt 0) { '#' * $width } else { '' }
            $bar = ' [' + $negative.PadLeft(20) + '|' + $positive.PadRight(20) + ']'
        }
        $lines.Add(('{0,-24} {1,12} saved  ({2} deliveries){3}' -f
            $group.Label, $saved, $group.Totals.Deliveries, $bar))
    }
    if ($Report.OmittedGroups) { $lines.Add(('{0} groups omitted; totals cover the entire period.' -f $Report.OmittedGroups)) }
    $lines.Add('Negative savings mean expansion. Estimates cover command output, not total agent cost.')
    $lines -join [Environment]::NewLine
}

function Write-QuietGainHtml {
    param($Report, [string]$Path)
    $encode = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $max = 1.0
    foreach ($group in $Report.Groups) { $max = [Math]::Max($max, [Math]::Abs([double]$group.Totals.SavedTokens)) }
    $height = 60 + 38 * $Report.Groups.Count
    $svg = [Text.StringBuilder]::new()
    [void]$svg.AppendLine(('<svg viewBox="0 0 920 {0}" role="img" aria-label="Estimated tokens saved by group"><line x1="470" y1="20" x2="470" y2="{0}" stroke="#94a3b8"/>' -f $height))
    $y = 30
    foreach ($group in $Report.Groups) {
        $saved = $group.Totals.SavedTokens
        $width = [int][Math]::Round(260 * [Math]::Abs([double]$saved) / $max)
        $x = if ($saved -lt 0) { 470 - $width } else { 470 }
        $color = if ($saved -lt 0) { '#fb923c' } else { '#34d399' }
        [void]$svg.AppendLine(('<text x="12" y="{0}" fill="#e2e8f0">{1}</text><rect x="{2}" y="{3}" width="{4}" height="20" fill="{5}"/><text x="760" y="{0}" fill="#e2e8f0">{6}</text>' -f
            ($y+15), (& $encode $group.Label), $x, $y, $width, $color, $saved))
        $y += 38
    }
    [void]$svg.AppendLine('</svg>')
    $summary = & $encode (Format-QuietGainText $Report)
    $html = @"
<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>QuietCli gain</title>
<style>body{background:#0f172a;color:#e2e8f0;font:16px system-ui;margin:3rem auto;padding:0 1.5rem;max-width:1100px}h1{color:#34d399}pre{white-space:pre-wrap;line-height:1.6}svg{width:100%;font:14px monospace}section{background:#1e293b;padding:1.5rem;border-radius:12px;margin:1.5rem 0}p{line-height:1.6}</style>
<h1>QuietCli gain</h1><p>Estimated command-output savings · UTC period · ceil(UTF-8 bytes / 4)</p>
<section><pre>$summary</pre></section><section><h2>Saved tokens by $($Report.GroupBy.ToLowerInvariant())</h2>$svg</section>
<p>Green bars show savings; orange bars show expansion. Groups share one scale around zero. Incomplete sources are excluded from token totals. This standalone report uses no external scripts or services.</p>
</html>
"@
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    [IO.File]::WriteAllText($fullPath, $html, [Text.UTF8Encoding]::new($false))
    $fullPath
}

function QuietCliGain {
    <#
    .SYNOPSIS
    Show estimated command-output savings stored in SQLite.
    .DESCRIPTION
    Defaults to the last seven days. Uses ceil(UTF-8 bytes / 4), as RTK does.
    Range boundaries are start-inclusive and end-exclusive; grouping uses UTC.
    .EXAMPLE
    QuietCliGain -Days 30 -View Chart
    .EXAMPLE
    QuietCliGain -From '2026-10-01T00:00:00Z' -To '2026-11-01T00:00:00Z' -View Html -OutputPath ./gain.html
    .EXAMPLE
    QuietCliGain -Days 30 -View Html -OutputPath ./gain.html -Browse
    #>
    [CmdletBinding(DefaultParameterSetName='Days')]
    param(
        [Parameter(ParameterSetName='Days')][ValidateRange(1,36500)][int]$Days=7,
        [Parameter(Mandatory,ParameterSetName='Range')][DateTimeOffset]$From,
        [Parameter(ParameterSetName='Range')][DateTimeOffset]$To=[DateTimeOffset]::UtcNow,
        [ValidateSet('Day','Command')][string]$GroupBy='Day',
        [ValidateSet('Text','Chart','Html','Object','Json')][string]$View='Text',
        [ValidateRange(1,1000)][int]$MaxItems=31,
        [string]$OutputPath,
        [switch]$Browse,
        [string]$DatabasePath
    )
    if ($View -eq 'Html' -and !$OutputPath) { throw '-OutputPath is required for -View Html.' }
    if ($View -ne 'Html' -and $OutputPath) { throw '-OutputPath is only supported with -View Html.' }
    if ($Browse -and $View -ne 'Html') { throw '-Browse is only supported with -View Html.' }
    $until = if ($PSCmdlet.ParameterSetName -eq 'Days') { [DateTimeOffset]::UtcNow } else { $To }
    $since = if ($PSCmdlet.ParameterSetName -eq 'Days') { $until.AddDays(-$Days) } else { $From }
    if ($since -ge $until) { throw '-From must be earlier than -To.' }
    $path = Get-QuietDatabasePath $DatabasePath
    $rows = @(); $groups = @(); $groupCount = 0L; $database = $null
    if (Test-Path -LiteralPath $path) {
        try {
            $database = [QuietCliStack.GainV1.Database]::new($path, $false)
            $parameters = [object[]]@($since.ToUnixTimeMilliseconds(), $until.ToUnixTimeMilliseconds())
            $aggregate = @'
COUNT(*) AS Deliveries, COALESCE(SUM(native_calls),0) AS NativeCalls,
COALESCE(SUM(measured),0) AS MeasuredDeliveries, COALESCE(SUM(1-measured),0) AS UnmeasuredDeliveries,
COALESCE(SUM(CASE WHEN outcome <> 'Success' THEN 1 ELSE 0 END),0) AS FailedDeliveries,
COALESCE(SUM(1-analysis_complete),0) AS AnalysisIncompleteDeliveries,
COALESCE(SUM(truncated),0) AS TruncatedDeliveries,
COALESCE(SUM(CASE WHEN measured=1 THEN input_bytes ELSE 0 END),0) AS InputBytes,
COALESCE(SUM(CASE WHEN measured=1 THEN output_bytes ELSE 0 END),0) AS OutputBytes,
COALESCE(SUM(input_tokens),0) AS InputTokens, COALESCE(SUM(output_tokens),0) AS OutputTokens,
COALESCE(SUM(saved_tokens),0) AS SavedTokens
'@
            $scope = ' FROM quietcli_deliveries WHERE timestamp_ms >= ? AND timestamp_ms < ?'
            $label = if ($GroupBy -eq 'Day') { "strftime('%Y-%m-%d',timestamp_ms/1000.0,'unixepoch')" } else { 'command' }
            $order = if ($GroupBy -eq 'Day') { 'Label DESC' } else { 'ABS(SavedTokens) DESC, Label ASC' }
            # One read snapshot keeps totals, group count, and selected groups consistent.
            $database.Execute('BEGIN', [object[]]@())
            $rows = @($database.Query(('SELECT ' + $aggregate + $scope), $parameters))
            $groupCount = [long]$database.Query(('SELECT COUNT(DISTINCT ' + $label + ') AS N' + $scope), $parameters)[0]['N']
            $selected = @($database.Query(('SELECT ' + $label + ' AS Label,' + $aggregate + $scope +
                ' GROUP BY Label ORDER BY ' + $order + ' LIMIT ?'), [object[]]@($parameters[0], $parameters[1], $MaxItems)))
            $groups = @(foreach ($row in $selected) {
                [pscustomobject]@{Label=[string]$row['Label'];Totals=ConvertTo-QuietGainTotals $row}
            })
            if ($GroupBy -eq 'Day') { $groups = @($groups | Sort-Object Label) }
            $database.Execute('COMMIT', [object[]]@())
        } catch { throw "QuietCli gain history cannot be read: $($_.Exception.GetBaseException().Message)" }
        finally { if ($database) { $database.Dispose() } }
    }
    $report = [pscustomobject][ordered]@{
        Estimator='ceil(utf8_bytes/4)'; Estimated=$true; DatabasePath=$path
        FromUtc=$since.UtcDateTime.ToString('o'); ToUtc=$until.UtcDateTime.ToString('o')
        TrackingEnabled=($env:QUIETCLI_TRACKING -notin @('0','off','false'))
        LastTrackingError=$script:LastGainError; GroupBy=$GroupBy
        Totals=ConvertTo-QuietGainTotals $(if ($rows.Count) { $rows[0] } else { $null })
        Groups=$groups; TotalGroups=$groupCount; OmittedGroups=($groupCount-$groups.Count)
    }
    switch ($View) {
        Object { $report }
        Json { ConvertTo-Json -InputObject $report -Depth 8 -Compress }
        Html {
            $reportPath = Write-QuietGainHtml $report $OutputPath
            if ($Browse) {
                try {
                    # A file URI preserves spaces, Unicode, and literal '#' characters.
                    Start-Process -FilePath ([Uri]::new($reportPath)).AbsoluteUri -ErrorAction Stop
                } catch {
                    throw "HTML report saved to '$reportPath', but the default browser could not be opened: $($_.Exception.Message)"
                }
            }
            $reportPath
        }
        Chart { Format-QuietGainText $report -Chart }
        Text { Format-QuietGainText $report }
    }
}
