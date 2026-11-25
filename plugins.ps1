# The plugin seam (docs/PLUGINS.md): finds a project's plugins, loads each in a module of its own, calls their hooks and
# merges what GetRun returns; and the provider, the one plugin that runs the coding tool (A provider). Dot-sourced by
# worker.ps1, setup.ps1 and tasks.ps1; only definitions. Checked by plugins.test.ps1.

# The version of docs/PLUGINS.md this base implements.
$PluginApi = 1

# Where a plugin of the project lives: a `source` that is a folder on the PC, else `plugins\<name>` of the install
# (setup.ps1 clones a git source or a listed plugin there).
function Get-PluginDir([string] $install, [string] $name, $entry) {
    $source = if ($entry) { [string]$entry.source } else { '' }
    if ($source -and $source -notmatch '^(https?|git|ssh)://|^git@' -and (Test-Path $source -PathType Container)) {
        return (Resolve-Path $source).Path
    }
    return Join-Path $install "plugins/$name"
}

# One plugin from its folder: its manifest, its hooks in a module of its own (so the helpers of two plugins never
# meet) and its settings from scriptorium.json. Throws for a missing folder or file and for another contract version.
function Import-Plugin([string] $dir, [string] $name, $entry) {
    $manifestFile = Join-Path $dir 'plugin.json'
    $file = Join-Path $dir 'plugin.ps1'
    if (-not (Test-Path $manifestFile) -or -not (Test-Path $file)) {
        throw "plugin ${name}: no plugin.json and plugin.ps1 in $dir; run setup.ps1 to install it"
    }
    $manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.api -ne [string]$PluginApi) {
        throw "plugin ${name}: written for contract version $($manifest.api), and Scriptorium has version $PluginApi"
    }
    $module = New-Module -ArgumentList $file -ScriptBlock {
        param($file)
        $Hooks = . $file
        Export-ModuleMember -Variable Hooks
    }
    $hooks = & $module { $Hooks }
    if ($hooks -isnot [hashtable]) {
        throw "plugin ${name}: plugin.ps1 must end with one hashtable of hooks"
    }
    $settings = @{}
    if ($entry) {
        foreach ($property in $entry.PSObject.Properties | Where-Object { $_.Name -ne 'source' }) {
            $settings[$property.Name] = $property.Value
        }
    }
    return @{
        Name = $name; Title = [string]$manifest.title; Version = [string]$manifest.version
        Description = [string]$manifest.description; Requires = @($manifest.requires | Where-Object { $_ })
        Dir = $dir; Hooks = $hooks; Settings = $settings
        # A provider (docs/PLUGINS.md, A provider), and the folder of the project where its skills go.
        Provider = [bool]$manifest.provider; Skills = [string]$manifest.skills
    }
}

# The project's plugins in the order scriptorium.json gives them; none for `"plugins": {}`.
function Import-Plugins([string] $install, $config) {
    $plugins = @()
    if ($config -and $config.plugins) {
        foreach ($property in $config.plugins.PSObject.Properties) {
            $plugins += , (Import-Plugin (Get-PluginDir $install $property.Name $property.Value) $property.Name $property.Value)
        }
    }
    return , $plugins
}

# The context of one call (docs/PLUGINS.md, The context). $machine: the main checkout's .queue/settings.json, whose
# `plugins.<name>` entry goes over the plugin's settings from scriptorium.json.
function New-HookContext($plugin, [string] $project, [string] $copy, $worker, $queueDir, $machine, [scriptblock] $report, [scriptblock] $log) {
    $settings = @{}
    foreach ($key in $plugin.Settings.Keys) {
        $settings[$key] = $plugin.Settings[$key]
    }
    $own = if ($machine -and $machine.plugins) { $machine.plugins.($plugin.Name) } else { $null }
    if ($own) {
        foreach ($property in $own.PSObject.Properties) {
            $settings[$property.Name] = $property.Value
        }
    }
    return @{
        Api = $PluginApi; Project = $project; Copy = $copy; Worker = $worker; QueueDir = $queueDir; Settings = $settings
        Report = $report; Log = $log
    }
}

# Calls one hook of every plugin that has it, in order, and returns their answers. A hook that throws stops the call
# with the plugin's name, the hook and the error. The same context fields for each plugin, with its own settings.
function Invoke-Hooks($plugins, [string] $hook, [string] $project, [string] $copy, $worker, $queueDir, $machine,
    [scriptblock] $report = { param($text) }, [scriptblock] $log = { param($text) }) {
    $answers = @()
    foreach ($plugin in @($plugins | Where-Object { $_ })) {
        $block = $plugin.Hooks[$hook]
        if (-not $block) {
            continue
        }
        $ctx = New-HookContext $plugin $project $copy $worker $queueDir $machine $report $log
        try {
            $answers += , (& $block $ctx)
        } catch {
            throw "plugin $($plugin.Name), ${hook}: $($_.Exception.Message)"
        }
    }
    return , $answers
}

# A disabled worker (docs/PLUGINS.md, Close): each plugin closes what Start opened, in each checkout. A hook that throws
# goes to $log, and the others still close.
function Close-Checkouts($plugins, [string[]] $checkouts, [string] $project, $worker, $queueDir, $machine, [scriptblock] $log) {
    foreach ($checkout in $checkouts) {
        foreach ($plugin in @($plugins | Where-Object { $_ })) {
            try {
                Invoke-Hooks @($plugin) 'Close' $project $checkout $worker $queueDir $machine $log $log | Out-Null
            } catch {
                & $log "$_"
            }
        }
    }
}

# GetRun's answers merged (docs/PLUGINS.md, The hooks): MCP servers and environment variables by name (a later plugin's
# wins), commands and tool rules as unions, prompts in order. @{ McpServers; Commands; AllowedTools; Prompt; Env }.
function Merge-RunAnswers($answers) {
    $servers = [ordered]@{}
    $commands = @()
    $tools = @()
    $prompts = @()
    $variables = [ordered]@{}
    foreach ($answer in @($answers | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        if ($answer.McpServers) {
            foreach ($key in @($answer.McpServers.Keys)) {
                $servers[$key] = $answer.McpServers[$key]
            }
        }
        if ($answer.Env) {
            foreach ($key in @($answer.Env.Keys)) {
                $variables[$key] = [string]$answer.Env[$key]
            }
        }
        $commands += @($answer.Commands | Where-Object { $_ })
        $tools += @($answer.AllowedTools | Where-Object { $_ })
        if ($answer.Prompt) {
            $prompts += ([string]$answer.Prompt).Trim()
        }
    }
    return @{ McpServers = $servers; Commands = @($commands | Select-Object -Unique); AllowedTools = @($tools | Select-Object -Unique)
        Prompt = $prompts -join ' '; Env = $variables }
}

# The commands a run may start without asking, each by how it starts (`git`, `unity command`): the base's git and gh,
# then scriptorium.json's `commands`, then the plugins'.
function Get-RunCommands($config, $merged) {
    return @(@('git', 'gh') + @($config.commands) + @($merged.Commands) | Where-Object { $_ } | Select-Object -Unique)
}

# The run's tool rules in the provider's own syntax, which the base hands on unread: scriptorium.json's `allowedTools`,
# then the plugins'.
function Get-RunTools($config, $merged) {
    return @(@($config.allowedTools) + @($merged.AllowedTools) | Where-Object { $_ } | Select-Object -Unique)
}

# The project's provider (docs/PLUGINS.md, A provider): the first of its plugins whose manifest says `provider`; $null
# when it has none.
# shortcut: one provider for a project; give an account its provider when a project runs two.
function Get-Provider($plugins) {
    return @($plugins | Where-Object { $_ -and $_.Provider }) | Select-Object -First 1
}

# The provider that Invoke-Provider and Read-Models (project.ps1) use from here on, and its windows (limits.ps1) where
# the script reckons a budget. $scope: the context fields of its calls, @{ Project; Copy; Worker; QueueDir; Machine (a
# script block that reads the PC's settings); Report; Log }.
function Set-Provider($plugin, [hashtable] $scope = @{}) {
    $script:Provider = $plugin
    $script:ProviderScope = $scope
    if (Get-Command Set-Windows -ErrorAction SilentlyContinue) {
        Set-Windows (Read-Models).windows
    }
}

# The provider's hooks that are features (docs/PLUGINS.md, A provider): every one but GetCommand and ReadRun.
$ProviderFeatures = @('ReadUsage', 'Probe', 'Compact', 'GetLogin', 'SignIn', 'ReadSignIn', 'SignOut', 'ReadStep', 'ReadEnd')

# Whether the provider has a hook: each one but GetCommand and ReadRun is a feature it may leave out.
function Test-ProviderHook([string] $hook) {
    return [bool]($script:Provider -and $script:Provider.Hooks[$hook])
}

# Calls one hook of the provider with the context of Set-Provider's scope and $fields over it (docs/PLUGINS.md, A
# provider). $null for a hook the provider does not have. A hook that throws stops the call with the plugin's name.
function Invoke-Provider([string] $hook, [hashtable] $fields = @{}) {
    if (-not (Test-ProviderHook $hook)) {
        return $null
    }
    $scope = $script:ProviderScope
    $silent = { param($text) }
    $ctx = New-HookContext $script:Provider ([string]$scope.Project) ([string]$scope.Copy) $scope.Worker $scope.QueueDir `
        $(if ($scope.Machine) { & $scope.Machine }) $(if ($scope.Report) { $scope.Report } else { $silent }) `
        $(if ($scope.Log) { $scope.Log } else { $silent })
    foreach ($key in $fields.Keys) {
        $ctx[$key] = $fields[$key]
    }
    try {
        return (& $script:Provider.Hooks[$hook] $ctx)
    } catch {
        throw "plugin $($script:Provider.Name), ${hook}: $($_.Exception.Message)"
    }
}
