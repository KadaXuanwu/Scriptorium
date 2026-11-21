# The queue's logon tasks, the setup of one worker and the delete of its copy (docs/QUEUE.md; docs/APP.md, Add and
# remove): shared by setup.ps1, uninstall.ps1 and the queue app's Add a worker, Remove and move (app/server.ps1). Dot-sourced; nothing
# runs on load.

. (Join-Path $PSScriptRoot 'project.ps1')
. (Join-Path $PSScriptRoot 'plugins.ps1')

# Runs one change, or only names it when the calling script (setup.ps1, uninstall.ps1) runs with -WhatIf.
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

# Logon tasks: hidden, one instance each, no time limit (a ticket can take hours). Through a headless console: with
# Windows Terminal as the default terminal, powershell's -WindowStyle Hidden still opens a window, and closing it kills
# the task.
function Register-QueueTask([string] $name, [string] $arguments, [string] $main) {
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -WorkingDirectory $main `
        -Argument "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass $arguments"
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
}

# The projects that Scriptorium runs on this PC, each with its name, its page's port and its main checkout (`main`):
# from the logon tasks of the pages. The lookup takes half a second, so the page's server asks at its start and every
# few minutes. `main` stays on the server: the page gets the views (state.ps1, Get-ProjectViews).
function Get-PcProjects {
    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskName (Get-TaskName '*' 'app') -ErrorAction SilentlyContinue)) {
        try {
            $main = Resolve-Project (Get-TaskProject "$($task.Actions[0].Arguments)")
            $project = Read-Project $main
            $found += [pscustomobject]@{ name = [string]$project.name; port = [int]$project.port; main = $main }
        } catch {
            # A task whose project is gone or has no scriptorium.json: not a project of the list.
        }
    }
    return $found
}

function Get-WorkerTaskName([string] $name, [string] $id) {
    return Get-TaskName $name "worker $id"
}

function Get-WorkerArguments([string] $main, [string] $id, [string] $clone) {
    return "-File `"$PSScriptRoot\worker.ps1`" $(Get-ProjectArg $main) -Id $id -Clone `"$clone`""
}

# Makes a worker copy able to work (docs/PLUGINS.md, PrepareCopy): each plugin adds what git does not hold and its
# per-checkout git config. Throws with the plugin's name at the first hook that fails.
function Initialize-Copy([string] $main, $plugins, [string] $clone, [string] $id) {
    $machine = Read-ProjectSettings $main
    $say = { param($text) Write-Host "  $text" }
    Invoke-Hooks $plugins 'PrepareCopy' $main $clone $id (Join-Path $clone '.queue') $machine $say $say | Out-Null
}

# One worker more (the queue app's Add a worker): its clone beside the main checkout (one left by a removed worker of
# that number is used again) prepared by the plugins, its `worker:N` label in this repo and in each repo a
# `repo:<Name>` label names, and its logon task, started. Throws at the first step that fails.
function Install-Worker([string] $main, [string] $name, [string] $slug, [string] $id) {
    $clone = "$main-w$id"
    if (-not (Test-Path $clone)) {
        & git clone --quiet (& git -C $main remote get-url origin) $clone
        if ($LASTEXITCODE -ne 0) {
            throw "git clone into $clone failed"
        }
    }
    Initialize-Copy $main (Import-Plugins $PSScriptRoot (Read-Project $main)) $clone $id | Out-Null
    $repos = @($slug) + @(& gh label list -R $slug --search 'repo:' --limit 100 --json name -q '.[].name' |
        Where-Object { $_ -like 'repo:*' } | ForEach-Object { "$($slug.Split('/')[0])/$($_.Substring(5))" })
    foreach ($repo in $repos) {
        & gh label create "worker:$id" --color 0e8a16 --description "Claimed by worker $id" --force -R $repo | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "the label worker:$id could not be made in $repo"
        }
    }
    Register-QueueTask (Get-WorkerTaskName $name $id) (Get-WorkerArguments $main $id $clone) $main
    Start-ScheduledTask -TaskName (Get-WorkerTaskName $name $id) -ErrorAction Stop
}

# A worker's task and loop end (the queue app's Remove and a worker's move to another project). Stopping a task ends
# only its console host: the loop, and its run with it, end by its project and its `-Id`. Then every process that still
# runs from its copy ends: its editor is not in the loop's process tree and stays open after the loop (measured).
function Uninstall-Worker([string] $main, [string] $name, [string] $id) {
    $task = Get-WorkerTaskName $name $id
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { (Test-ProjectProcess $_.CommandLine 'worker.ps1' $main) -and $_.CommandLine -match "-Id $id\b" } |
        ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }
    Get-CimInstance Win32_Process |
        Where-Object { $_.ProcessId -ne $PID -and (Test-CopyProcess $_.CommandLine "$main-w$id") } |
        ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }
}

# What a worker's copy holds that GitHub does not have, a phrase each for the owner (the queue app's dialogs that can
# delete the copy): the files changed and not committed, the stashes, the commits on no branch, and each branch with
# commits that were not pushed. A branch whose GitHub branch is gone (its PR is merged or closed) does not count:
# after a squash merge no remote branch holds its commits, and every used copy has many such branches.
# shortcut: commits made after the last push of a branch that is gone on GitHub are not seen; compare with the PR's
# head if a worker ever commits after its PR is closed.
function Get-CopyWork([string] $copy) {
    $files = @(& git -C $copy --no-optional-locks status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        return @('it is no git checkout, so nothing in it was checked')
    }
    $work = @()
    if ($files) {
        $more = $files.Count - 3
        $work += "changed files: $((@($files | Select-Object -First 3 | ForEach-Object { $_.Substring(3) }) -join ', '))$(if ($more -gt 0) { " and $more more" })"
    }
    $stashes = @(& git -C $copy stash list).Count
    if ($stashes) {
        $work += "stashes: $stashes"
    }
    $loose = [int]"$(& git -C $copy rev-list --count HEAD --not --branches --remotes)"
    if ($loose) {
        $work += "commits on no branch: $loose"
    }
    foreach ($line in @(& git -C $copy for-each-ref '--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)' refs/heads)) {
        $name, $upstream, $track = $line.Split("`t")
        # Ahead of its GitHub branch: only the commits whose change that branch does not have. After another worker
        # rebased the branch, the old commits here are ahead of it and hold nothing new.
        $ahead = if ($track -match 'ahead') {
            [int]"$(& git -C $copy rev-list --count --cherry-pick --left-only "${name}...${upstream}")"
        } elseif (-not $upstream) {
            [int]"$(& git -C $copy rev-list --count $name --not --remotes)"
        } else { 0 }
        if ($ahead) {
            $work += "commits not pushed on ${name}: $ahead"
        }
    }
    return $work
}

# The first half of deleting a worker's copy of the project $main (the queue app's Remove and move, when the owner
# ticks it): the copy gets a name that no worker uses. The rename is done at once, so a new worker of this number never
# finds a copy that is half deleted, and Windows refuses it while a program still uses a file in the copy. The path
# comes only from the main checkout and the worker's number. Returns the folder for Remove-Tree; '' when the worker has
# no copy, or a program still uses it after $tries tries a second apart: the copy then stays as it is.
function Rename-CopyToDelete([string] $main, [string] $id, [int] $tries = 5) {
    $copy = "$main-w$id"
    if ($id -notmatch '^\d+$' -or -not (Test-Path -LiteralPath $copy -PathType Container)) {
        return ''
    }
    $trash = "$copy.deleting-$(Get-Date -Format yyyyMMddHHmmss)"
    for ($try = 1; $try -le $tries; $try++) {
        try {
            Rename-Item -LiteralPath $copy -NewName (Split-Path $trash -Leaf) -ErrorAction Stop
            return $trash
        } catch {
            if ($try -lt $tries) {
                Start-Sleep 1
            }
        }
    }
    return ''
}

# Whether $name is a folder that Rename-CopyToDelete made of a copy of the project $main: the only folders the server
# deletes again after its end cut a delete.
function Test-CopyToDelete([string] $main, [string] $name) {
    return $name -match "^$([regex]::Escape((Split-Path $main -Leaf)))-w\d+\.deleting-\d{14}$"
}

# The second half: the folder and all in it go for good, not to the recycle bin. `rd` and not Remove-Item: it takes a
# path longer than 260 characters with the `\\?\` prefix, it deletes read-only files (git's packs), and it deletes a
# link in the tree and never what the link points at (Windows PowerShell's Remove-Item empties the target). Throws
# when a part is still there.
function Remove-Tree([string] $folder) {
    & "$env:SystemRoot\System32\cmd.exe" /c "rd /s /q `"\\?\$folder`"" | Out-Null
    if (Test-Path -LiteralPath $folder) {
        throw "a part of $folder is still there"
    }
}
