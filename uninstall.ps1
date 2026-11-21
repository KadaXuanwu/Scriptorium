<#
.SYNOPSIS
Takes Scriptorium off one project on this PC (README.md, Uninstall). Safe to run again.

.DESCRIPTION
1. Ends the project's page, merger and workers, with their runs and editors, and removes their logon tasks.
2. Takes the project's workers out of the PC's settings.
3. Deletes each worker's copy (`<main>-w<N>`, and its copies of the repos of `repo:` labels), unless it holds work that
   GitHub does not have, or -KeepCopies: such a copy stays, and uninstall names it.
4. Takes the page off Tailscale, and deletes the project's `.queue` folder.
5. With -Repo, also takes Scriptorium out of the repo: the queue's labels on GitHub, scriptorium.json, the ticket skill
   and the `.queue/` line of .gitignore. -Commit commits and pushes that change.

It never touches tickets, pull requests, branches or the Claude accounts. -WhatIf prints each step and changes nothing.
Runs in Windows PowerShell 5.1.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Tools\Scriptorium\uninstall.ps1 -Project D:\Work\MyGame -WhatIf
#>
param(
    # The project's main checkout, as setup.ps1 was given it.
    [Parameter(Mandatory = $true)] [string] $Project,
    # Leaves every worker copy on the PC.
    [switch] $KeepCopies,
    # Also deletes the queue's labels on GitHub (P0, P1, P2, size:*, worker:* and the others: tickets lose them) and the
    # files setup added to the repo.
    [switch] $Repo,
    # With -Repo: commits and pushes the files' removal.
    [switch] $Commit,
    # Prints each step and changes nothing.
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'tasks.ps1')
# Set-WorkerEntry: the page's own removal of a worker from the settings.
. (Join-Path $PSScriptRoot 'app\state.ps1')

$main = Resolve-Project $Project
$config = $null
try {
    $config = Read-Project $main
} catch {
    Write-Output "No scriptorium.json in ${main}: uninstall goes by the logon tasks and folders alone."
}

# 1. The scripts. A task is the project's by the -Project of its arguments, so another project of the same name is
# never touched. The page and the merger end first: the page could start a worker again.
$tasks = @(Get-ScheduledTask -TaskName 'Scriptorium *' -ErrorAction SilentlyContinue |
    Where-Object { (Get-TaskProject "$($_.Actions[0].Arguments)") -eq $main })
$name = if ($config) { [string]$config.name } elseif ($tasks) { $tasks[0].TaskName.Split(' ')[1] } else { '' }
$ids = @(@($tasks | ForEach-Object { if ($_.TaskName -match ' worker (\d+)$') { $Matches[1] } }) +
    @(Get-ChildItem (Join-Path $main '.queue\worker-*.json') -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName.Substring(7) }) |
    Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ } -Unique)

foreach ($task in $tasks | Where-Object { $_.TaskName -notmatch ' worker \d+$' }) {
    Invoke-Step "Stop and remove the logon task $($task.TaskName)" {
        Stop-ScheduledTask -TaskName $task.TaskName
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
    }
}
Invoke-Step 'End the project''s page and merger scripts' {
    # Stopping a task ends only its console host (tasks.ps1, Uninstall-Worker).
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { (Test-ProjectProcess $_.CommandLine 'merge.ps1' $main) -or (Test-ProjectProcess $_.CommandLine 'server.ps1' $main) } |
        ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }
}
foreach ($id in $ids) {
    Invoke-Step "End worker $id and its run, and remove its logon task" { Uninstall-Worker $main $name $id }
}

# 2. The PC's settings: the workers leave the register. The accounts stay: other projects may use them.
if ($ids.Count) {
    Invoke-Step "Take the workers $($ids -join ', ') out of the PC's settings ($PcDir)" {
        $lock = Enter-PcLock 'Settings'
        try {
            $settings = Read-ProjectSettings $main
            if ($settings) {
                foreach ($id in $ids) {
                    $settings = Set-WorkerEntry $settings $id $false
                }
                Save-ProjectSettings $main $settings
            }
        } finally {
            Exit-PcLock $lock
        }
    }
}

# 3. The copies: this repo's (every `<main>-w<N>` beside it: a worker the page removed leaves its copy) and the
# workers' copies of the `repo:` repos. A copy with work that GitHub does not have stays.
$parent = Split-Path $main -Parent
$leaf = Split-Path $main -Leaf
$copies = @(Get-ChildItem -LiteralPath $parent -Directory |
    ForEach-Object { if ($_.Name -match "^$([regex]::Escape($leaf))-w(\d+)$") { @{ main = $main; id = $Matches[1] } } })
foreach ($other in @(if ($config) { $config.repos })) {
    $copies += @($ids | Where-Object { Test-Path -LiteralPath (Join-Path $parent "$other-w$_") } |
        ForEach-Object { @{ main = (Join-Path $parent $other); id = $_ } })
}
foreach ($copy in $copies) {
    $folder = "$($copy.main)-w$($copy.id)"
    if ($KeepCopies) {
        Write-Output "Stays (-KeepCopies): $folder"
        continue
    }
    $work = @(Get-CopyWork $folder)
    if ($work.Count) {
        Write-Output "Stays, it holds work that GitHub does not have ($($work -join '; ')): $folder. Delete it by hand once nothing in it matters."
        continue
    }
    Invoke-Step "Delete the worker copy $folder" {
        $trash = Rename-CopyToDelete $copy.main $copy.id
        if ($trash) {
            Remove-Tree $trash
        } else {
            Write-Output "  It stays: a program still uses a file in it. Close it and run uninstall again."
        }
    }
}
foreach ($trash in @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object { Test-CopyToDelete $main $_.Name })) {
    Invoke-Step "Delete $($trash.FullName), a copy whose delete was cut off" { Remove-Tree $trash.FullName }
}

# 4. Tailscale and the project's own queue folder.
if ($config) {
    $command = Get-ServeOffCommand (Read-Serve) $config.port
    if ($command) {
        Invoke-Step "Take the page off your Tailscale devices: tailscale $command" {
            Invoke-Native (Get-Command tailscale).Source @($command -split ' ') | Out-Null
        }
    }
}
$queue = Join-Path $main '.queue'
if (Test-Path -LiteralPath $queue) {
    Invoke-Step "Delete ${queue}: the project's settings, logs and records" { Remove-Tree $queue }
}

# 5. The repo, only with -Repo.
if ($Repo) {
    $url = [string](& git -C $main remote get-url origin)
    $slug = [regex]::Match($url, 'github\.com[:/](.+?)(\.git)?$').Groups[1].Value
    $fixed = @('P0', 'P1', 'P2', 'needs-owner', 'needs-rebase', 'answered', 'follow-up', 'open-question')
    # The other repos got only the PR labels (setup.ps1, step 9).
    $targets = @(@{ repo = $slug; match = { param($label) $fixed -contains $label -or $label -match '^(size|complexity|worker|repo):' } })
    foreach ($other in @(if ($config) { $config.repos })) {
        $targets += @{ repo = "$($slug.Split('/')[0])/$other"; match = { param($label) @('needs-owner', 'needs-rebase', 'answered') -contains $label -or $label -match '^worker:' } }
    }
    foreach ($target in $targets) {
        $labels = @(& gh label list -R $target.repo --limit 500 --json name -q '.[].name' | Where-Object { & $target.match $_ })
        if ($labels.Count) {
            Invoke-Step "Delete the labels in $($target.repo): $($labels -join ', ')" {
                foreach ($label in $labels) {
                    Invoke-Native 'gh' @('label', 'delete', $label, '--yes', '-R', $target.repo) | Out-Null
                }
            }
        }
    }

    $removed = @()
    foreach ($path in @('scriptorium.json', '.claude\skills\ticket')) {
        if (Test-Path -LiteralPath (Join-Path $main $path)) {
            Invoke-Step "Delete $path" { Remove-Item -LiteralPath (Join-Path $main $path) -Recurse -Force }
            $removed += $path.Replace('\', '/')
        }
    }
    $ignore = Join-Path $main '.gitignore'
    if ((Test-Path $ignore) -and (Select-String -Path $ignore -Pattern '^/?\.queue/?$' -Quiet)) {
        Invoke-Step 'Take .queue/ out of .gitignore' {
            $lines = @(Get-Content $ignore -Encoding UTF8 | Where-Object { $_ -notmatch '^/?\.queue/?$' })
            # No byte order mark: Windows PowerShell's utf8 writes one.
            [IO.File]::WriteAllLines($ignore, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
        }
        $removed += '.gitignore'
    }
    if ($removed.Count) {
        if ($Commit) {
            Invoke-Step "Commit and push the removal of $($removed -join ', ')" {
                Invoke-Native 'git' (@('-C', $main, 'add', '-A', '--') + $removed) | Out-Null
                Invoke-Native 'git' (@('-C', $main, 'commit', '--quiet', '-m', 'Remove Scriptorium', '--') + $removed) | Out-Null
                Invoke-Native 'git' @('-C', $main, 'push', '--quiet') | Out-Null
            }
        } else {
            $quoted = ($removed | ForEach-Object { "'$_'" }) -join ' '
            Write-Output "Commit and push the removal (or run uninstall again with -Repo -Commit):"
            Write-Output "  git -C '$main' add -A -- $quoted; git -C '$main' commit -m 'Remove Scriptorium' -- $quoted; git -C '$main' push"
        }
    }
    if ($config -and @($config.plugins.PSObject.Properties).Count) {
        Write-Output "Files that a plugin's Setup added to the repo stay: each plugin's README names them."
    }
}

# What stays on the PC.
if (-not $WhatIf) {
    Write-Output ''
    Write-Output "Done. Scriptorium no longer runs $main."
    if (-not @(Get-PcProjects).Count) {
        $folders = @((Read-PcSettings).accounts.PSObject.Properties | ForEach-Object { $_.Value.configDir } | Where-Object { $_ })
        Write-Output "No project on this PC uses Scriptorium now. To remove the rest, delete $PcDir (settings and usage records)$(if ($folders) { ", the login folders of the accounts added on the page ($($folders -join ', '))" }) and $PSScriptRoot."
    }
}
