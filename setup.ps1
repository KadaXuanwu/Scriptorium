<#
.SYNOPSIS
Sets up Scriptorium for one project on this PC (README.md). Safe to run again.

.DESCRIPTION
1. Checks the tools: git, the GitHub CLI signed in, Claude Code, a GitHub origin. It stops at a missing one.
2. Writes a first scriptorium.json when the project has none (docs/CONFIG.md): the name from the folder, and each plugin
   of plugins.json whose detect patterns match a file in the project (or -Plugins).
3. Installs the plugins (clones a git source into plugins\<name>, or pulls it) and checks what each requires.
4. Adds .queue/ to the project's .gitignore, and the ticket skill when the project has none.
5. Writes the PC's .queue/settings.json when there is none: the default login runs the workers.
6. Runs each plugin's Setup.
7. Lists the files it added to the project. Workers clone origin, so these must be committed and pushed: -Commit does it.
8. Makes a copy of the repo for each worker beside the main checkout, and runs each plugin's PrepareCopy in it.
9. Makes the GitHub labels, the logon tasks, the ntfy topic and the Tailscale address of the page.

-WhatIf prints each step and changes nothing. Runs in Windows PowerShell 5.1.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Tools\Scriptorium\setup.ps1 -Project D:\Work\MyGame -Commit
#>
param(
    # The project's main checkout: a git repo whose origin is on GitHub.
    [Parameter(Mandatory = $true)] [string] $Project,
    # The workers to set up. The page adds more later.
    [int] $Workers = 1,
    # The plugins of a new scriptorium.json, in place of the ones plugins.json detects. Added to an existing one.
    [string[]] $Plugins,
    # Commits and pushes the files setup added to the project.
    [switch] $Commit,
    # Starts the logon tasks now, not only at the next logon.
    [switch] $Start,
    # Prints each step and changes nothing.
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
# gh writes UTF-8; Windows PowerShell would read it in the console's old code page.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'tasks.ps1')

# Runs one change, or only names it under -WhatIf.
function Invoke-Step([string] $what, [scriptblock] $do) {
    if ($WhatIf) {
        Write-Output "What if: $what"
        return
    }
    Write-Output $what
    & $do
}

# A native command that must succeed. Windows PowerShell turns a program's error text into a stop under 'Stop'.
function Invoke-Native([string] $exe, [string[]] $arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw "$exe $($arguments -join ' ') failed: $(($output | Select-Object -Last 3) -join ' ')"
    }
    return $output
}

function Stop-Setup([string[]] $lines) {
    Write-Output 'Setup stopped:'
    $lines | ForEach-Object { Write-Output "- $_" }
    exit 1
}

# 1. The tools and the repo.
$main = Resolve-Project $Project
$problems = @()
foreach ($tool in @('git', 'gh', 'claude')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $problems += "$tool is not on the PATH: install it (README.md, What it needs)"
    }
}
$slug = ''
$url = ''
if (-not $problems) {
    $ErrorActionPreference = 'Continue'
    & gh auth status *> $null
    $signedIn = $LASTEXITCODE -eq 0
    $top = (& git -C $main rev-parse --show-toplevel 2>$null)
    $url = [string](& git -C $main remote get-url origin 2>$null)
    $ErrorActionPreference = 'Stop'
    if (-not $signedIn) {
        $problems += 'the GitHub CLI is not signed in: run gh auth login'
    }
    if (-not $top -or (Resolve-Path $top).Path.TrimEnd('\') -ne $main) {
        $problems += "$main is not the root of a git repo"
    }
    $slug = [regex]::Match($url, 'github\.com[:/](.+?)(\.git)?$').Groups[1].Value
    if (-not $slug) {
        $problems += "the origin of $main is not a GitHub repo"
    }
}
if ($problems) {
    if (-not $WhatIf) {
        Stop-Setup $problems
    }
    $problems | ForEach-Object { Write-Output "What if: setup would stop here: $_" }
}
$owner = if ($slug) { $slug.Split('/')[0] } else { '<owner>' }

# 2. scriptorium.json.
$added = @()
$registry = Get-Content (Join-Path $PSScriptRoot 'plugins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$configFile = Join-Path $main 'scriptorium.json'
if (Test-Path $configFile) {
    $config = Read-Project $main
    $missing = @($Plugins | Where-Object { $_ -and -not $config.plugins.$_ })
    if ($missing) {
        foreach ($name in $missing) {
            $config.plugins | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{})
        }
        $text = $config | ConvertTo-Json -Depth 8
        Invoke-Step "Add the plugins $($missing -join ', ') to scriptorium.json" { Set-Content $configFile $text -Encoding utf8 }
        $added += 'scriptorium.json'
    }
} else {
    $name = ((Split-Path $main -Leaf) -replace '[^A-Za-z0-9-]+', '-').Trim('-')
    if (-not $name) {
        $name = 'project'
    }
    $names = if ($Plugins) { @($Plugins) } else {
        # A listed plugin whose detect patterns match a file of the project: the base itself knows no environment.
        @($registry.PSObject.Properties | Where-Object {
            @(@($_.Value.detect | Where-Object { $_ }) | Where-Object { Test-Path (Join-Path $main $_) }).Count -gt 0
        } | ForEach-Object { $_.Name })
    }
    $entries = [ordered]@{}
    foreach ($plugin in $names) {
        $entries[$plugin] = [pscustomobject]@{}
    }
    $text = [pscustomobject]@{ name = $name; plugins = [pscustomobject]$entries } | ConvertTo-Json -Depth 8
    Invoke-Step "Write scriptorium.json: name $name, plugins: $(if ($names) { $names -join ', ' } else { 'none' })" {
        Set-Content $configFile $text -Encoding utf8
    }
    $added += 'scriptorium.json'
    $config = [pscustomobject]@{ name = $name; port = 8770; repos = @(); allowedTools = @(); plugins = [pscustomobject]$entries }
}
$complexities = Get-Complexities (Read-Models) $config

# 3. The plugins: installed, loaded, and what each requires checked.
$loaded = @()
foreach ($property in @($config.plugins.PSObject.Properties)) {
    $name = $property.Name
    $entry = $property.Value
    $dir = Get-PluginDir $PSScriptRoot $name $entry
    $source = if ($entry.source) { [string]$entry.source } elseif ($registry.$name) { [string]$registry.$name.source } else { '' }
    # A folder source is used where it is; setup clones and pulls only a git source.
    $folder = $entry.source -and (Test-Path ([string]$entry.source) -PathType Container)
    if (-not $folder) {
        if (-not $source) {
            Stop-Setup @("plugin ${name}: not in plugins.json, and no source in scriptorium.json")
        }
        if (Test-Path $dir) {
            Invoke-Step "Pull the plugin $name in $dir" { Invoke-Native 'git' @('-C', $dir, 'pull', '--ff-only', '--quiet') | Out-Null }
        } else {
            Invoke-Step "Clone the plugin $name from $source into $dir" { Invoke-Native 'git' @('clone', '--quiet', $source, $dir) | Out-Null }
        }
    }
    if (-not (Test-Path (Join-Path $dir 'plugin.ps1'))) {
        Write-Output "What if: load the plugin $name once it is cloned, check what it requires and run its hooks"
        continue
    }
    try {
        $plugin = Import-Plugin $dir $name $entry
    } catch {
        Stop-Setup @("$_")
    }
    $lacking = @($plugin.Requires | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($lacking) {
        $lines = @($lacking | ForEach-Object { "the plugin $name requires $_ on the PATH: its README says how to install it" })
        if (-not $WhatIf) {
            Stop-Setup $lines
        }
        $lines | ForEach-Object { Write-Output "What if: setup would stop here: $_" }
    }
    $loaded += , $plugin
}

# 4. .gitignore and the ticket skill.
$ignore = Join-Path $main '.gitignore'
if (-not ((Test-Path $ignore) -and (Select-String -Path $ignore -Pattern '^/?\.queue/?$' -Quiet))) {
    # On a line of its own, also after a last line with no line break.
    $line = if ((Test-Path $ignore) -and [System.IO.File]::ReadAllText($ignore) -match '[^\n]\z') { "`r`n.queue/" } else { '.queue/' }
    Invoke-Step 'Add .queue/ to .gitignore' { Add-Content $ignore $line -Encoding utf8 }
    $added += '.gitignore'
}
$skill = Join-Path $main '.claude\skills\ticket\SKILL.md'
if (-not (Test-Path $skill)) {
    Invoke-Step 'Add the ticket skill: .claude/skills/ticket/SKILL.md' {
        New-Item -ItemType Directory -Force (Split-Path $skill) | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'templates\skills\ticket\SKILL.md') $skill
    }
    $added += '.claude/skills/ticket/SKILL.md'
}

# 5. The PC's settings (docs/QUEUE.md, Settings): the default login runs the workers and is the owner's own; a private
# ntfy topic.
$settingsFile = Join-Path $main '.queue\settings.json'
$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$changed = $false
if (-not $settings.accounts) {
    $uses = @(1..[math]::Max(1, $Workers) | ForEach-Object { "worker:$_" }) + 'personal'
    $settings | Add-Member -NotePropertyName accounts -NotePropertyValue ([pscustomobject]@{ main = [pscustomobject]@{ uses = $uses } }) -Force
    $changed = $true
}
if (-not $settings.ntfy -or -not $settings.ntfy.topic) {
    $topic = "$($config.name.ToLowerInvariant())-" + (-join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }))
    $settings | Add-Member -NotePropertyName ntfy -NotePropertyValue ([pscustomobject]@{ topic = $topic }) -Force
    $changed = $true
}
if ($changed) {
    $text = $settings | ConvertTo-Json -Depth 8
    Invoke-Step "Write the PC's settings: $settingsFile" {
        New-Item -ItemType Directory -Force (Split-Path $settingsFile) | Out-Null
        Set-Content $settingsFile $text -Encoding utf8
    }
}

# 6. The plugins' Setup: what the project itself must hold.
# The plugins' words go to the screen, never into a hook's answer.
$say = { param($text) Write-Host "  $text" }
foreach ($plugin in $loaded) {
    if (-not $plugin.Hooks.Setup) {
        continue
    }
    if ($WhatIf) {
        Write-Output "What if: run the Setup of the plugin $($plugin.Name)"
        continue
    }
    Write-Output "Run the Setup of the plugin $($plugin.Name)"
    try {
        $answers = Invoke-Hooks @($plugin) 'Setup' $main $main $null $null $settings $say $say
    } catch {
        Stop-Setup @("$_")
    }
    foreach ($answer in $answers) {
        $added += @($answer | Where-Object { $_ -is [string] })
    }
}

# 7. The files to commit: each worker copy clones origin, so it sees only what is pushed. A file in an ignored folder
# goes in too (git add -f): setup names each one.
$added = @($added | Select-Object -Unique)
$pending = @($added | Where-Object { $WhatIf -or (& git -C $main status --porcelain --ignored -- $_) })
if ($pending) {
    if ($Commit) {
        Invoke-Step "Commit and push: $($pending -join ', ')" {
            Invoke-Native 'git' (@('-C', $main, 'add', '-f', '--') + $pending) | Out-Null
            Invoke-Native 'git' (@('-C', $main, 'commit', '--quiet', '-m', 'Set up Scriptorium', '--') + $pending) | Out-Null
            Invoke-Native 'git' @('-C', $main, 'push', '--quiet') | Out-Null
        }
    } else {
        $quoted = ($pending | ForEach-Object { "'$_'" }) -join ' '
        Write-Output "Commit and push these files before a worker runs (or run setup again with -Commit): $($pending -join ', ')"
        Write-Output "  git -C '$main' add -f -- $quoted; git -C '$main' commit -m 'Set up Scriptorium' -- $quoted; git -C '$main' push"
    }
}

# 8. A copy of the repo for each worker, prepared by the plugins.
$clones = @()
for ($i = 1; $i -le $Workers; $i++) {
    $clone = "$main-w$i"
    $clones += $clone
    if (-not (Test-Path $clone)) {
        Invoke-Step "Clone the repo for worker $i into $clone" { Invoke-Native 'git' @('clone', '--quiet', $url, $clone) | Out-Null }
    }
    if (@($loaded | Where-Object { $_.Hooks.PrepareCopy }).Count) {
        Invoke-Step "Prepare the copy of worker $i (PrepareCopy)" {
            try {
                Initialize-Copy $main $loaded $clone "$i"
            } catch {
                Stop-Setup @("$_")
            }
        }
    }
}

# 9. The labels (docs/QUEUE.md, Labels), here and the PR labels in each other repo of the owner.
$labels = [ordered]@{
    'P0' = @('b60205', 'Queued, urgent: before anything else')
    'P1' = @('d93f0b', 'Queued')
    'P2' = @('fbca04', 'Queued, when nothing else waits')
    'needs-owner' = @('5319e7', 'A worker waits on the owner; remove the label once answered')
    'needs-rebase' = @('e99695', 'PR conflicts with main; its worker rebases it')
    'answered' = @('1d76db', 'PR held for questions, now answered; its worker applies the answers')
    'follow-up' = @('0052cc', 'A worker''s leftover with questions; waits for the owner to queue, park or drop it')
    'open-question' = @('0e8a8a', 'A question merged on its default; waits in Questions for the owner to keep or change it')
    'size:S' = @('bfdadc', 'Small usage: little to read and change')
    'size:M' = @('bfdadc', 'Medium usage: a feature''s worth of reading, changing and testing')
    'size:L' = @('bfdadc', 'Large usage: many files, long checks; goes to an account with much 5-hour room')
}
foreach ($complexity in $complexities) {
    $labels["complexity:$($complexity.name)"] = @('d4c5f9', $complexity.description)
}
for ($i = 1; $i -le $Workers; $i++) {
    $labels["worker:$i"] = @('0e8a16', "Claimed by worker $i")
}
$prLabels = @('needs-owner', 'needs-rebase', 'answered') + @($labels.Keys | Where-Object { $_ -like 'worker:*' })
foreach ($other in @($config.repos)) {
    $labels["repo:$other"] = @('006b75', "The work happens in the $other repo; its PR is opened there")
}
Invoke-Step "Make the labels in ${slug}: $($labels.Keys -join ', ')" {
    foreach ($label in $labels.Keys) {
        Invoke-Native 'gh' @('label', 'create', $label, '--color', $labels[$label][0], '--description', $labels[$label][1], '--force', '-R', $slug) | Out-Null
    }
}
foreach ($other in @($config.repos)) {
    Invoke-Step "Make the PR labels in $owner/$other" {
        foreach ($label in $prLabels) {
            Invoke-Native 'gh' @('label', 'create', $label, '--color', $labels[$label][0], '--description', $labels[$label][1], '--force', '-R', "$owner/$other") | Out-Null
        }
    }
}

# The bots get no GitHub notifications from the queue's repos: their mail would reach the owner's inbox, and the page
# tells the owner what matters.
$botDirs = @(@($settings.workers.PSObject.Properties | ForEach-Object { $_.Value.ghConfigDir }) + @($settings.merger.ghConfigDir) |
    Where-Object { $_ } | Sort-Object -Unique)
foreach ($dir in $botDirs) {
    Invoke-Step "Turn off the GitHub notifications of the bot in $dir" {
        foreach ($repoName in @($slug.Split('/')[1]) + @($config.repos)) {
            $env:GH_CONFIG_DIR = $dir
            & gh api -X PUT "repos/$owner/$repoName/subscription" -F ignored=true -F subscribed=false | Out-Null
        }
        Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    }
}

# The logon tasks: the workers, the merger and the page's server.
$tasks = [ordered]@{
    (Get-TaskName $config.name 'merger') = "-File `"$PSScriptRoot\merge.ps1`" $(Get-ProjectArg $main)"
    (Get-TaskName $config.name 'app') = "-File `"$PSScriptRoot\app\server.ps1`" $(Get-ProjectArg $main)"
}
for ($i = 1; $i -le $Workers; $i++) {
    $tasks[(Get-WorkerTaskName $config.name $i)] = Get-WorkerArguments $main $i $clones[$i - 1]
}
Invoke-Step "Register the logon tasks: $($tasks.Keys -join ', ')$(if ($Start) { ', and start them' })" {
    foreach ($task in $tasks.Keys) {
        Register-QueueTask $task $tasks[$task] $main
        if ($Start) {
            Start-ScheduledTask -TaskName $task
        }
    }
}

# The page on the owner's Tailscale devices, at an address that no other project on this PC has (project.ps1,
# Get-ServeCommand).
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
$serve = Read-Serve
if (-not $tailscale) {
    Write-Output "Tailscale is not installed: the page is only at http://127.0.0.1:$($config.port) on this PC."
} elseif (-not $serve) {
    Write-Output "Tailscale does not answer: the page is only at http://127.0.0.1:$($config.port) on this PC. Start Tailscale and run setup again."
} else {
    $command = Get-ServeCommand $serve $config.port
    if ($command) {
        Invoke-Step "Serve the page on your Tailscale devices: tailscale $command" {
            & $tailscale.Source @($command -split ' ')
        }
    }
}

if (-not $WhatIf) {
    Write-Output ''
    Write-Output "Done. The page: http://127.0.0.1:$($config.port) on this PC."
    $address = Get-ServeUrl (Read-Serve) $config.port
    if ($address) {
        Write-Output "On your Tailscale devices: $address"
    }
    Write-Output "Subscribe to the ntfy topic $($settings.ntfy.topic) in the ntfy app for pushes."
    Write-Output 'Sign in more plan accounts on the page (Accounts) when one is not enough.'
}
