#requires -Version 7.6
#requires -PSEdition Core
# Objectif : Vérifier ou exécuter les workflows localement, avec publication distante désactivée.
[CmdletBinding()]
param(
    [ValidateSet('Lint', 'CI', 'Release')][string]$Mode = 'CI',
    [string]$OutputDirectory = '',
    [string]$CacheDirectory = '',
    [string]$EngineSocketPath = '',
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking -ErrorAction Stop
$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root ('artifacts/local-ci/' + $runId) }
if (!$CacheDirectory) { $CacheDirectory = Join-Path $root '.local-ci' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$cache = [IO.Path]::GetFullPath($CacheDirectory)
if (Test-Path -LiteralPath (Join-Path $output 'local-ci.json')) { throw 'The output directory already contains a local-CI report. Choose a new directory or omit OutputDirectory.' }
[void][IO.Directory]::CreateDirectory($output)
[void][IO.Directory]::CreateDirectory($cache)

if (!$IsLinux) {
    # Objectif : Résoudre le socket du moteur Linux ; l'hôte effectue uniquement le transport Podman.
    if (!$EngineSocketPath) {
        $info = pump -AsObject -Parse {
            param($capture)
            $value = $capture.Stdout | ConvertFrom-Json
            @{ Socket = $value.host.remoteSocket.path; OS = $value.host.os }
        } podman info --format json
        if ($info.Outcome -ne 'Success' -or $info.Data.OS -ne 'linux') {
            $info | Out-QuietResult
            throw 'Start a Linux Podman machine before running local CI.'
        }
        $EngineSocketPath = [string]$info.Data.Socket
    }
    $EngineSocketPath = $EngineSocketPath -replace '^unix://', ''
    if (!$EngineSocketPath.StartsWith('/')) { throw 'EngineSocketPath must identify the Unix socket inside the Podman machine.' }
    $containerName = 'quietcli-local-ci-' + [guid]::NewGuid().ToString('N')
    $bootstrap = @'
# Objectif : Amorcer le contrôleur Linux puis y exécuter le mode de CI locale demandé.
set -eu
sh /module/.github/scripts/Initialize-QuietCliLinux.sh
exec pwsh -NoLogo -NoProfile -File /module/scripts/Invoke-LocalCI.ps1 -Mode __MODE__ -OutputDirectory /reports -CacheDirectory /local-ci -TimeoutSeconds __TIMEOUT__
'@
    $bootstrap = $bootstrap.Replace('__MODE__', $Mode).Replace('__TIMEOUT__', [string]$TimeoutSeconds)
    $arguments = @(
        'run', '--rm', '--init', '--interactive', '--network', 'host', '--pull=missing', '--name', $containerName,
        '--env', 'DOCKER_HOST=unix:///run/podman/podman.sock',
        '--volume', ($EngineSocketPath + ':/run/podman/podman.sock'),
        '--volume', ($root + ':/module:ro'),
        '--volume', ($cache + ':/local-ci'),
        '--volume', ($output + ':/reports'),
        '--workdir', '/module', 'docker.io/library/alpine:3.24', 'sh', '-s'
    )
    # Objectif : Exécuter le lanceur sous Linux en conservant les artefacts sur l'hôte.
    $transport = pump -AsObject -TimeoutSeconds ($TimeoutSeconds + 300) -InputText $bootstrap -Parse {
        param($capture)
        $lines = @($capture.Stdout -split "\r?\n" | Where-Object { $_.StartsWith('{') })
        if (!$lines.Count) { throw 'The Linux controller did not return a structured result.' }
        $lines[-1] | ConvertFrom-Json
    } podman @arguments
    if ($transport.Data -and $transport.Data.Data) {
        $data = $transport.Data.Data
        $data.Report = Join-Path $output 'local-ci.json'
        $data.ArtifactDirectory = Join-Path $output 'artifacts'
        $outcome = if ($transport.Outcome -eq 'Success') { [string]$transport.Data.Outcome } else { [string]$transport.Outcome }
        $result = New-QuietResult -Outcome $outcome -Summary ('Local ' + $Mode + ' completed in Linux.') -Data $data
        $result | ConvertTo-QuietJson -MaxOutputBytes 8192
    } else { $transport | Out-QuietResult }
    if ($transport.Outcome -ne 'Success' -or $transport.Data.Outcome -ne 'Success') { exit 1 }
    return
}

$reportPath = Join-Path $output 'local-ci.json'
$report = [ordered]@{
    SchemaVersion = 1; Mode = $Mode; Outcome = 'Failed'; PublicationEnabled = $false
    StartedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); CompletedAtUtc = $null
    Runtime = @{ PowerShell = $PSVersionTable.PSVersion.ToString(); OS = $PSVersionTable.OS }
    Tools = $null; Lint = $null; Act = $null; Error = $null
    ArtifactDirectory = (Join-Path $output 'artifacts'); SourceKind = 'WorkingTreeFiles'
}
$previousLocation = Get-Location
$environmentBefore = @{}
foreach ($key in @('DOCKER_HOST', 'GIT_CONFIG_GLOBAL', 'NO_COLOR')) {
    $environmentBefore[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    Set-Location $root
    # Objectif : Réutiliser ou installer uniquement les versions d'outils dont les empreintes sont épinglées.
    $tools = & (Join-Path $PSScriptRoot 'Install-QuietCliLocalTools.ps1') -Destination (Join-Path $cache 'tools')
    $report.Tools = @{ act = $tools.act.Version; actionlint = $tools.actionlint.Version }
    $workflows = @('.github/workflows/quietcli.yml', '.github/workflows/release.yml')
    # Objectif : Détecter les erreurs YAML, d'expressions et de connexion entre workflows avant toute exécution.
    $lint = pump -AsObject -Parse {
        param($capture)
        $text = $capture.Stdout.Trim()
        $findings = if ($text -and $text -ne 'null') { @($text | ConvertFrom-Json) } else { @() }
        @{ Findings = $findings; Count = $findings.Count }
    } $tools.actionlint.Path -no-color -format '{{json .}}' @workflows
    $report.Lint = @{ Outcome = $lint.Outcome; Diagnostics = $lint.Data.Findings; Count = $lint.Data.Count; ShellCheckAvailable = [bool](Get-Command shellcheck -ErrorAction SilentlyContinue) }
    if ($lint.Outcome -ne 'Success') { throw 'Workflow validation failed. Read the actionlint diagnostics in local-ci.json.' }

    if ($Mode -ne 'Lint') {
        if (!$env:DOCKER_HOST) { $env:DOCKER_HOST = 'unix:///run/podman/podman.sock' }
        $env:NO_COLOR = '1'
        $gitConfig = Join-Path $output 'gitconfig'
        [IO.File]::WriteAllText($gitConfig, ("[safe]" + [char]10 + "directory = " + $root + [char]10))
        $env:GIT_CONFIG_GLOBAL = $gitConfig
        $empty = Join-Path $output 'empty.env'
        [IO.File]::WriteAllText($empty, '')
        $version = (Import-PowerShellDataFile (Join-Path $root 'FrenchExDev.QuietCli.PoSh.psd1')).ModuleVersion
        $eventFile = Join-Path $output 'event.json'
        $reference = if ($Mode -eq 'Release') { 'refs/tags/v' + $version } else { 'refs/heads/local-ci' }
        @{ act = $true; ref = $reference } | ConvertTo-Json | Set-Content -LiteralPath $eventFile -Encoding utf8
        $report['EventRef'] = $reference
        $workflow = if ($Mode -eq 'Release') { '.github/workflows/release.yml' } else { '.github/workflows/quietcli.yml' }
        $report['Workflow'] = $workflow
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        try { $listener.Start(); $port = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
        [void][IO.Directory]::CreateDirectory($report.ArtifactDirectory)
        $arguments = @(
            'push', '-W', $workflow, '-e', $eventFile, '--json',
            '-P', 'ubuntu-latest=docker.io/library/alpine:3.24',
            '--container-architecture', 'linux/amd64', '--container-daemon-socket', '-',
            '--network', 'host', '--pull=false', '--action-offline-mode',
            '--action-cache-path', (Join-Path $cache 'actions'),
            '--artifact-server-addr', '127.0.0.1', '--artifact-server-port', [string]$port,
            '--artifact-server-path', $report.ArtifactDirectory,
            '--env-file', $empty, '--secret-file', $empty, '--var-file', $empty
        )
        $state = @{
            ProgressPath = (Join-Path $output 'progress.json'); LogWindows = @{}; FailedStepDiagnostics = [Collections.Generic.List[object]]::new(); Records = 0; UnparsedRecords = 0; NonTestRecords = 0; ErrorCount = 0; Errors = [Collections.Generic.List[string]]::new()
            Steps = [Collections.Generic.List[object]]::new(); Jobs = @{}; TestSummary = $null; IntegrationSummary = $null
        }
        # Objectif : Exécuter le workflow en analysant les résultats des étapes, sans charger de secrets de publication.
        $execution = pump -AsObject -Record -TimeoutSeconds $TimeoutSeconds -State $state -OnOutput {
            param($record, $state)
            if ([string]::IsNullOrWhiteSpace($record.Text)) { return }
            $state.Records++
            try { $logEntry = $record.Text | ConvertFrom-Json -ErrorAction Stop }
            catch { $state.UnparsedRecords++; return }
            $message = [string]$logEntry.msg
            if ($logEntry.level -in @('error', 'fatal')) { $state.ErrorCount++; if ($state.Errors.Count -lt 20) { $state.Errors.Add($message) } }
            $windowKey = [string]$logEntry.job + '|' + [string]$logEntry.step
            if ($logEntry.raw_output) {
                if (!$state.LogWindows.ContainsKey($windowKey)) { $state.LogWindows[$windowKey] = @{ Lines = [Collections.Generic.Queue[object]]::new(); Omitted = 0 } }
                $window = $state.LogWindows[$windowKey]
                $window.Lines.Enqueue(@{ Text = $message.Substring(0, [Math]::Min(320, $message.Length)); CharactersOmitted = [Math]::Max(0, $message.Length - 320) })
                if ($window.Lines.Count -gt 20) { [void]$window.Lines.Dequeue(); $window.Omitted++ }
            }
            if ($logEntry.stepResult) {
                $state.Steps.Add(@{ Job = [string]$logEntry.job; Step = [string]$logEntry.step; Result = [string]$logEntry.stepResult })
                if ($logEntry.stepResult -eq 'failure' -and $state.LogWindows.ContainsKey($windowKey)) {
                    $window = $state.LogWindows[$windowKey]
                    $state.FailedStepDiagnostics.Add(@{ Job = [string]$logEntry.job; Step = [string]$logEntry.step; Lines = $window.Lines.ToArray(); OmittedRecords = $window.Omitted })
                }
                [void]$state.LogWindows.Remove($windowKey)
                [IO.File]::WriteAllText($state.ProgressPath, (@{ Job = [string]$logEntry.job; Step = [string]$logEntry.step; Result = [string]$logEntry.stepResult; CompletedSteps = $state.Steps.Count } | ConvertTo-Json -Compress))
            }
            if ($logEntry.job -and $message -match 'Job succeeded|Job failed') {
                $state.Jobs[[string]$logEntry.job] = $(if ($message -match 'Job succeeded') { 'Success' } else { 'Failed' })
            }
            if ($message.StartsWith('{')) {
                try {
                    $value = $message | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $value.Data.Passed) { $state.TestSummary = $value.Data }
                    if ($value.Data.Kind -eq 'DotNetIntegration') { $state.IntegrationSummary = @{ Outcome = $value.Outcome; Data = $value.Data } }
                } catch { $state.NonTestRecords++ }
            }
        } -Complete {
            param($state)
            @{ Records = $state.Records; UnparsedRecords = $state.UnparsedRecords; NonTestRecords = $state.NonTestRecords; ErrorCount = $state.ErrorCount; ErrorsOmitted = ($state.ErrorCount - $state.Errors.Count); Errors = $state.Errors.ToArray(); FailedStepDiagnostics = $state.FailedStepDiagnostics.ToArray(); Steps = $state.Steps.ToArray(); Jobs = $state.Jobs; Tests = $state.TestSummary; Integration = $state.IntegrationSummary }
        } $tools.act.Path @arguments
        $report.Act = @{
            Outcome = $execution.Outcome; ExitCode = $execution.Execution.ExitCode
            Completeness = $execution.Completeness; RecordId = $execution.RecordId; Error = $execution.Error; Results = $execution.Data
        }
        if ($execution.Outcome -ne 'Success') { throw 'Local workflow execution failed. Read local-ci.json for bounded diagnostics.' }
        $steps = @($execution.Data.Steps)
        $testSteps = @($steps | Where-Object { $_.Step -like '*Test runtime and canonical Git consumer*' -and $_.Result -eq 'success' })
        if (!$testSteps.Count) { throw 'act did not confirm execution of the acceptance-test step.' }
        $integrationSteps = @($steps | Where-Object { $_.Step -like '*Test ZIP on Alpine with Serilog*' -and $_.Result -eq 'success' })
        if (!$integrationSteps.Count -or $execution.Data.Integration.Outcome -ne 'Success') {
            throw 'act did not confirm successful Alpine Serilog integration.'
        }
        if ($Mode -eq 'Release' -and !@($steps | Where-Object { $_.Step -like '*Build and verify the Gallery package from the tested ZIP*' -and $_.Result -eq 'success' }).Count) {
            throw 'act did not confirm execution of the NuGet packaging step.'
        }
        if (@($steps | Where-Object { $_.Step -match 'Publish the verified package|Create the GitHub release' -and $_.Result -eq 'success' }).Count) {
            throw 'A remote-publication step unexpectedly ran during local validation.'
        }
    }
    $report.Outcome = 'Success'
} catch {
    $report.Error = $_.Exception.Message
    if ($report.Act -and $report.Act.Outcome -in @('Timeout', 'Cancelled')) { $report.Outcome = $report.Act.Outcome }
} finally {
    $report.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    # Objectif : Conserver le rapport métier complet, sans sérialiser les captures internes de QuietCli.
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    foreach ($key in $environmentBefore.Keys) { [Environment]::SetEnvironmentVariable($key, $environmentBefore[$key]) }
    Set-Location $previousLocation
}
$summary = @{
    Mode = $Mode; Report = $reportPath; ArtifactDirectory = $report.ArtifactDirectory
    PublicationEnabled = $false; Tools = $report.Tools; LintErrors = $(if ($report.Lint) { $report.Lint.Count } else { $null })
    Tests = $(if ($report.Act) { $report.Act.Results.Tests } else { $null })
    Jobs = $(if ($report.Act) { $report.Act.Results.Jobs } else { $null })
    Integration = $(if ($report.Act) { $report.Act.Results.Integration } else { $null })
    Error = $report.Error
}
$result = New-QuietResult -Outcome $report.Outcome -Summary ('Local ' + $Mode + ' validation: ' + $report.Outcome) -Data $summary
$result | ConvertTo-QuietJson -MaxOutputBytes 8192 -MaxItems 30
if ($report.Outcome -ne 'Success') { exit 1 }
