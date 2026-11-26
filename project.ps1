# The project a script works on: its main checkout and its scriptorium.json (docs/CONFIG.md). Dot-sourced by the
# scripts that take -Project and by their tests; only definitions.

. (Join-Path $PSScriptRoot 'pc.ps1')

# The main checkout's full path, as every task and process match writes it.
function Resolve-Project([string] $Project) {
    return (Resolve-Path $Project).Path.TrimEnd('\', '/')
}

# The project's scriptorium.json with its defaults: port 8770, no repos, no extra commands or tools, no plugins. Throws for a
# missing file or a name that is not letters, digits and hyphens.
function Read-Project([string] $Project) {
    $file = Join-Path $Project 'scriptorium.json'
    if (-not (Test-Path $file)) {
        throw "$Project has no scriptorium.json: run setup.ps1 -Project `"$Project`""
    }
    $config = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$config.name -notmatch '^[A-Za-z0-9-]+$') {
        throw "scriptorium.json: name takes letters, digits and hyphens, not '$($config.name)'"
    }
    $defaults = @{ port = 8770; repos = @(); commands = @(); allowedTools = @(); plugins = [pscustomobject]@{} }
    foreach ($key in $defaults.Keys) {
        if ($null -eq $config.$key) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }
    return $config
}

# The base's ticket complexities (docs/QUEUE.md, Models): what each means. The provider gives each its models.
$BaseComplexities = [ordered]@{
    low = 'Clear what to do: a doc, a number, a rename, more of a pattern'
    medium = 'Judgement within known patterns: a feature or a bug in one part'
    high = 'Hard to get right: core rules, work across parts, a bug nobody can explain'
    design = 'The worker finds the shape of the solution, and the choice stays'
}

# The provider's model list (docs/PLUGINS.md, A provider: its models.json), read again at each use so an edit applies
# at once. With no provider (plugins.ps1, Set-Provider): a list with no model, so the page still shows the queue.
function Read-Models {
    if (-not $script:Provider) {
        return [pscustomobject]@{ models = [pscustomobject]@{}; efforts = @(); complexities = [pscustomobject]@{} }
    }
    return Get-Content (Join-Path $script:Provider.Dir 'models.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

# The names of the project's own complexities for a provider: the ones scriptorium.json ($config, as Get-ProviderConfig
# gives it to that provider) adds to the base's and to the provider's own.
function Get-OwnComplexities($models, $config) {
    $base = @($BaseComplexities.Keys) + @($models.complexities.PSObject.Properties | ForEach-Object { $_.Name })
    return @(if ($config -and $config.complexities) { $config.complexities.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $base -notcontains $_ } })
}

# The ticket complexities (docs/CONFIG.md, Complexities), the one list every script and the page read: the base's with
# the provider's models.json over them, and scriptorium.json's `complexities` over those, in this order: low, medium,
# high, the provider's and the project's own, design. Each
# @{ name; description; own; models; base; advisor; advisorFallback; baseAdvisor; baseFallback; compactAt }; `own`
# marks a complexity of the project's own. Such a
# complexity needs a description; with no models it runs on medium's. $settings: the owner's picks of one worker
# (Get-WorkerMapping, `picks`), in the form `complexities.<name>` = @{ model; advisor; advisorFallback; compactAt }.
# The model picked there is the complexity's one candidate, and `base` is the first
# candidate without that pick. The picked advisor switch and fallback effort
# go over the files' too, and `baseAdvisor` and `baseFallback` keep the files' values. Its compact
# size (docs/CONFIG.md, The compact size) is the picked one, else
# its own in scriptorium.json, else the project's, else models.json's; 0 with a provider that has none. Throws for a
# missing description, a name that is no label or a compact size out of range.
function Get-Complexities($models, $config, $settings) {
    $range = @($models.compactRange)
    $compactAt = if ($config -and $null -ne $config.compactAt) { $config.compactAt } else { $models.compactAt }
    $compactAt = if ($null -ne $compactAt) { ConvertTo-CompactAt $compactAt 'compactAt' $range } else { 0 }
    $paged = if ($settings -and $settings.complexities) { $settings.complexities } else { [pscustomobject]@{} }
    $base = @($BaseComplexities.Keys) + @($models.complexities.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { -not $BaseComplexities.Contains($_) })
    $changes = if ($config -and $config.complexities) { $config.complexities } else { [pscustomobject]@{} }
    $own = @(Get-OwnComplexities $models $config)
    $names = @($base | Where-Object { $_ -ne 'design' }) + $own + @($base | Where-Object { $_ -eq 'design' })
    $list = @()
    foreach ($name in $names) {
        if ($name -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "complexity '$name': lower-case letters, digits and hyphens only"
        }
        $entry = @{ name = $name; description = [string]$BaseComplexities[$name]; own = ($own -contains $name); models = @(); base = ''; advisor = $false; advisorFallback = ''; compactAt = $compactAt }
        foreach ($source in @($models.complexities.$name, $changes.$name)) {
            if (-not $source) {
                continue
            }
            if ($source.description) {
                $entry.description = [string]$source.description
            }
            if ($source.models) {
                $entry.models = @($source.models | ForEach-Object { [string]$_ })
            }
            if ($null -ne $source.advisor) {
                $entry.advisor = [bool]$source.advisor
            }
            if ($source.advisorFallback) {
                $entry.advisorFallback = [string]$source.advisorFallback
            }
            if ($null -ne $source.compactAt) {
                $entry.compactAt = ConvertTo-CompactAt $source.compactAt "complexity '$name'" $range
            }
        }
        $entry.baseAdvisor = $entry.advisor
        $entry.baseFallback = $entry.advisorFallback
        if ($paged.$name -and $null -ne $paged.$name.compactAt) {
            $entry.compactAt = ConvertTo-CompactAt $paged.$name.compactAt "settings.json, complexity '$name'" $range
        }
        # Not a truth test: the owner's off and '' (no other effort) must go over a true and an effort of the files.
        if ($paged.$name -and $null -ne $paged.$name.advisor) {
            $entry.advisor = [bool]$paged.$name.advisor
        }
        if ($paged.$name -and $null -ne $paged.$name.advisorFallback) {
            $entry.advisorFallback = [string]$paged.$name.advisorFallback
        }
        if (-not $entry.description) {
            throw "complexity '$name' in scriptorium.json needs a description"
        }
        if ($entry.models.Count -eq 0) {
            $entry.models = @(($list | Where-Object { $_.name -eq 'medium' } | Select-Object -First 1).models)
        }
        $entry.base = [string]$entry.models[0]
        if ($paged.$name -and $paged.$name.model) {
            $entry.models = @([string]$paged.$name.model)
        }
        $list += , $entry
    }
    # The list unrolled, one complexity at a time, so a pipe or a foreach sees each: it is never empty.
    return $list
}

# A worker's own mapping for a coding tool in the settings (`workers.<id>.mapping.<tool>`, the PC's); $null without one.
function Get-MappingEntry($settings, [string] $worker, [string] $tool) {
    if (-not $tool -or -not $settings -or -not $settings.workers -or -not $settings.workers.$worker -or -not $settings.workers.$worker.mapping) {
        return $null
    }
    return $settings.workers.$worker.mapping.$tool
}

# A worker's mapping (docs/QUEUE.md, A worker's mapping): the owner's picks for the worker's runs on the coding tool
# named $tool (a provider plugin's name), which the worker's card sets. Each worker has one for each tool it was on, so a
# worker that goes back to a tool finds its picks again. `follows` in it names another worker whose mapping this one
# uses, over any number of workers: the picks are those of the last worker of the chain. A chain that comes back to a
# worker it passed ends there, so a loop that a hand edit made does not hang a script.
# A complexity of the project's own ($own: Get-OwnComplexities) follows only a worker of this project ($here: the
# numbers of its workers): the last worker of a chain in another project has no row of it to set, so the worker's own
# pick counts.
# Returns @{ picks; follows; end; kept }: `picks` in the form Get-Complexities and Get-AdvisorRule take as settings
# (`complexities`, `advisor`); `follows`, the worker it follows ('' for none); `end`, the last worker of the chain (the
# worker itself without a link); `kept`, the complexities that are the worker's own though it follows.
function Get-WorkerMapping($settings, [string] $worker, [string] $tool, [string[]] $own = @(), [string[]] $here = @()) {
    $mine = Get-MappingEntry $settings $worker $tool
    $end = $worker
    $seen = @($worker)
    while ($true) {
        $entry = Get-MappingEntry $settings $end $tool
        $next = if ($entry) { [string]$entry.follows } else { '' }
        if (-not $next -or $seen -contains $next) {
            break
        }
        $seen += $next
        $end = $next
    }
    $linked = $end -ne $worker
    $source = Get-MappingEntry $settings $end $tool
    # Not a null name: a caller that passes a function's empty list on passes $null.
    $kept = @(if ($linked -and $here -notcontains $end) { $own | Where-Object { $_ } })
    $complexities = [pscustomobject]@{}
    foreach ($property in @(if ($source -and $source.complexities) { $source.complexities.PSObject.Properties })) {
        if ($kept -notcontains $property.Name) {
            Set-JsonProperty $complexities $property.Name $property.Value
        }
    }
    foreach ($name in $kept) {
        if ($mine -and $mine.complexities -and $mine.complexities.$name) {
            Set-JsonProperty $complexities $name $mine.complexities.$name
        }
    }
    return @{
        picks = [pscustomobject]@{ complexities = $complexities; advisor = $(if ($source) { $source.advisor }) }
        follows = $(if ($linked) { [string]$mine.follows } else { '' }); end = $end; kept = $kept
    }
}

# What scriptorium.json says of the complexities to a provider: all of it to the project's default provider
# ($default), whose models it names. To another provider only the project's own complexities with their descriptions:
# the models, the advisor and the compact size of that tool are its models.json's.
# shortcut: a project's file names models for its default provider only; give another provider keys of its own there
# when a project wants its own defaults for a second coding tool. The owner's picks are each worker's, for any tool
# (Get-WorkerMapping).
function Get-ProviderConfig($config, [bool] $default) {
    if ($default -or -not $config) {
        return $config
    }
    $own = [pscustomobject]@{}
    foreach ($property in @(if ($config.complexities) { $config.complexities.PSObject.Properties })) {
        if ($property.Value.description) {
            Set-JsonProperty $own $property.Name ([pscustomobject]@{ description = [string]$property.Value.description })
        }
    }
    return [pscustomobject]@{ complexities = $own }
}

# A pick (`model@effort`) as its model and effort: the effort after `@`, else that model's in models.json, else
# models.json's `effort`, the one of a model not listed there (as worker.ps1, Get-RunModel).
function Split-Pick($models, [string] $pick) {
    $model, $effort = $pick -split '@'
    if (-not $effort) {
        $effort = if ($model -and $models.models.$model) { [string]$models.models.$model.effort } else { [string]$models.effort }
    }
    return @{ model = [string]$model; effort = [string]$effort }
}

# The efforts a model takes (docs/PLUGINS.md, models.json): its own `efforts` (`[]`: none), else the provider's list;
# none where neither has one. Callers wrap it in @(): an empty list comes back as nothing.
function Get-ModelEfforts($models, [string] $model) {
    $entry = if ($model) { $models.models.$model }
    $list = if ($entry -and $entry.PSObject.Properties['efforts']) { $entry.efforts } else { $models.efforts }
    return @($list | Where-Object { $_ })
}

# A compact size (docs/CONFIG.md, The compact size): the context size at which a run compacts, in whole tokens in
# plain digits, within the sizes the provider takes ($range: models.json's `compactRange`, the least and the most;
# any size without one). Throws for anything else: a size written as '250k' was once read as the least without a word.
function ConvertTo-CompactAt($value, [string] $where, $range = @()) {
    $least = if (@($range).Count -eq 2) { [int]$range[0] } else { 1 }
    $most = if (@($range).Count -eq 2) { [int]$range[1] } else { [int]::MaxValue }
    if ("$value" -notmatch '^\d{1,9}$' -or [int]"$value" -lt $least -or [int]"$value" -gt $most) {
        throw "${where}: '$value' is no compact size: write whole tokens in digits$(if (@($range).Count -eq 2) { ", from $least to $most" })"
    }
    return [int]"$value"
}

# The cap of one run (docs/QUEUE.md, The cap of a run), in the tool's own count: `runCap` of scriptorium.json ($config,
# as Get-ProviderConfig gives it to the provider), else `runCap` of the provider's models.json ($models), else 0 for no
# cap. Throws for a value that is no number of 0 or more.
function Get-RunCap($models, $config) {
    if ($config -and $null -ne $config.runCap) {
        $value = $config.runCap
        $where = 'scriptorium.json'
    } elseif ($models -and $null -ne $models.runCap) {
        $value = $models.runCap
        $where = "the provider's models.json"
    } else {
        return 0.0
    }
    if ($value -isnot [ValueType] -or $value -is [bool] -or "$value" -notmatch '^\d+(\.\d+)?$') {
        throw "${where}: runCap takes a number of 0 or more, not '$value'"
    }
    return [double]$value
}

# The compact size of a ticket's complexity, from the list Get-Complexities gives; medium's for a name not in it,
# as Get-TicketComplexity counts such a ticket.
function Get-ComplexityCompactAt($complexities, [string] $name) {
    $entry = @($complexities | Where-Object { $_.name -eq $name }) + @($complexities | Where-Object { $_.name -eq 'medium' })
    return [int]$entry[0].compactAt
}

# A complexity's candidate models, best first, from the list Get-Complexities gives; none for a name not in it.
function Get-ComplexityModels($complexities, [string] $name) {
    return , @(($complexities | Where-Object { $_.name -eq $name } | Select-Object -First 1).models | Where-Object { $_ })
}

# A ticket's complexity from its label names: the first `complexity:<name>` of the list, else medium.
function Get-TicketComplexity([string[]] $labels, $complexities) {
    $names = @($complexities | ForEach-Object { "complexity:$($_.name)" })
    $label = @($labels | Where-Object { $names -contains $_ } | Select-Object -First 1)
    if ($label.Count) {
        return $label[0].Substring(11)
    }
    return 'medium'
}

# The advisor rule for limits.ps1 (Get-Advisor, Get-FallbackEffort): the advisor's model (the owner's pick in the
# worker's mapping, `advisor.model` of $settings as Get-Complexities takes them, else models.json's), the complexities
# whose runs get it, and the effort each gets instead where the account has no advisor left.
function Get-AdvisorRule($models, $complexities, $settings) {
    $fallback = @{}
    foreach ($entry in @($complexities | Where-Object { $_.advisor -and $_.advisorFallback })) {
        $fallback[$entry.name] = $entry.advisorFallback
    }
    $model = [string]$models.advisor.model
    if ($settings -and $settings.advisor -and $settings.advisor.model) {
        $model = [string]$settings.advisor.model
    }
    return @{
        model = $model
        complexities = @($complexities | Where-Object { $_.advisor } | ForEach-Object { $_.name })
        fallback = $fallback
    }
}

# The lowest worker number nothing holds (the page's Add a worker, setup.ps1): $taken are the numbers with a state file
# in the project or a task in any project of the PC. A removed worker's number comes back, and with it its clone.
function Get-FreeWorkerId($taken) {
    $numbers = @($taken | ForEach-Object { [string]$_ })
    $id = 1
    while ($numbers -contains [string]$id) {
        $id++
    }
    return [string]$id
}

# A logon task's name: `Scriptorium <name> worker 3`, `Scriptorium <name> merger`, `Scriptorium <name> app`.
function Get-TaskName([string] $name, [string] $role) {
    return "Scriptorium $name $role"
}

# How a script's command line names its project, the same in its task and in Test-ProjectProcess.
function Get-ProjectArg([string] $Project) {
    return "-Project `"$Project`""
}

# Tailscale Serve's mapping on this PC (`tailscale serve status --json`): an empty object while it serves nothing, and
# $null when it cannot be read (no Tailscale, or Tailscale does not run).
function Read-Serve {
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        return $null
    }
    try {
        $text = (& $tailscale.Source serve status --json) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $serve = $text | ConvertFrom-Json
        if ($serve) {
            return $serve
        }
        return [pscustomobject]@{}
    } catch {
        return $null
    }
}

# The address of the page of $port on the owner's Tailscale devices, or $null: the HTTPS address whose root Tailscale
# Serve gives to that port of this PC. $serve: Read-Serve. The address is read from the mapping, never made from the
# PC's name: several projects on one PC each have their own (docs/APP.md, Setup).
function Get-ServeUrl($serve, [int] $port) {
    if (-not $serve -or -not $serve.Web) {
        return $null
    }
    foreach ($site in $serve.Web.PSObject.Properties) {
        $at = ($site.Name -split ':')[-1]
        $root = if ($site.Value.Handlers) { $site.Value.Handlers.'/' }
        if ($root -and "$($root.Proxy)" -match "^http://(127\.0\.0\.1|localhost):$port/?$" -and $serve.TCP.$at.HTTPS) {
            return 'https://' + ($site.Name -replace ':443$', '')
        }
    }
    return $null
}

# What setup runs to give the page of $port an address, as the arguments of `tailscale` in one string, or '' when an
# address goes to the port already or the mapping cannot be read. The first project on the PC gets the PC's plain
# address (port 443). A later one gets the first free port from 8443 up, so setup never takes an address that
# Tailscale serves already. Never the page's own port: Windows keeps the port of the page's server (http.sys) from
# every other program, so Tailscale could not listen there for this PC's own browser.
function Get-ServeCommand($serve, [int] $port) {
    if (-not $serve -or (Get-ServeUrl $serve $port)) {
        return ''
    }
    $taken = @(if ($serve.TCP) { $serve.TCP.PSObject.Properties | ForEach-Object { $_.Name } })
    if ($taken -notcontains '443') {
        return "serve --bg $port"
    }
    $at = 8443
    while ($taken -contains "$at" -or $at -eq $port) {
        $at++
    }
    return "serve --bg --https=$at $port"
}

# What uninstall.ps1 runs to take the page of $port off Tailscale, as the arguments of `tailscale` in one string, or ''
# when Tailscale serves no address of that port.
function Get-ServeOffCommand($serve, [int] $port) {
    $url = Get-ServeUrl $serve $port
    if (-not $url) {
        return ''
    }
    $at = if ($url -match ':(\d+)$') { $Matches[1] } else { '443' }
    return "serve --https=$at off"
}

# The project of a logon task, from the task's arguments (Get-ProjectArg wrote them), or '' when they name none.
function Get-TaskProject([string] $arguments) {
    if ($arguments -match '-Project (?:"([^"]+)"|(\S+))') {
        return "$($Matches[1])$($Matches[2])"
    }
    return ''
}

# Whether a branch is a ticket's (PLAYBOOK.md, Branch: `t<N>`). A pull request on any other branch is the owner's own,
# and the merger leaves it alone.
function Test-TicketBranch([string] $branch) {
    return $branch -cmatch '^t\d+$'
}

# Whether a process's command line runs $script (worker.ps1, merge.ps1, server.ps1) for this project. The path as a
# whole argument: another project, a path that starts with this one, or a queue from before -Project never matches.
# conhost passes a path with no space on without its quotes, so the quotes are optional.
function Test-ProjectProcess([string] $commandLine, [string] $script, [string] $Project) {
    if (-not $commandLine) {
        return $false
    }
    return $commandLine.ToLowerInvariant().Contains($script.ToLowerInvariant()) -and
        $commandLine -match ('-Project "?' + [regex]::Escape($Project) + '("|\s|$)')
}

# Whether a process's command line names a worker's copy ($copy, `<main>-w<N>`) or a path in it: a worker's editor
# stays open after its loop ends (Uninstall-Worker). Either slash kind, any case. The path ends at a slash, a quote
# of either kind, white space or the end, so App-w1 never matches App-w10 or App-w1-old.
function Test-CopyProcess([string] $commandLine, [string] $copy) {
    if (-not $commandLine -or -not $copy) {
        return $false
    }
    $path = (@($copy.TrimEnd('\', '/') -split '[\\/]') | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]'
    return $commandLine -match ($path + '([\\/"''\s]|$)')
}
