# The project a script works on: its main checkout and its scriptorium.json (docs/CONFIG.md). Dot-sourced by the
# scripts that take -Project and by their tests; only definitions.

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
# @{ name; description; models; advisor; advisorFallback }. A complexity of the project's own needs a description; with
# no models it runs on medium's. Throws for a missing description or a name that is no label.
function Get-Complexities($models, $config) {
    $base = @($models.complexities.PSObject.Properties | ForEach-Object { $_.Name })
    $changes = if ($config -and $config.complexities) { $config.complexities } else { [pscustomobject]@{} }
    $own = @($changes.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $base -notcontains $_ })
    $names = @($base | Where-Object { $_ -ne 'design' }) + $own + @($base | Where-Object { $_ -eq 'design' })
    $list = @()
    foreach ($name in $names) {
        if ($name -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "complexity '$name': lower-case letters, digits and hyphens only"
        }
        $entry = @{ name = $name; description = ''; models = @(); advisor = $false; advisorFallback = '' }
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
        }
        if (-not $entry.description) {
            throw "complexity '$name' in scriptorium.json needs a description"
        }
        if ($entry.models.Count -eq 0) {
            $entry.models = @(($list | Where-Object { $_.name -eq 'medium' } | Select-Object -First 1).models)
        }
        $list += , $entry
    }
    # The list unrolled, one complexity at a time, so a pipe or a foreach sees each: it is never empty.
    return $list
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
function Get-TaskName([string] $name, [string] $role) {
    return "Scriptorium $name $role"
}

# How a script's command line names its project, the same in its task and in Test-ProjectProcess.
function Get-ProjectArg([string] $Project) {
    return "-Project `"$Project`""
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
