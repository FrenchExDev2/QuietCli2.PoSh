---
name: quiet-cli
description: Write or reuse local companion scripts that run CLIs, compute the requested facts and return one bounded JSON result. Use for verbose commands, streaming jobs and tasks that combine several observations locally.
---

# Quiet CLI

The AI writes the program that answers the question: commands, arguments, parsers, counters, conditions and final projection. QuietCli handles native execution, streams and the result envelope. It does not decide which facts answer the user's question.

An already short and sufficient command may be called directly. Use a companion when local analysis, composition or reusable domain logic adds value. Preserve the user's scope, intended effects and authorization; this skill does not authorize installation, network access or publication.

## Dependencies and distribution

Use **PowerShell 7.4+ Core**. The PowerShell runtime has no OutputPumps registry, DevPoSh or third-party module dependency. Git is required for the Git examples. The native noisy-job example also needs a Python interpreter; the alternative container example needs Podman and an explicitly selected, already available image with Python.

Obtain the complete [QuietCli ZIP](https://github.com/FrenchExDev/FrenchExDev/raw/refs/heads/develop/PoSh/FrenchExDev/FrenchExDev.QuietCli.PoSh/downloads/QuietCli.zip), or use the [module source tree](https://github.com/FrenchExDev/FrenchExDev/tree/develop/PoSh/FrenchExDev/FrenchExDev.QuietCli.PoSh). The ZIP contains the module, this skill, examples, fixtures and the verification launcher. The GitHub branch is moving; retain the downloaded `package-manifest.json` to identify files by SHA-256.

This document contains the agent instructions. Downloading `SKILL.md` alone does not install the runtime. Set `$moduleRoot` to the extracted `QuietCli` directory or an existing module checkout. If this file remains in its original tree, that directory is two levels above `skills/quiet-cli/`. If the skill folder was installed elsewhere, pass the module path explicitly; do not infer that its parent contains the runtime.

```powershell
$moduleRoot = 'C:/tools/QuietCli'
Import-Module (Join-Path $moduleRoot 'QuietCli.PoSh.psd1') -ErrorAction Stop
```

All relative module links below resolve inside the complete ZIP and source tree. There are no separate skill-local `scripts/` or `references/` dependencies.

## Define the answer before execution

1. Specify the required properties, units, scope and evidence for a sufficient answer. Unknown values are `null`.
2. Verify arguments and machine formats in the installed help or official documentation. Record the relevant source in reusable code. Narrow the native command when doing so preserves the question's meaning.
3. Write or reuse a companion. Pass native arguments as an array and set `WorkingDirectory`; avoid shell-string concatenation, `eval` and `Invoke-Expression`.
4. Parse and calculate locally. Capture both streams without displaying raw output or progress. Prefer documented JSON, NDJSON or delimited records.
5. Return one bounded JSON document. Check its status, completeness and omissions before using the domain data. Do not automatically rerun commands, especially operations with effects.

## Result contract

The envelope contains `SchemaVersion`, `Summary`, `Outcome`, `Data`, `Execution`, `Error` and `Truncation`. `Outcome` is `Success`, `Failed`, `Timeout` or `Unsupported`. `.Data` is any serializable value: object, array, dictionary, scalar or `null`.

Keep these questions separate:

- Did the runtime finish analyzing the process output? Inspect `Execution.AnalysisComplete` and `Outcome`.
- Does the calculation answer the requested domain question? Add `AnswerComplete`, `CountExact` or an explicit `Scope` when useful.
- Which facts were transmitted? Inspect `Truncation.Applied`, its `Reasons` and `.Data` itself.

An exact count may coexist with omitted examples. A final budget may remove `.Data` even when process analysis succeeded. An incomplete search does not establish a zero count. Never infer completeness from `Success` alone.

The default final limit is **4096 UTF-8 bytes**, not tokens. Use **2048 bytes** for the examples here. Capture and record limits are separate character limits; a truncated JSON prefix is not a complete document. Keep diagnostic selection bounded and sanitize known secrets before returning them.

## Write a task

Use the five public functions defined by the [root manifest](../../FrenchExDev.QuietCli.PoSh.psd1): `Invoke-QuietCli`, `New-QuietResult`, `Invoke-QuietStep`, `Invoke-QuietTask` and `ConvertTo-QuietJson`. The [implementation](../../src/QuietCli.psm1) defines the exact parameters and limit behavior.

This small example obtains the current branch. Empty successful output denotes detached HEAD; the official [Git branch documentation](https://git-scm.com/docs/git-branch) defines `--show-current`.

```powershell
$repository = 'C:/code/my-project'
Invoke-QuietTask -MaxOutputBytes 2048 -AsJson -ArgumentList @($repository) -ScriptBlock {
    param($repo)
    $branch = Invoke-QuietStep -Name branch -ScriptBlock {
        Invoke-QuietCli -FilePath git -ArgumentList @('branch', '--show-current') `
            -WorkingDirectory $repo -Summary 'Current branch extracted.' -Parse {
                param($capture)
                $name = $capture.Stdout.Trim()
                [pscustomobject]@{ Branch = $name; Detached = ($name.Length -eq 0) }
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

For repository cleanliness, inspect and reuse [Generated-GitOverview.ps1](../../examples/Generated-GitOverview.ps1). It counts tracked changes and untracked entries using `git status --porcelain=v1 -z --untracked-files=normal`, handles the second path in rename records and reports detached state. Under `normal`, untracked directories can be grouped into one entry; these are entry counts, not recursive file totals. See the official [Git status grammar](https://git-scm.com/docs/git-status).

```powershell
& (Join-Path $moduleRoot 'examples/Generated-GitOverview.ps1') `
    -Repository $repository -MaxOutputBytes 2048
```

## Compose and reuse

Record each locally consumed execution with `Invoke-QuietStep` inside `Invoke-QuietTask`, then emit one final domain projection under a common budget. This keeps a consumed failed step visible in the aggregate. Multiple independently bounded calls do not create a common final budget.

When a child companion emits JSON, successful process execution and successful JSON decoding do not certify the operation described by that JSON. Record and check the inner envelope before reading its `.Data`. The supplied [Invoke-RepositoryDecision.ps1](../../examples/Invoke-RepositoryDecision.ps1) does this and combines the overview with a separately obtained commit identifier. These are sequential observations, not an atomic repository snapshot.

```powershell
& (Join-Path $moduleRoot 'examples/Invoke-RepositoryDecision.ps1') `
    -Repository $repository -QuietCliRoot $moduleRoot -MaxOutputBytes 2048
```

## Stream a noisy job

Use `State`, `OnRecord` and `Complete` to reduce records progressively into bounded state. Distinguish stdout domain events from stderr diagnostics. Require completion evidence and consistency between observed and reported totals; exit code zero alone is insufficient. Oversized records or incomplete capture must remain visible as failures or incomplete answers.

The supplied [Generated-NoisyJob.ps1](../../examples/Generated-NoisyJob.ps1) runs the [Python fixture](../../fixtures/noisy-job.py) in two stages:

```powershell
& (Join-Path $moduleRoot 'examples/Generated-NoisyJob.ps1') `
    -Python python3 -Records 2000 -MaxOutputBytes 2048
```

If host Python is unavailable, [Invoke-NoisyJobContainer.ps1](../../examples/Invoke-NoisyJobContainer.ps1) uses an explicitly selected existing image, `--pull=never`, disabled networking and only the fixture directory mounted read-only. Verify the image and permissions first. Report this as an execution adaptation; it is not a run of the unchanged native Python companion.

## Verify the actual distribution

Run [scripts/Invoke-Examples.ps1](../../scripts/Invoke-Examples.ps1) against the module you will distribute. It creates temporary fixtures, checks successful and failed execution, malformed data, timeouts, internal limits, final budgets, unknowns, Git semantics, reuse and streaming, then writes a structured report. Select the Python executable explicitly, or pass `PythonImage` for the documented offline adaptation.

```powershell
& (Join-Path $moduleRoot 'scripts/Invoke-Examples.ps1') `
    -QuietCliRoot $moduleRoot -Python python3
```

For a new parser, add cases that establish its domain semantics and meaningful failure boundaries. Record versions and limits with observed results. A syntax check does not prove the calculation is correct; a small output does not prove a total cost, speed or token improvement.
