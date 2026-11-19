# The project a script works on: its main checkout and its scriptorium.json (docs/CONFIG.md). Dot-sourced by the
# scripts that take -Project and by their tests; only definitions.

. (Join-Path $PSScriptRoot 'pc.ps1')

# The main checkout's full path, as every task and process match writes it.
function Resolve-Project([string] $Project) {
    return (Resolve-Path $Project).Path.TrimEnd('\')
}

# The project's scriptorium.json with its defaults: port 8770, no repos, no extra tools, no plugins. Throws for a
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
    $defaults = @{ port = 8770; repos = @(); allowedTools = @(); plugins = [pscustomobject]@{} }
    foreach ($key in $defaults.Keys) {
        if ($null -eq $config.$key) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }
    return $config
}

# The base's model list (docs/QUEUE.md, Models), read again at each use so an edit applies at once.
function Read-Models {
    return Get-Content (Join-Path $PSScriptRoot 'models.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

# The ticket complexities (docs/CONFIG.md, Complexities), the one list every script and the page read: models.json's,
# with scriptorium.json's `complexities` over them, in this order: low, medium, high, the project's own, design. Each
# @{ name; description; models; base; advisor; advisorFallback; compactAt }. A complexity of the project's own needs a
# description; with no models it runs on medium's. The model the owner picked on the page ($settings: the PC's
# settings.json, `complexities.<name>.model`) is its one candidate, and `base` is the first candidate without that
# pick. Its compact size (docs/CONFIG.md, The compact size) is the one the owner set on the page
# (`complexities.<name>.compactAt`), else its own in scriptorium.json, else the project's, else models.json's. Throws
# for a missing description, a name that is no label or a compact size out of range.
function Get-Complexities($models, $config, $settings) {
    $compactAt = ConvertTo-CompactAt $(if ($config -and $null -ne $config.compactAt) { $config.compactAt } else { $models.compactAt }) 'compactAt'
    $paged = if ($settings -and $settings.complexities) { $settings.complexities } else { [pscustomobject]@{} }
    $base = @($models.complexities.PSObject.Properties | ForEach-Object { $_.Name })
    $changes = if ($config -and $config.complexities) { $config.complexities } else { [pscustomobject]@{} }
    $own = @($changes.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $base -notcontains $_ })
    $names = @($base | Where-Object { $_ -ne 'design' }) + $own + @($base | Where-Object { $_ -eq 'design' })
    $list = @()
    foreach ($name in $names) {
        if ($name -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "complexity '$name': lower-case letters, digits and hyphens only"
        }
        $entry = @{ name = $name; description = ''; models = @(); base = ''; advisor = $false; advisorFallback = ''; compactAt = $compactAt }
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
                $entry.compactAt = ConvertTo-CompactAt $source.compactAt "complexity '$name'"
            }
        }
        if ($paged.$name -and $null -ne $paged.$name.compactAt) {
            $entry.compactAt = ConvertTo-CompactAt $paged.$name.compactAt "settings.json, complexity '$name'"
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

# A pick (`claude-opus-5-5@high`) as its model and effort: the effort after `@`, else that model's in models.json,
# xhigh for a model not listed there (as worker.ps1, Get-RunModel).
function Split-Pick($models, [string] $pick) {
    $model, $effort = $pick -split '@'
    if (-not $effort) {
        $effort = if ($models.models.$model) { [string]$models.models.$model.effort } else { 'xhigh' }
    }
    return @{ model = $model; effort = $effort }
}

# A compact size (docs/CONFIG.md, The compact size): the context size at which a run compacts, in whole tokens in
# plain digits, from 67000 to 967000, which are the windows Claude Code takes (Get-CompactWindow). Throws for
# anything else: Claude Code read '250k' as its minimum without a word.
function ConvertTo-CompactAt($value, [string] $where) {
    if ("$value" -notmatch '^\d{5,6}$' -or [int]"$value" -lt 67000 -or [int]"$value" -gt 967000) {
        throw "${where}: '$value' is no compact size: write whole tokens in digits, from 67000 to 967000"
    }
    return [int]"$value"
}

# The window that makes Claude Code compact a run at $at tokens (CLAUDE_CODE_AUTO_COMPACT_WINDOW, from 100000 to
# 1000000): Claude Code compacts 33000 tokens before its window (measured with Claude Code 2.1.323).
function Get-CompactWindow([int] $at) {
    return $at + 33000
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

# The advisor rule for limits.ps1 (Get-Advisor, Get-FallbackEffort): models.json's advisor model, the complexities
# whose runs get it, and the effort each gets instead where the account has no advisor left.
function Get-AdvisorRule($models, $complexities) {
    $fallback = @{}
    foreach ($entry in @($complexities | Where-Object { $_.advisor -and $_.advisorFallback })) {
        $fallback[$entry.name] = $entry.advisorFallback
    }
    return @{
        model = [string]$models.advisor.model
        complexities = @($complexities | Where-Object { $_.advisor } | ForEach-Object { $_.name })
        fallback = $fallback
    }
}

# A logon task's name: `Scriptorium <name> worker 3`, `Scriptorium <name> merger`, `Scriptorium <name> app`.
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

# The project of a logon task, from the task's arguments (Get-ProjectArg wrote them), or '' when they name none.
function Get-TaskProject([string] $arguments) {
    if ($arguments -match '-Project (?:"([^"]+)"|(\S+))') {
        return "$($Matches[1])$($Matches[2])"
    }
    return ''
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
# stays open after its loop ends (Uninstall-Worker). Either slash kind, any case. The path ends at a slash, a quote,
# white space or the end, so App-w1 never matches App-w10 or App-w1-old.
function Test-CopyProcess([string] $commandLine, [string] $copy) {
    if (-not $commandLine -or -not $copy) {
        return $false
    }
    $path = (@($copy.TrimEnd('\', '/') -split '[\\/]') | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]'
    return $commandLine -match ($path + '([\\/"\s]|$)')
}
