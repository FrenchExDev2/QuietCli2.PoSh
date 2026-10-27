# QuietCli

**Give your AI agent the useful result of a command. Compute that result locally.**

QuietCli is a **PowerShell 7.4+ Core** module for writing **companion scripts**: they run your tools, analyze their output, and return a single JSON result within an explicit budget. The agent defines the question; the script computes the answer; QuietCli handles processes, both streams, and the result envelope.

```text
Question: "Does this repository need a review?"

git branch + git status
        ↓ local analysis in a companion script
{ Branch: "main", Changed: 1, Untracked: 1, Clean: false }
        ↓ one bounded JSON envelope
The agent has the facts it needs to decide.
```

**5 public functions · Bounded UTF-8 JSON · Composable tasks · MIT license**

[Get started](#get-started) · [Load at startup](#load-quietcli-when-pwsh-starts) · [Git example](#practical-example-inspect-a-git-repository) · [Write a companion](#write-your-first-companion) · [API](#the-five-public-functions) · [Troubleshooting](#troubleshooting)

## Why QuietCli?

Terminal output often mixes progress messages, diagnostics, and data. QuietCli lets a local program process that text and send the AI an answer tailored to the request.

| Your question | What the script computes and returns |
| --- | --- |
| Is the repository clean? | Branch, changed entries, untracked entries, and a `Clean` flag. |
| Did validation succeed? | Totals, failures, and selected diagnostics. |
| How many items match? | Count, scope, unit, and completeness status. |
| Does preparation allow the next step? | Preparation result, local decision, and validation result. |

The `.Data` property is freely defined: a domain object, an array, a scalar, or `null`. You choose the information you need and keep intermediate calculations inside the script.

## Get started

### Prerequisites

| Component | When do you need it? |
| --- | --- |
| **PowerShell 7.4+ Core**, the `pwsh` executable | For the module and PowerShell companions. Windows PowerShell 5.1 is not supported. |
| **Git** on the `PATH` | For the Git examples. |
| **Python 3** | For the noisy demonstration and the full integration suite. |
| Bash, awk, jq, and GNU `timeout` | For the Bash companion and its Linux checks. |

The PowerShell module has no third-party module dependencies. Its C# code loads on import; no separate .NET SDK installation is required. You can use any text editor.

### 1. Get the module

**From this workspace**, copy this block into `pwsh`:

```powershell
$moduleRoot = 'C:/code/FrenchExDev/FrenchExDev_i2/PoSh/FrenchExDev/FrenchExDev.QuietCli.PoSh'
$moduleRoot = (Resolve-Path -LiteralPath $moduleRoot -ErrorAction Stop).Path
$moduleManifest = Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1'
Import-Module $moduleManifest -ErrorAction Stop
Get-Command New-QuietResult, Invoke-QuietCli, Invoke-QuietTask, Invoke-QuietStep, ConvertTo-QuietJson
```

Adjust the first line to your checkout location. The checkout uses the **`FrenchExDev.QuietCli.PoSh.psd1`** manifest. Older archives may still use `QuietCli.PoSh.psd1`; the next block supports both names.

**Without a checkout**, download the [QuietCli.zip bundle](downloads/QuietCli.zip), save it to your downloads folder, and extract it to a permanent location:

```powershell
# Adjust this path to the actual download location.
$archive = Join-Path $HOME 'Downloads/QuietCli.zip'
$installRoot = Join-Path $HOME '.local/share/quietcli'
if (Test-Path -LiteralPath (Join-Path $installRoot 'QuietCli')) {
    throw 'QuietCli already exists here. Choose another folder for this extraction.'
}
Expand-Archive -LiteralPath $archive -DestinationPath $installRoot -ErrorAction Stop
$moduleRoot = (Resolve-Path -LiteralPath (Join-Path $installRoot 'QuietCli')).Path
$moduleManifest = Join-Path $moduleRoot 'FrenchExDev.QuietCli.PoSh.psd1'
# Support archives created before the manifest was renamed.
if (!(Test-Path -LiteralPath $moduleManifest)) {
    $moduleManifest = Join-Path $moduleRoot 'QuietCli.PoSh.psd1'
}
Import-Module $moduleManifest -ErrorAction Stop
Get-Command New-QuietResult, Invoke-QuietCli, Invoke-QuietTask, Invoke-QuietStep, ConvertTo-QuietJson
```

The ZIP includes the runtime, skill, examples, fixtures, and verification launcher. Keep its `package-manifest.json` and the [distribution manifest](downloads/QuietCli.manifest.json), which identify the contents using SHA-256 hashes. The checkout README and the README in a previously generated archive may correspond to different revisions.

### 2. Get your first result

In the same session, specify **an existing Git repository**:

```powershell
$repository = 'C:/code/my-project' # Replace this path.
& (Join-Path $moduleRoot 'examples/Generated-GitOverview.ps1') `
    -Repository $repository -MaxOutputBytes 2048
```

You receive a JSON document with `Outcome`, `Data`, `Execution`, `Error`, and `Truncation`. The [reproducible example](#practical-example-inspect-a-git-repository) below creates its own repository if you prefer to try it without touching your project.

## Load QuietCli when pwsh starts

PowerShell distinguishes the current host profile (`$PROFILE`) from the current user's profile shared across hosts (`$PROFILE.CurrentUserAllHosts`). Use the latter to make QuietCli available in the console and other PowerShell hosts. The [PowerShell documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles) explains profiles and their loading order.

**After either installation above**, run this block. It uses `$moduleRoot`, validates the manifest, backs up the existing profile, and adds a marked section only once:

```powershell
$quietCliManifest = (Resolve-Path -LiteralPath $moduleManifest -ErrorAction Stop).Path
$profilePath = $PROFILE.CurrentUserAllHosts
$marker = '# >>> QuietCli >>>'
$profileText = if (Test-Path -LiteralPath $profilePath) {
    [string](Get-Content -LiteralPath $profilePath -Raw)
} else { '' }

if ($profileText.Contains($marker)) {
    Write-Host "A QuietCli section already exists in $profilePath. Check its path if you moved the module."
} else {
    New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
    if (Test-Path -LiteralPath $profilePath) {
        $backupPath = '{0}.{1}.bak' -f $profilePath, (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')
        Copy-Item -LiteralPath $profilePath -Destination $backupPath -ErrorAction Stop
    }
    $profileBlock = @"
# >>> QuietCli >>>
Import-Module '__QUIETCLI_MANIFEST__' -ErrorAction Stop
# <<< QuietCli <<<
"@
    $profileBlock = $profileBlock.Replace('__QUIETCLI_MANIFEST__', $quietCliManifest.Replace("'", "''"))
    Add-Content -LiteralPath $profilePath -Value ("`n" + $profileBlock) -Encoding utf8
}

# Load the configuration in the current session.
. $profilePath
Get-Command Invoke-QuietCli, Invoke-QuietTask, Invoke-QuietStep
```

The profile contains a correctly quoted **absolute path** and works without variables from the installation session. Open a new terminal with `pwsh` to check that the module loads at startup.

A process started with `pwsh -NoProfile` skips profiles; its scripts must import the module themselves. The supplied companions already do this. Remote sessions do not automatically load your local profile either. To limit loading to the current host, replace `$PROFILE.CurrentUserAllHosts` with `$PROFILE` in the installation block.

To move or disable the installation, edit the section between the two markers in `$profilePath`. Commands remain loaded in existing sessions until you close them or unload the module.

## Practical example: inspect a Git repository

**Goal:** get the branch, count changed and untracked entries, and determine whether the repository is clean. The supplied companion combines two Git observations and returns a single JSON document of **at most 2,048 bytes**.

### Create a reproducible case

This block creates a new temporary folder, a local commit, a change, and an untracked directory. It does not use an existing repository. Git must be installed; `$moduleRoot` comes from the setup above.

```powershell
$demoRepo = Join-Path ([IO.Path]::GetTempPath()) ('quietcli-demo-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $demoRepo | Out-Null
git init --quiet --initial-branch=main $demoRepo
if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }

Set-Content -LiteralPath (Join-Path $demoRepo 'app.txt') -Value 'version 1'
git -C $demoRepo add app.txt
if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
git -C $demoRepo -c user.name=QuietCli -c user.email=demo@example.invalid `
    -c commit.gpgsign=false -c core.hooksPath= `
    commit --quiet -m 'Initial demo'
if ($LASTEXITCODE -ne 0) { throw 'Demo commit failed.' }

Set-Content -LiteralPath (Join-Path $demoRepo 'app.txt') -Value 'version 2'
New-Item -ItemType Directory -Path (Join-Path $demoRepo 'notes') | Out-Null
Set-Content -LiteralPath (Join-Path $demoRepo 'notes/a.txt') -Value 'first note'
Set-Content -LiteralPath (Join-Path $demoRepo 'notes/b.txt') -Value 'second note'

$json = & (Join-Path $moduleRoot 'examples/Generated-GitOverview.ps1') `
    -Repository $demoRepo -MaxOutputBytes 2048
$json
```

In the returned envelope, `.Data` contains:

```json
{
  "Branch": "main",
  "Detached": false,
  "Changed": 1,
  "Untracked": 1,
  "Clean": false,
  "AnswerComplete": true
}
```

`Changed` counts **tracked status entries**, not modified lines. `Untracked` counts entries from `git status --untracked-files=normal`: the `notes/` directory counts as **one entry**, even though it contains two files. Ignored files are not counted. The companion handles NUL-delimited records and renames according to [Git's porcelain format](https://git-scm.com/docs/git-status).

### Use the result in your script

```powershell
$result = $json | ConvertFrom-Json -ErrorAction Stop
if ($result.Outcome -ne 'Success' -or
    !$result.Execution.AnalysisComplete -or
    $result.Truncation.Applied -or
    $null -eq $result.Data -or
    !$result.Data.AnswerComplete) {
    throw "Insufficient result: $($result.Outcome). Inspect Error and Truncation."
}

if ($result.Data.Clean) {
    'Repository is clean.'
} else {
    'Review needed: {0} changed entry/entries, {1} untracked.' -f `
        $result.Data.Changed, $result.Data.Untracked
}
```

For this case, the answer is: `Review needed: 1 changed entry/entries, 1 untracked.`

The observations are sequential and do not form an atomic snapshot. A repository can change between commands. With a detached HEAD, `Branch` is `null` and `Detached` is `true`; this is not an execution error.

You can reuse the JSON in a larger task: check its envelope before computing another decision or starting the next step.

## Use QuietCli with your AI agent

The [quiet-cli skill](skills/quiet-cli/SKILL.md) explains how to prepare or reuse a companion. Give the agent **the instruction file and the installed runtime path**. Downloading the skill alone does not provide the module.

Example request you can adapt:

```text
Read <module-path>/skills/quiet-cli/SKILL.md.
The runtime is <module-path>/FrenchExDev.QuietCli.PoSh.psd1.

In repository <project-path>, I want the branch, the counts of changed
and untracked entries, and a Boolean indicating whether it is clean.
Reuse examples/Generated-GitOverview.ps1 if its scope is suitable.
Run the companion locally and return a single JSON result,
with a total budget of 2048 bytes. Preserve failures, limits,
and the meaning of the counters. Do not modify the inspected repository.
```

Loading the module in `$PROFILE` makes its functions available in the relevant sessions. The agent still needs to choose and invoke a companion: QuietCli does not configure any automatic command interception hooks.

In this request, replace the paths in angle brackets with your absolute paths. For an older archive, use the manifest name actually imported during installation (`$moduleManifest`).

## Write your first companion

Here is a minimal version that answers one question: **what is the current branch?** It uses the [documented `git branch --show-current` behavior](https://git-scm.com/docs/git-branch). Run it after setup, or save it in a script that explicitly imports the manifest.

```powershell
$repository = $demoRepo # Or the absolute path to another Git repository.
Invoke-QuietTask -MaxOutputBytes 2048 -AsJson -ArgumentList @($repository) -ScriptBlock {
    param($repo)
    $branch = Invoke-QuietStep -Name 'branch' -ScriptBlock {
        Invoke-QuietCli -FilePath git -ArgumentList @('branch', '--show-current') `
            -WorkingDirectory $repo -Summary 'Current branch extracted.' -Parse {
                param($capture)
                $name = $capture.Stdout.TrimEnd("`r", "`n")
                [pscustomobject]@{
                    Branch = $(if ($name.Length) { $name } else { $null })
                    Detached = ($name.Length -eq 0)
                }
            }
    }
    if ($branch.Outcome -ne 'Success') { return }
    [pscustomobject]@{
        Branch = $branch.Data.Branch
        Detached = $branch.Data.Detached
        AnswerComplete = $true
    }
}
```

`Invoke-QuietStep` registers the result with the task, even when you assign it to a variable. After a failure, the script stops before producing a domain answer. The task preserves that failure in its final envelope. Assigning an `Invoke-QuietCli` call to a variable does not register it as a step: use `Invoke-QuietStep`.

The parser receives the local capture and returns **one object**; to return an array as a single value, use the unary comma (`return ,$items`). Never return the raw capture. In a streaming reducer, `-OnRecord` only updates state; `-Complete` produces the final object.

## Handle a noisy command

The [Generated-NoisyJob.ps1](examples/Generated-NoisyJob.ps1) companion runs preparation, then validation. A Python fixture produces events on stdout and diagnostics on stderr. The script consumes them locally, checks completion events, and aggregates both steps.

```powershell
$companion = Join-Path $moduleRoot 'examples/Generated-NoisyJob.ps1'
pwsh -NoLogo -NoProfile -File $companion `
    -Python python3 -Records 2000 -MaxOutputBytes 2048
```

Use `-Python python` or the absolute path to Python 3 if needed. For 2,000 items per step, the projection contains `Prepared: 2000`, `Validated: 2000`, and the counters for each step.

The [supplied measurement](verification/demo-measurements.json) reports **4,000 progress events and 4,000 diagnostics consumed**, followed by a final JSON document of **533 bytes**, excluding the newline. This observation was recorded with PowerShell 7.4.20; the size can vary, particularly with execution time. It does not measure total token or financial savings.

## The five public functions

| Function | Purpose | Useful parameters |
| --- | --- | --- |
| `Invoke-QuietCli` | Run a native program and analyze both streams. | `-FilePath`, `-ArgumentList`, `-WorkingDirectory`, `-Parse` or `-OnRecord` / `-State` / `-Complete`, `-TimeoutSeconds`. |
| `Invoke-QuietStep` | Register a result with the current task. | `-Name`, `-ScriptBlock`. Requires an active task. |
| `Invoke-QuietTask` | Compose steps and emit a final projection. | `-ScriptBlock`, `-ArgumentList`, `-MaxItems`, `-MaxOutputBytes`, `-AsJson`. |
| `New-QuietResult` | Build a bounded envelope with your own data. | `-Summary`, `-Outcome`, `-Data`, `-Execution`, `-ErrorInfo`. |
| `ConvertTo-QuietJson` | Serialize an envelope as compact JSON within the budget. | `-InputObject`, `-MaxOutputBytes`. |

The [runtime](src/QuietCli.psm1) defines the exact signatures. Pass native arguments as an array; the runtime forwards them without an implicit shell. For a script or shell syntax, choose the interpreter explicitly.

### Two reading modes

| Mode | Use case | Contract |
| --- | --- | --- |
| **Document**: `-Parse` | A JSON document or a small, complete output. | The parser receives the capture after execution. A capture exceeding the limit produces a `CaptureLimit` failure. |
| **Streaming**: `-OnRecord`, `-State`, `-Complete` | Many events, lines, or records. | The reducer maintains counters and a bounded sample. Lost records invalidate the analysis (`RecordLimit`). |

### Default limits

| Parameter | Default | Unit and scope |
| --- | --- | --- |
| `MaxOutputBytes` | `4096` | UTF-8 bytes for the JSON envelope; range `1024` to `65536`. |
| `MaxItems` | `20` | Projection values emitted by the task body. Does not limit each array nested inside `.Data`. |
| `TimeoutSeconds` | `600` | Seconds per native call. |
| `MaxCaptureCharacters` | `262144` | Capture characters in document mode. |
| `MaxRecordCharacters` | `65536` | Characters per record in streaming mode. |

The final budget must cover **the entire answer**, not twenty separately displayed outputs. Intermediate QuietCli objects also pass through their own budgets: data omitted at that stage cannot be recovered by increasing only the final budget. For large inputs, compute a smaller projection or use streaming.

## Read a result correctly

| Field | What it tells you |
| --- | --- |
| `SchemaVersion` | Envelope version: `1`. |
| `Summary` | Short execution summary. |
| `Outcome` | `Success`, `Failed`, `Timeout`, or `Unsupported`. |
| `Data` | Domain answer defined by the companion. |
| `Execution` | Exit code, duration, analysis status, and step counters depending on the context. |
| `Error` | Structured diagnostic, or `null`. |
| `Truncation` | The `Applied` flag and reasons for omissions or masking. |

Check **status**, **analysis completeness**, **the presence of domain facts**, and **omissions** together. `Success` does not guarantee that `.Data` answers your question. An unknown value remains `null`. For a composed task, `Execution.ExitCode` is `null`; the counters describe its steps.

| Situation | Interpretation and action |
| --- | --- |
| `Failed` / `NativeFailed` | The program returned an unaccepted exit code. Check the code, arguments, and selected diagnostics. |
| `Failed` / `ParserFailed` | The format or parser contract is invalid. Fix the analysis. |
| `Timeout` | The command did not finish before the deadline. Review the scope or timeout before running it again. |
| `CaptureLimit` / `RecordLimit` | The analysis does not have a complete source. Adjust the reading mode, scope, or limit. |
| `OutputBudget` | Delivery exceeded the budget; `.Data` may be `null`. Reduce the projection or explicitly increase the budget. |
| `SensitiveData` | The runtime masked recognized sensitive values. Check what remains usable. |

Composed tasks group incidents under `Error.Code = TaskFailed` and expose affected steps in `Error.Issues`. The runtime masks known secrets and applies field limits; also select useful diagnostics in your companions, because masking cannot identify every possible confidential value.

The envelope describes the domain result. A script that prints it may finish with process exit code `0` while reporting `Outcome: Failed`: callers must read the envelope. The test launcher explicitly defines its exit codes.

## QuietCli and RTK

The [RTK README](https://github.com/rtk-ai/rtk) offers a quick start, practical examples, and an explanation of savings. This QuietCli README follows that reading progression, with a workflow centered on companions.

| Need | RTK | QuietCli |
| --- | --- | --- |
| Reduce output from common tools | Filters and commands supplied by RTK. | Parser and projection written or reused in a companion. |
| Define a domain answer tailored to the request | Check the extension options in your RTK version. | `.Data` is freely defined and computed by your script. |
| Chain several observations | Depends on the configured workflow. | Local variables, conditions, and steps in `Invoke-QuietTask`. |
| Load the tool at startup | RTK-specific installation and integration. | `Import-Module` in the PowerShell profile; explicit companion invocation. |

To evaluate savings, compare equivalent tasks using the same tokenizer and expected answer. Include reading instructions, generating the companion, debugging it, and rerunning commands. Separate creation cost from reuse cost. A reduction in output bytes alone does not establish overall savings.

## Verify the installation

The runtime suite requires neither Python nor Git:

```powershell
pwsh -NoLogo -NoProfile -File (Join-Path $moduleRoot 'test/Invoke-Tests.ps1') -RuntimeOnly
```

For the full suite, install the prerequisites for your environment, then choose your Python executable:

```powershell
$testReport = Join-Path ([IO.Path]::GetTempPath()) 'quietcli-local-tests.json'
pwsh -NoLogo -NoProfile -File (Join-Path $moduleRoot 'test/Invoke-Tests.ps1') `
    -Python python3 -OutputPath $testReport
```

The launcher returns a bounded JSON report. Its exit code is `0` on success, `1` on failure, and `2` when a prerequisite is missing (`Unsupported`). Bash cases skipped on Windows are counted separately.

The retained reports, **dated October 14, 2026**, describe sources identified by their SHA-256 hashes:

| Recorded environment | Runtime | Integration | Report |
| --- | --- | --- | --- |
| Windows, PowerShell 7.6.6, Python 3.13.16 | 24 passed | 5 passed, 2 Bash cases skipped | [Windows](verification/windows-tests.json) |
| Debian 13, PowerShell 7.4.20, Python 3.13.5 | 24 passed | 7 passed | [Linux](verification/linux-tests.json) |

These reports are snapshots. They do not replace running the suite against your installed version. Checks cover native failures, timeouts, malformed output, limits, empty and singleton arrays, failure aggregation, and Git edge cases.

## Troubleshooting

| Symptom | Check or fix |
| --- | --- |
| "No valid module file was found" | Check the full path: **`FrenchExDev.QuietCli.PoSh.psd1`** in the current checkout, or `QuietCli.PoSh.psd1` in an older archive. |
| The module works here, but not in a new terminal | Check the QuietCli section in `$PROFILE.CurrentUserAllHosts` and start `pwsh` without `-NoProfile`. |
| It works in the terminal, but not in the VS Code PowerShell host | Check that the host uses PowerShell 7 and loads the shared profile; a host-specific profile may then modify the session. |
| The companion cannot find Git or Python | Check the process `PATH` and executable name. Use an absolute path if needed. |
| A downloaded script is blocked on Windows | Review its source and the effective policy with `Get-ExecutionPolicy -List`. If you trust the file and it is only marked as downloaded, use `Unblock-File -LiteralPath <file>`. |
| `.Data` is `null` | Read `Outcome`, `Error`, and `Truncation.Reasons`; look for `OutputBudget` in particular. |
| A failed step disappears from the summary | Wrap its call in `Invoke-QuietStep` inside `Invoke-QuietTask`. |
| A runtime change appears to be ignored | Start a fresh `pwsh -NoProfile` process: C# types already loaded remain in the session. |

## Sources and examples

| Resource | Contents |
| --- | --- |
| [Skill](skills/quiet-cli/SKILL.md) | Agent instructions and companion contracts. |
| [Manifest](FrenchExDev.QuietCli.PoSh.psd1) and [runtime](src/QuietCli.psm1) | Version, exports, and exact behavior. |
| [Native C# session](src/NativeSession.cs) | Execution and stream reading. |
| [PowerShell Git](examples/Generated-GitOverview.ps1) and [Bash Git](examples/generated-git-status.sh) | Repository inspection companions. |
| [Noisy task](examples/Generated-NoisyJob.ps1) | Streaming reduction and validation across two steps. |
| [Test launcher](test/Invoke-Tests.ps1) | Runtime and integration verification. |

When contributing parser changes, include cases for success, failure, invalid formats, and limits. Preserve the meaning of units, the scope analyzed, and the information needed for decisions in the companion contract.

Published under the [MIT license](LICENSE). Author: Stéphane Erard / FrenchExDev.
