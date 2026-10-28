# QuietCli V2

**The AI writes the program that answers the question. QuietCli executes it, records its evidence and makes it reusable.**

PowerShell **7.6+ Core** only. QuietCli contains no catalogue of CLI commands, argument grammars or supported executable versions. The agent reads installed help or official documentation, defines the business object, then supplies a PowerShell contract. The same contract works directly, on recorded output and in an explicitly installed module.

## Install from PowerShell Gallery

After the first release has been published, install the module in PowerShell 7.6+ Core:

```powershell
Install-PSResource FrenchExDev.QuietCli.PoSh -Repository PSGallery -Scope CurrentUser
Import-Module FrenchExDev.QuietCli.PoSh -DisableNameChecking
```

Use `-Version 2.0.0` to select a particular published version. Installation does not modify your profile or configure a consumer module. Qualification currently covers Linux only.

## Import and first call

```powershell
Import-Module ./FrenchExDev.QuietCli.PoSh.psd1 -DisableNameChecking
$result = quiet -AsObject -ContractPath ./examples/contracts/Git.Status.ps1 -WorkingDirectory /path/to/repository git status
$result | Out-QuietResult
```

The Git example is an AI-authored consumer, outside the engine. It observes the actual Git version, then runs `git --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=all --ignore-submodules=none`. Its object exposes branch, initial/detached state, upstream divergence, counts, entries and observation scope. Upstream values describe local refs; no fetch runs.

A missing contract returns `Unsupported` **without executing the native command**. `-Record` does not change this rule.

Options precede the executable. Native arguments are passed as an argument vector. When writing a native literal `--`, add one before the executable too, because PowerShell removes the first separator of a function call:

```powershell
quiet -ContractPath ./examples/contracts/Git.Status.ps1 -- git status -- 'src/a file.cs'
```

## quiet and streaming output

The public quiet and pump functions share the same parser and execution engine. quiet is the preferred spelling in current examples.

-OnOutput receives the same output object as the streaming engine: Text is the decoded record, Stream identifies stdout or stderr, and the caller's State is the second callback argument. Both streams are drained. The observed cross-stream order can be recorded and replayed; it is not a guarantee about the producer's original write order. -OnBatch remains available for batches.

The former streaming parameter is not accepted by V2. Historical V1 documentation keeps its original API names.

    $result = quiet -AsObject -State @{ Count = 0 } -OnOutput {
        param($output, $state)
        if ($output.Stream -eq 'stdout') { $state.Count++ }
    } -Complete { param($state, $capture) @{ StdoutRecords = $state.Count } } executable arguments
    $result | Out-QuietResult

Native arguments remain after the executable. Use an initial literal separator before the executable when a native literal separator follows it; this also applies to module-qualified quiet and pump calls.
## Local values and delivery

`New-QuietResult` and `Invoke-QuietCli` retain complete business data locally. Arrays are not reduced to 1,000 values. A result contains local capture handles, callbacks and internal accounting: **keep it in a variable; never print or JSON-serialize the whole object**.

```powershell
$result = New-QuietResult -Data @{ Values = @(1..1500) } -Projection { param($data, $settings) @{ Total = $data.Values.Count } }
$result | ConvertTo-QuietJson -MaxOutputBytes 2048
# Local $result.Data.Values still contains 1500 values.
```

`Out-QuietResult` applies the projection, secret masking and the final UTF-8 byte budget. JSON is the default; `-AsYaml` selects YAML. `-Envelope full` keeps default metadata. Defaults: 20 items, 4096 bytes and 600 seconds per native call.

The V2 result separates:

- `Outcome`: Success, Failed, Timeout, Cancelled or Unsupported;
- `Completeness.Source`: the native streams were drained;
- `Completeness.Analysis`: analysis completed without lost records or callback failure;
- `Completeness.Capture`: the retained raw capture is complete;
- `Truncation`: facts omitted from the delivery.

An omitted default field in a compact delivery retains its documented default. Domain completeness remains the contract's responsibility: expose scope, units and unknown values explicitly.

## Write a contract

A contract factory is a `.ps1` accepting one invocation hashtable: `FilePath`, `ArgumentList` and `WorkingDirectory`. It returns a fresh `New-QuietContract` or an explicit Unsupported result. Factories construct contracts without launching native commands; probes belong in Execute. The contract owns native adaptations and the forms it supports.

Document mode uses `-Parse`. Streaming uses `-OnOutput` or `-OnBatch`, explicit `-State` and optional `-Complete`. A `-Projection` chooses what reaches the agent. `-Execute` defines a composed task and receives the original invocation. Declare `-SourcePath`, `-Documentation` and `-SupportedForms` for reproducible reuse.

The full Git factory is in [examples/contracts/Git.Status.ps1](examples/contracts/Git.Status.ps1). All Git parsing lives there, rather than in the engine. A module may support a deliberately small subset of an executable; unsupported forms are returned to the agent for a documented extension.

Direct companion scripts remain supported:

```powershell
Invoke-QuietTask -AsJson {
    $check = Invoke-QuietCli -FilePath git -ArgumentList @('--version') -Parse { param($capture) @{ Version = $capture.Stdout.Trim() } }
    if ($check.Outcome -eq 'Success') { $check.Data }
}
```

Assigned calls register with enclosing tasks automatically. `Invoke-QuietStep` adds a name without counting the call twice. Failed child calls remain visible even when the task body consumes their results.

## RECORD and replay

```powershell
$result = quiet -AsObject -Record -ContractPath ./examples/contracts/Git.Status.ps1 -WorkingDirectory /path/to/repository git status
$id = $result.RecordId
Get-QuietRecord -Id $id
Get-QuietRecord -Id $id -Stream stderr -From 1 -Lines 20
$replayed = Invoke-QuietRecord -Id $id -ContractPath ./examples/contracts/Git.Status.ps1 -AsObject
$replayed | Out-QuietResult
```

RECORD relates the request, actual native calls, declared source snapshots and hashes, documentation, observed versions, outcomes, masked captures and complete local business data. It retains original framing and the observed order across stdout/stderr. An explicit task contract can replay its calls and recompute its original aggregation.

Replay runs the supplied PowerShell contract against retained evidence. Native calls through QuietCli consume matching recorded calls; they are not relaunched. A missing, lossy or insufficient capture cannot certify a replay. Original cross-stream write order is not an OS guarantee; the stored journal preserves the order the caller observed.

An inline callback with hidden captured variables is an observation, not a portable module. Generation requires explicit sources. Masked or missing source dependencies are reported as non-promotable. Captures never replace the executable's documented semantics or independent test assertions.

Temporary capture files are read on demand. Streaming continues after the capture cap fills. `$result.Capture.ReadLines('stderr', 1, 20)` reads a local window; `$result.Capture.Dispose()` releases its files. Otherwise files are released with the capture object. Document parsing requires a complete retained document.

## Generate one module per executable

```powershell
$module = New-QuietModule -Command git -Name FrenchExDev.QuietCli.Git.PoSh -ContractPath ./examples/contracts/Git.Status.ps1 -RecordId $id -AssertionPath ./Git.Assertions.ps1 -OutputPath ./generated-git
Test-QuietModule -Path $module.Path
Install-QuietModule -Path $module.Path
quiet git status
```

The agent supplies the parser and independent assertion scripts. Assertion scripts receive an array of `Record` / `Actual` cases. They must test known fixture preparation or documented invariants; copying a candidate's output is not an independent oracle.

Generation is deterministic for fixed source files and selected records and never overwrites an existing directory. Validation parses the sources, loads the module, replays fixtures and executes the supplied assertions. Optional live tests run only with `-IncludeLiveTests`. Installation checks the validation hash, rejects conflicts and changes only QuietCli configuration. It never edits a PowerShell profile. A later session lazily loads the configured module for its executable.

The Git consumer has its own canonical source directory beside the runtime and its own PowerShell Gallery package. The runtime ZIP does not include consumer modules. Import the Gallery-installed Git module to activate its documented command forms.

## Settings and storage

Settings are JSON at `~/.quietcli/config.json`; `QUIETCLI_CONFIG_PATH` selects another file. Explicit call options override configured limits. History remains at `~/.quietcli/gain.sqlite3`, overridden by `QUIETCLI_DB_PATH`.

```json
{
  "MaxItems": 20,
  "MaxOutputBytes": 4096,
  "TimeoutSeconds": 600,
  "MaxCaptureBytes": 10485760,
  "Recall": true,
  "RecallMaxEntries": 200,
  "RecallRetentionDays": 30,
  "Tokenizer": "o200k_base",
  "OutputFormat": "json",
  "Envelope": "compact"
}
```

The capture cap applies separately to each native stream and to its observed-record journal. Every omission is retained in completeness metadata. Automatic recall stores delivered calls; disable it with `QUIETCLI_RECALL=0`. Explicit RECORD remains available. `QUIETCLI_TRACKING=0` disables measurements; `QUIETCLI_TOKENIZER=off` disables token counting.

SQLite migrates V1 history transactionally and preserves its estimated counters. Exact counts identify tokenizer and version; summaries never mix estimates and exact token profiles into a single saving. Measurement failures do not change business success.

```powershell
QuietCliGain -Days 7 -GroupBy Command
QuietCliGain -View Html -OutputPath ./quietcli-gain.html
Get-QuietAudit
Measure-QuietContract -RecordId $id -ContractPath ./examples/contracts/Git.Status.ps1
```

The Html view writes a self-contained dashboard with inline SVG histograms comparing native output and QuietCli delivery, summary cards and expandable measurement details. Each method, tokenizer and version has its own chart; when token counts are unavailable, known byte measurements are shown explicitly. Unknown measurements and groups omitted by MaxItems are identified. No network or JavaScript is required. Use -Browse to open the generated file; reload the module in an existing session after updating it.

These measurements cover command-output volume and local runtime durations. They do not measure provider invoices or total agent costs.

## Agents and verification

[The supplied skill](skills/quiet-cli/SKILL.md) defines the documentation-first workflow. `Get-QuietAgentInstruction` returns reusable instructions. `Install-QuietHook -SettingsPath <explicit Claude settings file>` installs a hook only on request; `Uninstall-QuietHook` removes its own entry. Hook modes are warn, deny and restricted rewrite with approval. Uncertain shell syntax receives a reminder. `Get-QuietSession -Path <jsonl>` reports observed adoption without retaining transcript output.

Run the tests inside the owned Linux container with `--init`:

```powershell
& ./test/Invoke-Tests.ps1 -Analyze
& ./test/Measure-QuietPerformance.ps1 -Records 2000,20000 -Samples 2
& ./scripts/New-QuietCliArchive.ps1 -ValidateOnly
```

The GitHub workflow runs the V2 acceptance suite and source analysis only in a Linux container started with --init; it checks the PowerShell 7.6+ minimum before testing. Pester 6.2, PSScriptAnalyzer 1.25 and powershell-yaml 0.4.12 are test dependencies, not runtime dependencies. Runtime C# compiles on import using PowerShell; no separate SDK is required. Pinned tokenizers and SQLite native libraries are bundled with their notices.

Current acceptance evidence and a historical performance baseline are in [verification/v2-validation.json](verification/v2-validation.json) and [verification/v2-performance.json](verification/v2-performance.json). Qualification is Linux only. QuietCli is the active workspace engine. The public quiet and pump functions use the same execution path. -OnOutput is the streaming callback parameter; the former callback parameter is no longer accepted by V2.

V2 intentionally changes V1's intermediate truncation, explicit step accounting and result schema. The previous README is retained in [doc/V1-README.md](doc/V1-README.md); older verification files describe earlier revisions.

The current callback spelling and entry point were not used to produce the retained historical performance baseline. No new performance claim is made.

## Local CI before pushing

Run these commands from the module repository in PowerShell 7.6+ Core:

```powershell
# Objectif : Vérifier le YAML, les expressions GitHub et les connexions entre workflows.
& ./scripts/Invoke-LocalCI.ps1 -Mode Lint

# Objectif : Exécuter les tests et la construction du ZIP avec act et les artefacts locaux.
& ./scripts/Invoke-LocalCI.ps1 -Mode CI

# Objectif : Tester aussi le workflow réutilisable et le paquet NuGet, sans publication distante.
& ./scripts/Invoke-LocalCI.ps1 -Mode Release
```

On Windows, start a Linux Podman machine first. The script uses the host only to start an owned Alpine controller with `--init`, detect and mount its Podman socket, and preserve the output directories. Tools, source analysis and workflow execution stay in Linux. On Linux x64, the script runs directly; `DOCKER_HOST` selects the Docker-compatible API and defaults to `unix:///run/podman/podman.sock`.

The installer pins **act 0.2.91** and **actionlint 1.7.12**, verifies both downloaded archives and executables against SHA-256, and rechecks cached executables on subsequent calls. Tools and action downloads stay in the ignored `.local-ci/` directory. An unexpected cached checksum fails explicitly without overwriting the file.

`Lint` validates both workflow files. `CI` then runs `quietcli.yml`, including its tests and standalone ZIP checks. `Release` emulates a version-tag event derived from the root manifest and also runs `release.yml` through NuGet packaging. The local event marks `act: true`; the publication job and its remote-write steps are disabled under act. The launcher supplies empty environment, variable and secret files instead of loading local publication secrets.

Each invocation writes `artifacts/local-ci/<run>/local-ci.json` and stores workflow uploads beneath its `artifacts/` directory. Use `-OutputDirectory` to select another destination; a directory already containing a report is rejected to avoid mixing runs. The JSON report records tool versions, lint diagnostics, job/step results, test counts, completeness and the final outcome. Native output is analyzed through QuietCli and delivered as a bounded summary. The launcher does not retry failed commands automatically.

The Alpine checkout bootstrap installs Node.js only when `ACT=true` because act requires Node in the job container. A local artifact server supports the workflow's v4 upload/download actions. See the [act usage guide](https://nektosact.com/usage/index.html) and [actionlint documentation](https://github.com/rhysd/actionlint).

Local execution complements GitHub verification: act does not fully reproduce hosted-runner permissions, concurrency or deployment environments. Podman is exercised through its Docker-compatible API; act does not guarantee compatibility with every Podman version. GitHub remains the check for remote authorization and publication.

## Workflow-owned distribution

The source tree contains no `modules/` distribution copy and no `downloads/` archive. `New-QuietCliArchive.ps1 -ValidateOnly` validates the inventory without creating a ZIP. Release ZIP and NuGet package creation run in GitHub Actions and use its temporary artifact directory.

### Configure publication once

1. Register at [PowerShell Gallery](https://www.powershellgallery.com/) and create a [scoped API key](https://learn.microsoft.com/en-us/powershell/gallery/how-to/managing-profile/creating-apikeys?view=powershellget-3.x) with permission to push new packages and versions. Limit its package pattern to `FrenchExDev.QuietCli.PoSh` and renew it before expiry.
2. In this GitHub repository, open **Settings > Secrets and variables > Actions** and add the repository secret **PSGALLERY_API_KEY**. Keep its value out of source files and logs.
3. No custom Linux image is required: each job starts from **alpine:3.24** on an x64 runner, prepares Git and the Node runtime libraries for checkout, then installs **PowerShell 7.6.9 Core** from the official **linux-musl-x64** archive with its pinned SHA-256 checksum. The workflows install pinned test dependencies and PSResourceGet 1.2.0 when absent. Optionally set **QUIETCLI_LINUX_IMAGE** to a prepared image with PowerShell 7.6+ Core and Git; a compatible runtime is reused. Ubuntu 24.04 x64 is also supported by the bootstrap using the glibc archive. The image must be reachable by GitHub-hosted runners. All qualification remains inside Linux containers started with **--init**.

The Gallery package name must be available to your account. An existing package with that name requires ownership or publishing rights. The workflow never installs consumer modules or publishes the sibling Git module.

### Publish a stable version

Update `ModuleVersion` in both the root manifest and `src/QuietCli.psd1`, then commit and push the release sources. The stable tag must match both manifests exactly:

```powershell
git tag v2.0.0
git push origin v2.0.0
```

Use a new version and tag for each release; the workflow rejects prerelease tags and versions already present on PSGallery. It does not replace published packages.

The tag triggers the reusable Linux acceptance suite and source analysis in a container started with `--init`. It builds `QuietCli.zip` and verifies its hashes and runtime in a fresh PowerShell process. The release workflow then creates a clean `FrenchExDev.QuietCli.PoSh` staging directory from that ZIP, builds a NuGet package with `Compress-PSResource`, and verifies that package in another fresh process. Git metadata, local databases, previous archives and downloads are excluded. Runtime libraries and their notices remain included.

Only the verified `.nupkg` is sent to PSGallery using [Publish-PSResource -NupkgPath](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.psresourceget/publish-psresource?view=powershellget-3.x). After Gallery publication succeeds, the workflow creates the GitHub release with three assets:

- `QuietCli.zip`
- `QuietCli.manifest.json`, containing the source tag, commit, per-file hashes and both package hashes
- `FrenchExDev.QuietCli.PoSh.<version>.nupkg`

Ordinary pushes and pull requests run validation without publishing. A missing API key, mismatched version, checksum failure or unavailable Gallery stops publication explicitly. Gallery publication and GitHub release creation are separate remote operations: if the Gallery succeeds but GitHub fails, complete the GitHub release from the retained **QuietCli-release** workflow artifact; rerunning publication will reject the existing Gallery version. Local release tests use temporary files and mocked publication; they do not run remote CI or publish packages.

## Alpine integration with a real .NET project

The required Alpine integration job tests the workflow-generated **QuietCli ZIP** against
[Serilog v4.4.0](https://github.com/serilog/serilog/releases/tag/v4.4.0), commit
`6d9fc0b84e004418f2677b5961b9c8970349d0be`. It restores, builds and tests
`test/Serilog.Tests/Serilog.Tests.csproj` in Release for `net10.0`.

The fresh container uses `--init` and the pinned image
`mcr.microsoft.com/dotnet/sdk:10.0-alpine3.24@sha256:cc02b814237a76c4735fb6eeee87181597b5e56f2ce458a435e527674d91f4d7`
(SDK 10.0.403, PowerShell Core 7.6+). This qualifies Alpine Linux x64 only.
The harness verifies the archive SHA-256, both file inventories and the bundled musl
SQLite library before importing the extracted module in a fresh PowerShell process.
It never imports QuietCli from the checkout.

The temporary upstream copy receives two explicit dependency corrections:
`System.Security.Cryptography.Xml 8.0.5` and `System.Security.Cryptography.Pkcs 8.0.2`.
NuGet audit remains enabled for all dependencies and warnings remain errors.
The pinned project initially executes **815 successful tests**. No upstream changes
are committed; the temporary checkout and QuietCli database are removed after the run.

The explicit consumer factory `test/integration/contracts/DotNet.Serilog.ps1` owns
English MSBuild/VSTest console analysis; the engine has no dotnet catalogue.
Independent TRX counters and individual result rows verify the console counts.
The job also checks an identifiable compiler error, exactly one failing xUnit test,
complete captures, deliveries bounded to 4096 UTF-8 bytes, altered/incomplete ZIP
rejection, and successful replay after moving the original source directory and TRX files.
The controlled failures are expected assertions, separate from the successful baseline.

Both local modes include this job and require its successful structured result:

```powershell
# Objectif : Tester le workflow complet, dont le ZIP sur Alpine et les tests Serilog.
./scripts/Invoke-LocalCI.ps1 -Mode CI

# Objectif : Tester aussi le packaging de release sans publication distante.
./scripts/Invoke-LocalCI.ps1 -Mode Release
```

To test an existing distribution **inside the pinned Alpine container**, start a fresh
PowerShell process:

```powershell
# Objectif : Qualifier un ZIP existant avec son manifeste et conserver les rapports.
pwsh -NoLogo -NoProfile -File ./scripts/Test-QuietCliDotNetIntegration.ps1 -ArchivePath /input/QuietCli.zip -ManifestPath /input/QuietCli.manifest.json -OutputDirectory /reports/serilog
```

Use a new output directory for every run. Public access to the image registry, GitHub,
NuGet and Alpine packages is required. The job has a 20-minute limit and each native
command a 600-second limit, with no automatic retry.

The `quietcli-dotnet-integration-alpine` artifact contains `integration.json` and the
baseline/expected-failure TRX reports. The JSON records image, SDK, PowerShell, source
commit, dependency corrections, patched project hash, ZIP hash, phase outcomes and
completeness. Local CI exposes `Integration` separately from QuietCli's own `Tests`.

For a failure, inspect `integration.json` first: `Error` names the failed assertion
and `Phases` identifies the native exit code and parsed diagnostics. Missing network
prerequisites, audit findings, incomplete captures and absent TRX files fail the job;
they never count as a successful zero-test run. An upstream dependency audit failure
requires a reviewed dependency correction, while retaining the pinned source commit
and recording the new patch provenance.
