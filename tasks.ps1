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

# The queue's logon tasks: each runs one script with $arguments (`-File "<script>" -Project "<main>" ...`) at the owner's
# logon, one instance each, no time limit (a ticket can take hours). On Windows a scheduled task, through a headless
# console: with Windows Terminal as the default terminal, powershell's -WindowStyle Hidden still opens a window, and
# closing it kills the task. On macOS a launchd agent, on Linux a systemd user service: a file each in $UnitDir, which
# names the task and its arguments in two comment lines (Get-UnitText), so Get-QueueTasks reads them back.
$UnitDir = if ($OnMac) { Join-Path $HOME 'Library/LaunchAgents' } else { Join-Path $HOME '.config/systemd/user' }

function Register-QueueTask([string] $name, [string] $arguments, [string] $main) {
    if ($OnWindows) {
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -WorkingDirectory $main `
            -Argument "--headless `"$(Get-ShellPath)`" -NoProfile -ExecutionPolicy Bypass $arguments"
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
        return
    }
    New-Item -ItemType Directory -Force $UnitDir | Out-Null
    $file = Get-UnitFile $name
    # No byte order mark: launchd and systemd read plain UTF-8.
    [System.IO.File]::WriteAllText($file, (Get-UnitText $name $arguments $main (Get-ShellPath) $env:PATH $OnMac),
        (New-Object System.Text.UTF8Encoding $false))
    if (-not $OnMac) {
        Invoke-Native 'systemctl' @('--user', 'daemon-reload') | Out-Null
        Invoke-Native 'systemctl' @('--user', 'enable', (Split-Path $file -Leaf)) | Out-Null
    }
}

# A task's file on macOS or Linux: `scriptorium-<name>-worker-3.plist` or `.service`.
function Get-UnitFile([string] $name) {
    $id = ($name -replace '[^A-Za-z0-9]+', '-').ToLowerInvariant()
    return Join-Path $UnitDir "$id$(if ($OnMac) { '.plist' } else { '.service' })"
}

# The arguments of a task as a list: a quoted part is one argument without its quotes.
function Split-Arguments([string] $arguments) {
    return @([regex]::Matches($arguments, '"([^"]*)"|(\S+)') | ForEach-Object { "$($_.Groups[1].Value)$($_.Groups[2].Value)" })
}

# The text of a task's launchd agent ($mac) or systemd service, with the PATH of setup's shell: a service gets almost
# none of its own, and git, gh and claude are often in Homebrew's or ~/.local/bin. The script starts again after a
# restart on new code (restart.ps1, $RestartCode): launchd starts an agent again after any exit that is not 0, systemd
# only after that code.
function Get-UnitText([string] $name, [string] $arguments, [string] $main, [string] $shell, [string] $path, [bool] $mac) {
    $all = @($shell, '-NoProfile') + @(Split-Arguments $arguments)
    if ($mac) {
        $escape = { param($text) [System.Security.SecurityElement]::Escape($text) }
        $label = ($name -replace '[^A-Za-z0-9]+', '-').ToLowerInvariant()
        return (@('<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            "<!-- Scriptorium-Task: $(& $escape $name) -->",
            "<!-- Scriptorium-Arguments: $(& $escape $arguments) -->",
            '<plist version="1.0">', '<dict>',
            "  <key>Label</key><string>$label</string>",
            '  <key>ProgramArguments</key>', '  <array>') +
            @($all | ForEach-Object { "    <string>$(& $escape $_)</string>" }) +
            @('  </array>',
            "  <key>WorkingDirectory</key><string>$(& $escape $main)</string>",
            "  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(& $escape $path)</string></dict>",
            '  <key>RunAtLoad</key><true/>',
            '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>',
            '  <key>ThrottleInterval</key><integer>10</integer>',
            '</dict>', '</plist>', '')) -join "`n"
    }
    # systemd reads % and $ in a value as its own: doubled, they stay themselves.
    $escape = { param($text) $text.Replace('%', '%%').Replace('$', '$$') }
    $exec = ($all | ForEach-Object { '"' + (& $escape $_).Replace('\', '\\').Replace('"', '\"') + '"' }) -join ' '
    return (@("# Scriptorium-Task: $name",
        "# Scriptorium-Arguments: $arguments",
        '[Unit]', "Description=$name", '',
        '[Service]',
        "WorkingDirectory=$(& $escape $main)",
        "Environment=`"PATH=$(& $escape $path)`"",
        "ExecStart=$exec",
        'Restart=no',
        "RestartForceExitStatus=$RestartCode",
        'RestartSec=10', '',
        '[Install]', 'WantedBy=default.target', '')) -join "`n"
}

# The name and the arguments that a task's file names (Get-UnitText), or $null for a file of another kind.
function Read-UnitText([string] $text) {
    $name = [regex]::Match($text, '(?m)^(?:# |<!-- )Scriptorium-Task: (.*?)(?: -->)?\r?$')
    $arguments = [regex]::Match($text, '(?m)^(?:# |<!-- )Scriptorium-Arguments: (.*?)(?: -->)?\r?$')
    if (-not $name.Success) {
        return $null
    }
    $xml = $text.StartsWith('<')
    $decode = { param($value) if ($xml) { [System.Net.WebUtility]::HtmlDecode($value) } else { $value } }
    return [pscustomobject]@{ TaskName = (& $decode $name.Groups[1].Value); Arguments = (& $decode $arguments.Groups[1].Value) }
}

# The queue's tasks on this PC whose name is like $pattern (`Scriptorium * worker *`), each with TaskName and the
# Arguments it runs with.
function Get-QueueTasks([string] $pattern = 'Scriptorium *') {
    if ($OnWindows) {
        return @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ TaskName = $_.TaskName; Arguments = "$($_.Actions[0].Arguments)" } })
    }
    return @(Get-ChildItem $UnitDir -Filter 'scriptorium-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Read-UnitText ([System.IO.File]::ReadAllText($_.FullName)) } |
        Where-Object { $_ -and $_.TaskName -like $pattern })
}

# Starts a task now. Nothing when it runs already.
function Start-QueueTask([string] $name) {
    if ($OnWindows) {
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        return
    }
    $file = Get-UnitFile $name
    if (-not $OnMac) {
        Invoke-Native 'systemctl' @('--user', 'start', (Split-Path $file -Leaf)) | Out-Null
        return
    }
    # A new agent loads at the next logon by itself; loaded now, it starts (RunAtLoad).
    $domain = "gui/$(& id -u)"
    $label = [IO.Path]::GetFileNameWithoutExtension($file)
    $ErrorActionPreference = 'Continue'
    & launchctl print "$domain/$label" *> $null
    $loaded = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if ($loaded) {
        Invoke-Native 'launchctl' @('kickstart', "$domain/$label") | Out-Null
    } else {
        Invoke-Native 'launchctl' @('bootstrap', $domain, $file) | Out-Null
    }
}

# Stops a task and removes it. On Windows stopping ends only its console host (Uninstall-Worker); launchd and systemd
# end the script too.
function Remove-QueueTask([string] $name) {
    if ($OnWindows) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        return
    }
    $file = Get-UnitFile $name
    if (-not (Test-Path $file)) {
        return
    }
    $ErrorActionPreference = 'Continue'
    if ($OnMac) {
        & launchctl bootout "gui/$(& id -u)/$([IO.Path]::GetFileNameWithoutExtension($file))" *> $null
    } else {
        & systemctl --user disable --now (Split-Path $file -Leaf) *> $null
    }
    Remove-Item $file
    if (-not $OnMac) {
        & systemctl --user daemon-reload *> $null
    }
    $ErrorActionPreference = 'Stop'
}

# The projects that Scriptorium runs on this PC, each with its name, its page's port and its main checkout (`main`):
# from the logon tasks of the pages. The lookup takes half a second, so the page's server asks at its start and every
# few minutes. `main` stays on the server: the page gets the views (state.ps1, Get-ProjectViews).
function Get-PcProjects {
    $found = @()
    foreach ($task in Get-QueueTasks (Get-TaskName '*' 'app')) {
        try {
            $main = Resolve-Project (Get-TaskProject $task.Arguments)
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
    return "-File `"$(Join-Path $PSScriptRoot 'worker.ps1')`" $(Get-ProjectArg $main) -Id $id -Clone `"$clone`""
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
    Start-QueueTask (Get-WorkerTaskName $name $id)
}

# A worker's task and loop end (the queue app's Remove and a worker's move to another project). Stopping a task ends
# only its console host: the loop, and its run with it, end by its project and its `-Id`. Then every process that still
# runs from its copy ends: its editor is not in the loop's process tree and stays open after the loop (measured).
function Uninstall-Worker([string] $main, [string] $name, [string] $id) {
    Remove-QueueTask (Get-WorkerTaskName $name $id)
    Get-CommandLines -Shells |
        Where-Object { (Test-ProjectProcess $_.CommandLine 'worker.ps1' $main) -and $_.CommandLine -match "-Id $id\b" } |
        ForEach-Object { Stop-ProcessTree $_.ProcessId }
    Get-CommandLines |
        Where-Object { $_.ProcessId -ne $PID -and (Test-CopyProcess $_.CommandLine "$main-w$id") } |
        ForEach-Object { Stop-ProcessTree $_.ProcessId }
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

# The second half: the folder and all in it go for good, not to the recycle bin. On Windows `rd` and not Remove-Item:
# it takes a path longer than 260 characters with the `\\?\` prefix, it deletes read-only files (git's packs), and it
# deletes a link in the tree and never what the link points at (Windows PowerShell's Remove-Item empties the target).
# `rm -rf` does the same elsewhere. Throws when a part is still there.
function Remove-Tree([string] $folder) {
    if ($OnWindows) {
        & "$env:SystemRoot\System32\cmd.exe" /c "rd /s /q `"\\?\$folder`"" | Out-Null
    } else {
        & /bin/rm -rf -- $folder
    }
    if (Test-Path -LiteralPath $folder) {
        throw "a part of $folder is still there"
    }
}
