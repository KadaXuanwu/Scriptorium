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

# Whether a plugin is in its folder: its manifest and its hooks file. A clone makes the folder before the files.
function Test-PluginInstalled([string] $dir) {
    return (Test-Path (Join-Path $dir 'plugin.json')) -and (Test-Path (Join-Path $dir 'plugin.ps1'))
}

# The plugins scriptorium.json names that are not installed yet (docs/PLUGINS.md, Where a plugin comes from): the
# owner added the name, and setup.ps1 has not cloned it. @{ Name; Dir; Watch }: `Watch` goes to Start-CodeWatch, so
# the script starts again when the plugin's files are there.
function Get-MissingPlugins([string] $install, $config) {
    $missing = @()
    if ($config -and $config.plugins) {
        foreach ($property in $config.plugins.PSObject.Properties) {
            $dir = Get-PluginDir $install $property.Name $property.Value
            if (-not (Test-PluginInstalled $dir)) {
                # The folder for its plugin.ps1, and the manifest: a restart may come between the two files.
                $missing += , @{ Name = $property.Name; Dir = $dir; Watch = @($dir, (Join-Path $dir 'plugin.json')) }
            }
        }
    }
    return , $missing
}

# What a script says while it waits for the plugins of Get-MissingPlugins: on a worker's card and in the logs.
function Get-MissingText($missing) {
    return "plugin $(@($missing | ForEach-Object { $_.Name }) -join ', ') not installed: run setup.ps1 for this project " +
        '(docs/PLUGINS.md, Where a plugin comes from). This script loads it by itself once it is there.'
}

# Checks a provider's models.json (docs/PLUGINS.md, models.json) when the provider loads, so a bad file stops the
# scripts with the file's name, not later with an unclear error. It parses, has `models`, gives each of the base's
# complexities ($BaseComplexities, project.ps1) a model, and gives each window `seconds` above 0. A key the base does
# not know is the provider's own.
function Test-ProviderModels([string] $name, [string] $file) {
    $where = "plugin ${name}: models.json"
    if (-not (Test-Path $file)) {
        throw "${where}: not found in $(Split-Path $file)"
    }
    try {
        $models = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "${where}: no JSON: $($_.Exception.Message)"
    }
    if (-not ($models -and $models.models)) {
        throw "${where}: no models"
    }
    foreach ($complexity in $BaseComplexities.Keys) {
        if (-not @($models.complexities.$complexity.models | Where-Object { $_ }).Count) {
            throw "${where}: the complexity $complexity has no model"
        }
    }
    foreach ($window in @(if ($models.windows) { $models.windows.PSObject.Properties })) {
        $seconds = $window.Value.seconds
        if ("$seconds" -notmatch '^\d+(\.\d+)?$' -or [double]$seconds -le 0) {
            throw "${where}: the window $($window.Name) needs seconds above 0, not '$seconds'"
        }
    }
}

# One plugin from its folder: its manifest, its hooks in a module of its own (so the helpers of two plugins never
# meet) and its settings from scriptorium.json. Throws for a missing folder or file, for another contract version and
# for a provider's models.json that does not hold (Test-ProviderModels).
function Import-Plugin([string] $dir, [string] $name, $entry) {
    $manifestFile = Join-Path $dir 'plugin.json'
    $file = Join-Path $dir 'plugin.ps1'
    if (-not (Test-PluginInstalled $dir)) {
        throw "plugin ${name}: no plugin.json and plugin.ps1 in $dir; run setup.ps1 to install it"
    }
    $manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.api -ne [string]$PluginApi) {
        throw "plugin ${name}: written for contract version $($manifest.api), and Scriptorium has version $PluginApi"
    }
    # An account names its provider by this name for the whole PC: a second name for one tool hides its accounts.
    if ([string]$manifest.name -cne $name) {
        throw "plugin ${name}: its plugin.json names it '$($manifest.name)', and its key in scriptorium.json and its folder must have that name"
    }
    if ($manifest.provider) {
        Test-ProviderModels $name (Join-Path $dir 'models.json')
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
        # A provider (docs/PLUGINS.md, A provider), the folder of the project where its skills go, and the picture
        # behind its account cards.
        Provider = [bool]$manifest.provider; Skills = [string]$manifest.skills; Card = [string]$manifest.card
    }
}

# The project's plugins in the order scriptorium.json gives them; none for `"plugins": {}`. -Installed: without the
# ones that are not installed yet (Get-MissingPlugins), for a script that waits for them; else such a plugin throws.
function Import-Plugins([string] $install, $config, [switch] $Installed) {
    $plugins = @()
    if ($config -and $config.plugins) {
        foreach ($property in $config.plugins.PSObject.Properties) {
            $dir = Get-PluginDir $install $property.Name $property.Value
            if ($Installed -and -not (Test-PluginInstalled $dir)) {
                continue
            }
            $plugins += , (Import-Plugin $dir $property.Name $property.Value)
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

# The project's default provider (docs/PLUGINS.md, A provider): the first of its plugins whose manifest says
# `provider`; $null when it has none. A worker in no account runs on it, and scriptorium.json's models are its.
# shortcut: the complexities' names and the ticket skill's folder are the default provider's alone; take every
# provider's when one brings a complexity of its own or the front desk runs on a second coding tool.
function Get-Provider($plugins) {
    return @($plugins | Where-Object { $_ -and $_.Provider }) | Select-Object -First 1
}

# Every provider a project's scripts can run (docs/PLUGINS.md, A provider): the project's own in scriptorium.json's
# order, the default first, then each in the install's plugins folder that the project does not name. A worker runs
# on its account's coding tool in any project of the PC, so a provider that one project installed serves them all.
# A folder there that does not load is no provider.
function Get-Providers([string] $install, $plugins) {
    $found = @($plugins | Where-Object { $_ -and $_.Provider })
    $named = @($plugins | Where-Object { $_ } | ForEach-Object { $_.Name })
    foreach ($dir in @(Get-ChildItem (Join-Path $install 'plugins') -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($named -contains $dir.Name) {
            continue
        }
        try {
            if ((Get-Content (Join-Path $dir.FullName 'plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json).provider) {
                $found += , (Import-Plugin $dir.FullName $dir.Name $null)
            }
        } catch {
        }
    }
    return , $found
}

# The provider of an account's entry among $providers (docs/QUEUE.md, Settings, `accounts.<name>.provider`): the one
# its `provider` names. An entry that names none (a PC from before an account had one), and no entry, is the first's:
# the project's default. $null for a coding tool these scripts do not have.
function Get-AccountProvider($entry, $providers) {
    $name = if ($entry) { [string]$entry.provider } else { '' }
    if (-not $name) {
        return @($providers | Where-Object { $_ }) | Select-Object -First 1
    }
    return @($providers | Where-Object { $_ -and $_.Name -eq $name }) | Select-Object -First 1
}

# The provider a worker runs on: its account's (docs/QUEUE.md, Accounts). A worker in no entry runs on the
# command-line login, which is the entry's with no login folder; on a PC with no such entry, the default provider's.
function Get-WorkerProvider($settings, [string] $worker, $providers) {
    $entries = @(if ($settings -and $settings.accounts) { $settings.accounts.PSObject.Properties })
    $entry = $entries | Where-Object { @($_.Value.uses) -contains "worker:$worker" } | Select-Object -First 1
    if (-not $entry) {
        $entry = $entries | Where-Object { -not $_.Value.configDir } | Select-Object -First 1
    }
    return Get-AccountProvider $(if ($entry) { $entry.Value }) $providers
}

# Each provider's windows by its folder, read once: a script restarts when a models.json changes (Start-CodeWatch).
$script:WindowsOf = @{}
# The providers a script serves when it serves more than one (Set-Providers): the page's server.
$script:Providers = @()

# The provider that Invoke-Provider and Read-Models (project.ps1) use from here on, and its windows (limits.ps1) where
# the script reckons a budget. $scope: the context fields of its calls, @{ Project; Copy; Worker; QueueDir; Machine (a
# script block that reads the PC's settings); Report; Log }.
function Set-Provider($plugin, [hashtable] $scope = @{}) {
    $script:Provider = $plugin
    $script:ProviderScope = $scope
    if (Get-Command Set-Windows -ErrorAction SilentlyContinue) {
        $key = if ($plugin) { [string]$plugin.Dir } else { '' }
        if (-not $script:WindowsOf.ContainsKey($key)) {
            $script:WindowsOf[$key] = (Read-Models).windows
        }
        Set-Windows $script:WindowsOf[$key]
    }
}

# The providers of a script that serves the accounts and the workers of every coding tool (Get-Providers' list): the
# first is set, as the project's default.
function Set-Providers($providers, [hashtable] $scope = @{}) {
    $script:Providers = @($providers | Where-Object { $_ })
    Set-Provider $(if ($script:Providers.Count) { $script:Providers[0] }) $scope
}

# The providers a script serves: the list of Set-Providers, else its one provider. One list, also of one provider:
# assign it or pass it on, and put it in parentheses before a pipe.
function Get-KnownProviders {
    if ($script:Providers.Count) {
        return , $script:Providers
    }
    return , @($script:Provider | Where-Object { $_ })
}

# Sets another of the script's providers, with the same scope; nothing for the one that is set already, and for none.
# The code that follows reads that provider's models, windows and hooks, so each entry of the server (a request, a
# snapshot) sets the default first.
function Select-Provider($plugin) {
    if ($plugin -and (-not $script:Provider -or $script:Provider.Name -ne $plugin.Name)) {
        Set-Provider $plugin $script:ProviderScope
    }
}

# Runs a script block with a provider set (Select-Provider) and returns what it gives, then sets the one from before
# again. The block reads the caller's variables; these three names are its own.
function Use-Provider($providerToUse, [scriptblock] $blockToRun) {
    $providerBefore = $script:Provider
    Select-Provider $providerToUse
    try {
        return (& $blockToRun)
    } finally {
        Select-Provider $providerBefore
    }
}

# The provider's hooks that are features (docs/PLUGINS.md, A provider): every one but GetCommand and ReadRun.
$ProviderFeatures = @('ReadUsage', 'Probe', 'Compact', 'GetLogin', 'SignIn', 'ReadSignIn', 'SignOut', 'ReadStep', 'ReadEnd')

# Whether the provider has a hook: each one but GetCommand and ReadRun is a feature it may leave out. 'Probe' is yes for
# either form of a probe: GetProbe with ReadProbe, or the older Probe (Invoke-ProviderProbe). 'Compact' the same, for
# GetCompact with ReadCompact or the older Compact (Invoke-ProviderCompact).
function Test-ProviderHook([string] $hook) {
    if (-not $script:Provider) {
        return $false
    }
    $hooks = $script:Provider.Hooks
    if (($hook -eq 'Probe' -and $hooks.GetProbe -and $hooks.ReadProbe) -or ($hook -eq 'Compact' -and $hooks.GetCompact -and $hooks.ReadCompact)) {
        return $true
    }
    return [bool]$hooks[$hook]
}

# Calls one hook of the provider with the context of Set-Provider's scope and $fields over it (docs/PLUGINS.md, A
# provider). $null for a hook the provider does not have. A hook that throws stops the call with the plugin's name.
function Invoke-Provider([string] $hook, [hashtable] $fields = @{}) {
    if (-not ($script:Provider -and $script:Provider.Hooks[$hook])) {
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

# Runs a command that a provider gave (@{ FilePath; Arguments; Env }, as GetCommand gives one) in $dir, with nothing to
# read on its input. It sets Env for the process (a variable with no value is taken away) and puts the old values back.
# After $seconds it ends the process and every process it started. @{ Text: what the process printed; Errors: what it
# wrote to its errors; Ended: it ended in time }.
function Invoke-ProviderCommand($command, [string] $dir, [int] $seconds) {
    $variables = if ($command.Env) { $command.Env } else { @{} }
    $previous = @{}
    $inFile = [IO.Path]::GetTempFileName()
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        foreach ($name in @($variables.Keys)) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $(if ($null -ne $variables[$name]) { [string]$variables[$name] }))
        }
        $start = @{ FilePath = $command.FilePath; WorkingDirectory = $dir; NoNewWindow = $true; PassThru = $true
            RedirectStandardInput = $inFile; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile }
        # Start-Process refuses an empty list.
        $arguments = @($command.Arguments | Where-Object { $null -ne $_ })
        if ($arguments.Count) {
            $start.ArgumentList = $arguments
        }
        $process = Start-Process @start
        $ended = $process.WaitForExit($seconds * 1000)
        if (-not $ended) {
            Stop-ProcessTree $process.Id
            # Windows keeps the output file locked until the process is gone.
            [void]$process.WaitForExit(5000)
        }
        $text = ''
        $errors = ''
        try {
            $text = [IO.File]::ReadAllText($outFile)
            $errors = [IO.File]::ReadAllText($errFile)
        } catch {
        }
        return @{ Text = $text; Errors = $errors; Ended = $ended }
    } finally {
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
        Remove-Item $inFile, $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

# The time limit of a probe (docs/PLUGINS.md, GetProbe): a worker probes while it holds the lock that gives out
# tickets, and the page's server on its only thread.
$ProbeSeconds = 60

# The provider's probe (docs/PLUGINS.md, GetProbe): @{ Usage; Answered; Kind; Text } as the hooks give it, $null for a
# provider with none. GetProbe's command runs here with the time limit, and a probe that passes it throws. The older
# Probe hook runs the tool itself, with no time limit.
function Invoke-ProviderProbe([string] $login, [string] $dir) {
    $fields = @{ Login = $login; Dir = $dir }
    if (-not ($script:Provider -and $script:Provider.Hooks.GetProbe -and $script:Provider.Hooks.ReadProbe)) {
        return Invoke-Provider 'Probe' $fields
    }
    $printed = Invoke-ProviderCommand (Invoke-Provider 'GetProbe' $fields) $dir $ProbeSeconds
    if (-not $printed.Ended) {
        throw "plugin $($script:Provider.Name), GetProbe: no end after $ProbeSeconds seconds, stopped"
    }
    return Invoke-Provider 'ReadProbe' @{ Text = $printed.Text }
}

# The time limit of a compaction (docs/PLUGINS.md, GetCompact).
$CompactSeconds = 600

# Compacts the session $session of a run where the provider can (docs/PLUGINS.md, GetCompact): the line for the
# worker's log, $null for a provider that cannot. $run: what the run started from (GetCommand's Run). The tool's output
# goes to the file $log, and what it wrote to its errors to "$log.err". A compaction that failed, passed its time limit
# or threw gives a line too: the session then resumes whole.
function Invoke-ProviderCompact($run, [string] $session, [string] $log) {
    if (-not (Test-ProviderHook 'Compact')) {
        return $null
    }
    $held = @{}
    foreach ($key in @($run.Keys)) {
        $held[$key] = $run[$key]
    }
    $held.Session = $session
    $fields = @{ Copy = $run.Dir; Run = $held }
    try {
        if (-not ($script:Provider.Hooks.GetCompact -and $script:Provider.Hooks.ReadCompact)) {
            # The older Compact runs the tool itself, and its Log is the file for the tool's output.
            $fields.Log = $log
            return "compaction: $(Invoke-Provider 'Compact' $fields) Log: $log"
        }
        $printed = Invoke-ProviderCommand (Invoke-Provider 'GetCompact' $fields) $run.Dir $CompactSeconds
        [IO.File]::WriteAllText($log, $printed.Text)
        if ($printed.Errors) {
            [IO.File]::WriteAllText("$log.err", $printed.Errors)
        }
        $line = if (-not $printed.Ended) {
            "no end after $($CompactSeconds / 60) minutes, stopped; the session resumes whole."
        } else {
            Invoke-Provider 'ReadCompact' @{ Text = $printed.Text }
        }
        if (-not $line) {
            $line = 'failed; the session resumes whole.'
        }
        return "compaction: $line Log: $log"
    } catch {
        return "compaction error: $_"
    }
}
