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

# A logon task's name: `Scriptorium <name> worker 3`, `Scriptorium <name> merger`, `Scriptorium <name> app`.
function Get-TaskName([string] $name, [string] $role) {
    return "Scriptorium $name $role"
}

# How a script's command line names its project, the same in its task and in Test-ProjectProcess.
function Get-ProjectArg([string] $Project) {
    return "-Project `"$Project`""
}

# Whether a process's command line runs $script (worker.ps1, merge.ps1, server.ps1) for this project. The path with its
# closing quote: another project, a path that starts with this one, or a queue from before -Project never matches.
function Test-ProjectProcess([string] $commandLine, [string] $script, [string] $Project) {
    if (-not $commandLine) {
        return $false
    }
    $line = $commandLine.ToLowerInvariant()
    return $line.Contains($script.ToLowerInvariant()) -and $line.Contains((Get-ProjectArg $Project).ToLowerInvariant())
}
