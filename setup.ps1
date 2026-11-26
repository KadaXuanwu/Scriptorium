<#
.SYNOPSIS
Sets up Scriptorium for one project on this PC (README.md). Safe to run again.

.DESCRIPTION
1. Checks the tools: git, the GitHub CLI signed in, a GitHub origin. It stops at a missing one.
2. Writes a first scriptorium.json when the project has none (docs/CONFIG.md): the name from the folder, and each plugin
   of plugins.json whose detect patterns match a file in the project (or -Plugins). A project needs one provider, the
   plugin that runs the coding tool (docs/PLUGINS.md, A provider): setup adds the listed one where the project names
   none and plugins.json lists exactly one.
3. Installs the plugins (clones a git source into plugins\<name>, or pulls it) and checks what each requires. It stops
   when no plugin is a provider, and names the listed ones.
4. Adds .queue/ to the project's .gitignore, and the ticket skill in the provider's skills folder. It replaces a ticket skill that is not the current
   one when PROJECT.md is beside it: that file holds the project's own rules for tickets, and setup never changes it.
5. Writes the settings: the project's .queue/settings.json (a push topic), and the PC's part (the workers of the
   project on the command-line login, each with a number that no other project of the PC has).
6. Runs each plugin's Setup.
7. Lists the files it added to the project. Workers clone origin, so these must be committed and pushed: -Commit does it.
8. Makes a copy of the repo for each worker beside the main checkout, and runs each plugin's PrepareCopy in it.
9. Makes the GitHub labels, the logon tasks, the ntfy topic and the Tailscale address of the page.

-WhatIf prints each step and changes nothing. -Check only checks step 1, says how to fix each part, and stops.
Runs in Windows PowerShell 5.1, and in PowerShell 7.4 or later (pwsh) on macOS and Linux.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Tools\Scriptorium\setup.ps1 -Check -Project D:\Work\MyGame

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Tools\Scriptorium\setup.ps1 -Project D:\Work\MyGame -Commit
#>
param(
    # The project's main checkout: a git repo whose origin is on GitHub. -Check works without it.
    [string] $Project,
    # The workers that the project has after the setup: the ones it has, and new ones up to this count. The page adds
    # more later.
    [int] $Workers = 1,
    # The plugins of a new scriptorium.json, in place of the ones plugins.json detects. Added to an existing one.
    [string[]] $Plugins,
    # Commits and pushes the files setup added to the project.
    [switch] $Commit,
    # Starts the logon tasks now, not only at the next logon.
    [switch] $Start,
    # Prints each step and changes nothing.
    [switch] $WhatIf,
    # Only checks what the PC (and the project, when named) needs, says how to fix each part, and changes nothing.
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
# gh writes UTF-8; Windows PowerShell would read it in the console's old code page.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'tasks.ps1')

function Stop-Setup([string[]] $lines) {
    Write-Output 'Setup stopped:'
    $lines | ForEach-Object { Write-Output "- $_" }
    exit 1
}

# 1. The tools and the repo: each check with how to fix it. -Check prints them all and stops here.
if (-not $Project -and -not $Check) {
    Stop-Setup @('name the project: -Project <its folder>')
}
$checks = @()
function Add-Check([bool] $ok, [string] $what, [string] $fix, [bool] $optional = $false) {
    $script:checks += , [pscustomobject]@{ ok = $ok; what = $what; fix = $fix; optional = $optional }
}
if ($OnWindows) {
    Add-Check $true 'Windows' ''
} else {
    Add-Check ($PSVersionTable.PSVersion -ge [version]'7.4') "PowerShell 7.4 or later (this is $($PSVersionTable.PSVersion))" 'install the current PowerShell: https://aka.ms/powershell'
}
$install = if ($OnWindows) { 'winget install --id ' } elseif ($OnMac) { 'brew install ' } else { '' }
$tools = [ordered]@{
    git = if ($install) { "install it: $install$(if ($OnWindows) { 'Git.Git' } else { 'git' })" } else { 'install it with your package manager, for example: sudo apt install git' }
    gh = if ($install) { "install the GitHub CLI: $install$(if ($OnWindows) { 'GitHub.cli' } else { 'gh' })" } else { 'install the GitHub CLI: https://github.com/cli/cli#installation' }
}
foreach ($tool in $tools.Keys) {
    Add-Check ([bool](Get-Command $tool -ErrorAction SilentlyContinue)) "$tool on the PATH" "$($tools[$tool]), then open a new terminal"
}
if (-not $OnWindows -and -not $OnMac) {
    # The workers are systemd user services. Without lingering they end when the owner logs out.
    $ErrorActionPreference = 'Continue'
    & systemctl --user show-environment *> $null
    $systemd = $LASTEXITCODE -eq 0
    $linger = [string](& loginctl show-user $env:USER --property=Linger --value 2>$null)
    $ErrorActionPreference = 'Stop'
    Add-Check $systemd 'systemd user services' 'run setup in a login session of a Linux with systemd'
    Add-Check ($linger -eq 'yes') 'the workers keep running after you log out' "optional: sudo loginctl enable-linger $env:USER" $true
}
$ghReady = $false
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $ErrorActionPreference = 'Continue'
    & gh auth status *> $null
    $ghReady = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    Add-Check $ghReady 'the GitHub CLI signed in' 'run: gh auth login'
}
$main = ''
$slug = ''
$url = ''
if ($Project) {
    if (-not (Test-Path $Project -PathType Container)) {
        Stop-Setup @("$Project is not a folder")
    }
    $main = Resolve-Project $Project
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        $top = (& git -C $main rev-parse --show-toplevel 2>$null)
        $url = [string](& git -C $main remote get-url origin 2>$null)
        $ErrorActionPreference = 'Stop'
        Add-Check ($top -and (Resolve-Path $top).Path.TrimEnd('\') -eq $main) "$main is the root of a git repo" 'name the folder that holds .git, or run git init there'
        $slug = [regex]::Match($url, 'github\.com[:/](.+?)(\.git)?$').Groups[1].Value
        Add-Check ([bool]$slug) 'its origin is a GitHub repo' 'make a repo on GitHub, then run: git remote add origin <its URL>; git push -u origin HEAD'
    }
    if ($slug -and $ghReady) {
        $ErrorActionPreference = 'Continue'
        $permission = [string](& gh repo view $slug --json viewerPermission -q .viewerPermission 2>$null)
        $ErrorActionPreference = 'Stop'
        Add-Check (@('ADMIN', 'MAINTAIN', 'WRITE') -contains $permission) "write access to $slug" 'workers push branches and open pull requests: sign gh in to an account that can push there'
    }
}
Add-Check ($null -ne (Read-Serve)) 'Tailscale, for the page on your phone' 'optional: install Tailscale (https://tailscale.com/download) and sign in; without it the page is only on this PC' $true
if ($Check) {
    foreach ($item in $checks) {
        $mark = if ($item.ok) { '[ok]      ' } elseif ($item.optional) { '[optional]' } else { '[MISSING] ' }
        Write-Output "$mark $($item.what)$(if (-not $item.ok) { ": $($item.fix)" })"
    }
    if (-not $Project) {
        Write-Output 'Add -Project <folder> to check the project too.'
    }
    if (@($checks | Where-Object { -not $_.ok -and -not $_.optional }).Count) {
        Write-Output 'Fix each MISSING line, then run setup -Check again.'
        exit 1
    }
    Write-Output 'Ready. Setup checks each plugin when it installs it. Run setup without -Check.'
    exit 0
}
$problems = @($checks | Where-Object { -not $_.ok -and -not $_.optional } | ForEach-Object { "$($_.what): $($_.fix)" })
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
# The listed providers (docs/PLUGINS.md, A provider). A project that names none of them, and no plugin from a source
# of its own (that one may be a provider), gets the listed one when there is exactly one. With several, setup stops
# after step 3 and names them.
$providers = @($registry.PSObject.Properties | Where-Object { $_.Value.provider } | ForEach-Object { $_.Name })
function Add-Provider($names, $entries) {
    $own = @($entries | Where-Object { $_ } | ForEach-Object { $_.PSObject.Properties } | Where-Object { $_.Value.source })
    if ($providers.Count -eq 1 -and -not $own -and -not @($names | Where-Object { $providers -contains $_ })) {
        return @($providers) + @($names)
    }
    return @($names)
}
if (Test-Path $configFile) {
    $config = Read-Project $main
    $wanted = Add-Provider (@($config.plugins.PSObject.Properties | ForEach-Object { $_.Name }) + @($Plugins | Where-Object { $_ })) $config.plugins
    $missing = @($wanted | Where-Object { $_ -and -not $config.plugins.$_ } | Select-Object -Unique)
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
    $names = @(Add-Provider $names $null)
    $entries = [ordered]@{}
    foreach ($plugin in $names) {
        $entries[$plugin] = [pscustomobject]@{}
    }
    $text = [pscustomobject]@{ name = $name; plugins = [pscustomobject]$entries } | ConvertTo-Json -Depth 8
    Invoke-Step "Write scriptorium.json: name $name, plugins: $(if ($names) { $names -join ', ' } else { 'none' })" {
        Set-Content $configFile $text -Encoding utf8
    }
    $added += 'scriptorium.json'
    $config = [pscustomobject]@{ name = $name; port = 8770; repos = @(); commands = @(); allowedTools = @(); plugins = [pscustomobject]$entries }
}

# 3. The plugins: installed, loaded, and what each requires checked.
$loaded = @()
# A plugin that -WhatIf did not clone: it may be the provider.
$pending = $false
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
        $pending = $true
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
# The provider: its models give the complexities their labels, and its skills folder takes the ticket skill.
$provider = Get-Provider $loaded
if (-not $provider -and -not $pending) {
    $listed = @($registry.PSObject.Properties | Where-Object { $_.Value.provider } | ForEach-Object { "$($_.Name) ($($_.Value.description))" })
    $lines = @("the project has no provider, the plugin that runs the coding tool (docs/PLUGINS.md, A provider): run setup again with -Plugins <name>" +
        $(if ($listed) { ". Listed: $($listed -join '; ')" } else { '' }))
    if (-not $WhatIf) {
        Stop-Setup $lines
    }
    $lines | ForEach-Object { Write-Output "What if: setup would stop here: $_" }
}
Set-Provider $provider @{ Project = $main; Copy = $main }
$complexities = Get-Complexities (Read-Models) $config
# A run cap that is no number stops setup here, not the first run.
Get-RunCap (Read-Models) $config | Out-Null
# The command-line login, the one setup gives a new worker. No stop: a PC whose workers all run on accounts added on
# the page may leave it signed out.
$login = Invoke-Provider 'GetLogin' @{ Login = '' }
if ($login -and -not $login.SignedIn) {
    Write-Output "The command-line login of $($provider.Title) is signed out: sign it in (the plugin's README says how), or add an account on the page (Accounts)."
}

# 4. .gitignore and the ticket skill.
$ignore = Join-Path $main '.gitignore'
if (-not ((Test-Path $ignore) -and (Select-String -Path $ignore -Pattern '^/?\.queue/?$' -Quiet))) {
    # On a line of its own, also after a last line with no line break.
    $line = if ((Test-Path $ignore) -and [System.IO.File]::ReadAllText($ignore) -match '[^\n]\z') { "`r`n.queue/" } else { '.queue/' }
    Invoke-Step 'Add .queue/ to .gitignore' { Add-Content $ignore $line -Encoding utf8 }
    $added += '.gitignore'
}
# SKILL.md is Scriptorium's: setup replaces a copy that differs. The project's own rules are in PROJECT.md beside it,
# which setup writes once and never changes. A skill with no PROJECT.md is from an older setup and may hold the
# project's rules, so it stays.
# The skill goes where the provider's tool reads a project's skills (its manifest, `skills`).
$skills = if ($provider -and $provider.Skills) { $provider.Skills.Trim('/', '\') } else { '' }
$skillDir = Join-Path $main "$skills/ticket"
$skill = Join-Path $skillDir 'SKILL.md'
$rules = Join-Path $skillDir 'PROJECT.md'
$template = Join-Path $PSScriptRoot 'templates/skills/ticket'
# Without the line ends: git writes them as the PC wants them.
$read = { param($file) (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -replace "`r", '' }
if (-not $skills) {
    Write-Output 'No ticket skill: the provider names no skills folder (or is not cloned yet).'
} elseif (-not (Test-Path $skill)) {
    Invoke-Step "Add the ticket skill: $skills/ticket (SKILL.md, and PROJECT.md for the rules of this project)" {
        New-Item -ItemType Directory -Force $skillDir | Out-Null
        Copy-Item (Join-Path $template 'SKILL.md') $skill
        if (-not (Test-Path $rules)) {
            Copy-Item (Join-Path $template 'PROJECT.md') $rules
        }
    }
    $added += "$skills/ticket/SKILL.md", "$skills/ticket/PROJECT.md"
} elseif ((& $read $skill) -ne (& $read (Join-Path $template 'SKILL.md'))) {
    if (Test-Path $rules) {
        Invoke-Step "Replace the ticket skill with the current one: $skills/ticket/SKILL.md" {
            Copy-Item (Join-Path $template 'SKILL.md') $skill -Force
        }
        $added += "$skills/ticket/SKILL.md"
    } else {
        Write-Output ("The ticket skill is not the current one, and it stays: it has no PROJECT.md beside it, so it may hold rules of " +
            "this project. To take the current one, move those rules to $skills/ticket/PROJECT.md (copy " +
            "$(Join-Path $template 'PROJECT.md') when the project has none) and run setup again.")
    }
}

# 5. The settings (docs/QUEUE.md, Settings). The project's own: a private ntfy topic. The PC's (pc.ps1): the workers of
# this project on the command-line login, which is also the owner's own.
# The project's workers: the ones it has, then new ones up to -Workers, each with the lowest number that no worker of
# the PC has (a worker's number is the PC's).
$ids = @(Get-ChildItem (Join-Path $main '.queue/worker-*.json') -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName.Substring(7) }) +
    @(Get-QueueTasks (Get-WorkerTaskName $config.name '*') | ForEach-Object { $_.TaskName.Split(' ')[-1] })
$ids = @($ids | Sort-Object { [int]$_ } -Unique)
$taken = @(Get-QueueTasks (Get-WorkerTaskName '*' '*') | ForEach-Object { $_.TaskName.Split(' ')[-1] })
while ($ids.Count -lt $Workers) {
    $ids += Get-FreeWorkerId ($taken + $ids)
}
$settingsFile = Join-Path $main '.queue/settings.json'
$lock = Enter-PcLock 'Settings'
try {
    # -WhatIf changes nothing: not the move of an older project's account keys to the PC's file either.
    if ($WhatIf) {
        $settings = Read-JsonFile $settingsFile
    } else {
        Initialize-Pc $main
        $settings = Read-ProjectSettings $main
    }
    if (-not $settings) {
        $settings = [pscustomobject]@{}
    }
    $changed = $false
    # Each worker that is on no account yet goes on one of the project's default provider (pc.ps1, Set-WorkerAccounts).
    if (Set-WorkerAccounts $settings ([string[]]@($ids | ForEach-Object { "$_" })) $(if ($provider) { $provider.Name } else { '' }) $HOME) {
        $changed = $true
    }
    if (-not $settings.ntfy -or -not $settings.ntfy.topic) {
        $topic = "$($config.name.ToLowerInvariant())-" + (-join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }))
        Set-JsonProperty $settings 'ntfy' ([pscustomobject]@{ topic = $topic })
        $changed = $true
    }
    if ($changed) {
        Invoke-Step "Write the settings: $settingsFile, and the PC's part in $PcDir" {
            Save-ProjectSettings $main $settings
        }
    }
} finally {
    Exit-PcLock $lock
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
foreach ($i in $ids) {
    $clone = "$main-w$i"
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
foreach ($i in $ids) {
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
$botDirs = @(@($settings.workers.PSObject.Properties | Where-Object { $ids -contains $_.Name } | ForEach-Object { $_.Value.ghConfigDir }) + @($settings.merger.ghConfigDir) |
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
    (Get-TaskName $config.name 'merger') = "-File `"$(Join-Path $PSScriptRoot 'merge.ps1')`" $(Get-ProjectArg $main)"
    (Get-TaskName $config.name 'app') = "-File `"$(Join-Path $PSScriptRoot 'app/server.ps1')`" $(Get-ProjectArg $main)"
}
foreach ($i in $ids) {
    $tasks[(Get-WorkerTaskName $config.name $i)] = Get-WorkerArguments $main $i "$main-w$i"
}
Invoke-Step "Register the logon tasks: $($tasks.Keys -join ', ')$(if ($Start) { ', and start them' })" {
    foreach ($task in $tasks.Keys) {
        Register-QueueTask $task $tasks[$task] $main
        if ($Start) {
            Start-QueueTask $task
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
