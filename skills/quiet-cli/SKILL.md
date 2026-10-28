---
name: quiet-cli
description: Write documented PowerShell contracts that compute business results locally, record evidence and generate reusable per-executable modules with QuietCli V2.
---

# QuietCli V2

The AI owns command semantics. Read the installed help or official documentation before choosing native arguments, machine formats, business fields, scope and invariants. QuietCli owns execution, streams, task accounting, recording, replay and bounded delivery. PowerShell Core 7.6+ only.

1. Read the requested executable's documentation. Define the business object and independent success criteria.
2. Reuse an installed module only when its documented argument forms and scope match the request.
3. Otherwise write a factory file accepting one invocation hashtable and returning a fresh `New-QuietContract`. Declare source dependencies and documentation. Keep executable-specific parsing outside the engine.
4. Run `quiet -AsObject -ContractPath <file> [options] executable arguments`. Use `-Record` when retaining the documented computation and evidence is useful.
5. Inspect outcome, source/analysis/capture completeness and domain scope. A small delivery does not prove a correct or complete answer.
6. Keep local objects in variables. Deliver only through `Out-QuietResult` or `ConvertTo-QuietJson`; never print Capture, callbacks or Internal.
7. Read or replay recorded evidence before repeating a native command. Replay consumes captures and does not relaunch native calls through QuietCli.
8. For recurring work, supply explicit sources and independent assertions to `New-QuietModule`. Use one module per executable. Run `Test-QuietModule`, then explicitly `Install-QuietModule`. Generation and installation are separate operations.

A missing contract returns Unsupported without executing anything. RECORD does not discover a command by running it. Never infer a parser from one successful snapshot. Fixtures describe observed values; documentation and independent preparation establish meaning.

Document contracts use Parse; streaming contracts use OnOutput or OnBatch and explicit State/Complete. Execute contracts compose calls and return a final business object. Factories create fresh state on every call. A closure is portable only when its dependencies are reproduced from the declared source files and parameters.

The Git example uses documented porcelain v2 with NUL framing. It observes the installed Git version without a central version matrix. It covers `git status [-- pathspec...]`; other arguments require an explicit documented extension. Add an initial separator for a native literal separator: `quiet [options] -- git status -- path`.

Assigned calls are automatically accounted in tasks. Invoke-QuietStep is optional naming and never an excuse to lose failures. Unknown values stay null; distinguish exact totals from omitted previews.

Use bounded evidence reads: `Get-QuietRecord -Id <id> -Stream stderr -Lines 20`. Full objects requested with AsObject are local intermediates. A partial or lossy capture cannot certify replay. Secret masking can alter a fixture; retain those limitations.

Import the installed runtime explicitly in NoProfile sessions. Downloading this skill alone does not install it. The complete [README](../../README.md) documents settings, API examples, module generation, history and verification. The [Git factory](../../examples/contracts/Git.Status.ps1) is the executable documentation-first example.

Existing authorization still applies to every native command, installation, hook, file mutation and external publication. No hook is installed on import. Token counts describe command output, with profile/version identified; historical estimates and exact counts are separate. Do not claim speedups, reduced total agent cost, human validation or other-platform qualification from these local observations.
