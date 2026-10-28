# QuietCli V2 reading path

Read [README.md](README.md) for runtime use, direct contracts, RECORD, replay, modules, settings and evidence. The [quiet-cli skill](skills/quiet-cli/SKILL.md) defines the documentation-first authoring workflow.

The agent defines command semantics from documentation. The engine owns process mechanics and bounded delivery. Never add a CLI catalogue or argument/version matrix to src/. Executable-specific code belongs in explicit consumer contracts and generated modules.

Use PowerShell Core 7.6+ in the owned Linux container with --init. Native commands go through quiet. Keep local results in variables; never emit Capture or Internal. Run test/Invoke-Tests.ps1 -Analyze for validation and inspect its compact result and verification/v2-validation.json. Run the performance script only when measuring a relevant change, and distinguish recording/tokenization overhead from a general speed claim.

The C# native reader and SQLite adapter compile on import. Use a new PowerShell process after editing these sources. Native timeouts do not interrupt arbitrary synchronous PowerShell callback code; callbacks must return cooperatively.

A generated module uses a fresh source factory for each invocation. Declare all source dependencies. When a callback calls a helper function defined by a factory file, capture its CommandInfo in a freshly built closure or define it in a proper module scope; do not rely on a vanished caller scope.

The generated Git consumer and its ten independently asserted fixtures live beside this module. Generation and installation are separate, explicit operations. Preserve V1 history and original user changes while migrating.

## Command objectives

Every command submitted for execution must start with a visible PowerShell comment in French using this format:

```powershell
# Objectif : Expliquer le but concret de la commande et le résultat attendu.
```

Place the comment in the executed code, before any executable statement. A chat explanation does not replace this comment. Keep the objective concise and specific to the action.

This rule also applies to bootstrap commands, source reads and edits, searches, Git, builds, tests, native calls through quiet or pump, and host/container transport. When a block contains several distinct actions, put a specific objective comment immediately before each action. Scripts sent into a container must also begin with their own objective comment.
