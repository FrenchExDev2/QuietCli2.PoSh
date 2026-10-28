$script:QuietLinePumpOptions=$null
function quiet {
    $call = ConvertFrom-QuietLineCommandLine $args $MyInvocation.Statement $MyInvocation.MyCommand.Name
    Invoke-QuietPump @call
}
function pump {
    # Command-line form of Invoke-QuietPump: options first, then the command and its arguments, passed verbatim. A simple
    # function receives native options such as -c, -o or -v unbound, where an advanced function would claim them.
    $call = ConvertFrom-QuietLineCommandLine $args $MyInvocation.Statement $MyInvocation.MyCommand.Name
    Invoke-QuietPump @call
}

function Get-QuietLinePumpOption {
    # Invoke-QuietPump parameters accepted before the command, mapped to whether each one is a switch. Read once per session:
    # command metadata costs tens of milliseconds on every pump call.
    if ($null -eq $script:QuietLinePumpOptions) {
        $excluded = @('Command','ArgumentList') + @([Management.Automation.Cmdlet]::CommonParameters) + @([Management.Automation.Cmdlet]::OptionalCommonParameters)
        $options = @{}
        foreach ($parameter in (Get-Command Invoke-QuietPump -CommandType Function).Parameters.Values) {
            if ($parameter.Name -notin $excluded) { $options[$parameter.Name] = $parameter.SwitchParameter }
        }
        $script:QuietLinePumpOptions = $options
    }
    return $script:QuietLinePumpOptions
}

function Test-QuietLineParameterToken {
    # PowerShell marks the $args entries written as -name tokens; quoted strings and values are never options.
    param([object]$Value)
    return $Value -is [string] -and $null -ne $Value.PSObject.Properties['<CommandParameterName>']
}

function ConvertFrom-QuietLineCommandLine {
    # Parameter tokens before the command are Invoke-QuietPump options, by exact name; every entry after the command is a
    # native argument. PowerShell splits "-name:value" into two entries, which are joined again.
    param([object[]]$Arguments, [string]$Statement, [string]$EntryPoint = 'quiet')
    $usage = "Usage: $EntryPoint [options] <command> [arguments]."
    $options = Get-QuietLinePumpOption
    $call = @{}; $index = 0
    while ($index -lt $Arguments.Count -and (Test-QuietLineParameterToken $Arguments[$index])) {
        $token = [string]$Arguments[$index]; $index++
        $name = $token.Substring(1).TrimEnd(':')
        if (!$options.ContainsKey($name)) { throw "Unknown $EntryPoint option '$token'. $usage" }
        if ($options[$name] -and !$token.EndsWith(':')) { $call[$name] = $true; continue }
        if ($index -eq $Arguments.Count) { throw "Missing value for $EntryPoint option '$token'. $usage" }
        $call[$name] = $Arguments[$index]; $index++
    }
    if ($index -eq $Arguments.Count) { throw "Missing command. $usage" }
    $call.Command = [string]$Arguments[$index]
    $native = [Collections.Generic.List[string]]::new()
    for ($index++; $index -lt $Arguments.Count; $index++) {
        $value = $Arguments[$index]
        if ($value -is [scriptblock] -or $value -is [Collections.IDictionary]) { throw "$EntryPoint options precede the command; a script block or dictionary is not a native argument. $usage" }
        if ((Test-QuietLineParameterToken $value) -and $value.EndsWith(':') -and $index+1 -lt $Arguments.Count) { $index++; $native.Add($value + $Arguments[$index]); continue }
        foreach ($item in @($value)) { if ($null -ne $item) { $native.Add([string]$item) } }
    }
    $call.ArgumentList = $native.ToArray()
    Assert-QuietLineSeparator $Statement $options $EntryPoint
    return $call
}

function Get-QuietLineElementKind {
    param([object]$Element)
    if ($Element -is [Management.Automation.Language.CommandParameterAst]) { return $(if ($Element.ParameterName -eq '-') { 'Separator' } else { 'Option' }) }
    if ($Element -is [Management.Automation.Language.VariableExpressionAst] -and $Element.Splatted) { return 'Splat' }
    return 'Value'
}

function Assert-QuietLineSeparator {
    # PowerShell removes the first -- of a function call before pump receives its arguments. Before the command it
    # only ends the options; after the command it was a native argument, which cannot be restored.
    param([string]$Statement, [hashtable]$Options, [string]$EntryPoint = 'quiet')
    $ast = [Management.Automation.Language.Parser]::ParseInput($Statement, [ref]$null, [ref]$null)
    # A pump call inside a script block of this statement (such as a callback) is checked when it runs.
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '(^|\\)(?:pump|quiet)$' }, $false)
    foreach ($command in $commands) {
        $elements = $command.CommandElements
        $index = 1
        while ($index -lt $elements.Count -and (Get-QuietLineElementKind $elements[$index]) -in @('Option','Splat')) {
            $element = $elements[$index]; $index++
            if ((Get-QuietLineElementKind $element) -eq 'Option' -and !$element.Argument -and !$Options[$element.ParameterName]) { $index++ }
        }
        # The options end at the separator or at the command; a separator after the command was removed from it.
        for ($index++; $index -lt $elements.Count; $index++) {
            if ((Get-QuietLineElementKind $elements[$index]) -eq 'Separator') {
                throw "PowerShell removed the first '--' of this command line, which followed the command. Write one before the command as well: $EntryPoint [options] -- <command> [arguments]."
            }
        }
    }
}
