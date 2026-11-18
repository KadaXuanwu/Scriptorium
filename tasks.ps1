# The queue's logon tasks and the setup of one worker (docs/QUEUE.md): shared by setup.ps1 and the queue app's Add a
# worker and Remove (app/server.ps1). Dot-sourced; nothing runs on load.

. (Join-Path $PSScriptRoot 'project.ps1')
. (Join-Path $PSScriptRoot 'plugins.ps1')

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

# The projects that Scriptorium runs on this PC, each with its name and its page's port: from the logon tasks of the
# pages. The lookup takes half a second, so the page's server asks at its start and every few minutes.
function Get-PcProjects {
    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskName (Get-TaskName '*' 'app') -ErrorAction SilentlyContinue)) {
        try {
            $project = Read-Project (Get-TaskProject "$($task.Actions[0].Arguments)")
            $found += [pscustomobject]@{ name = [string]$project.name; port = [int]$project.port }
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
    $machine = $null
    $file = Join-Path $main '.queue\settings.json'
    if (Test-Path $file) {
        $machine = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
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

# A worker's task and loop end (the queue app's Remove). Stopping a task ends only its console host: the loop, and its
# run and editors with it, end by its project and its `-Id`.
function Uninstall-Worker([string] $main, [string] $name, [string] $id) {
    $task = Get-WorkerTaskName $name $id
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { (Test-ProjectProcess $_.CommandLine 'worker.ps1' $main) -and $_.CommandLine -match "-Id $id\b" } |
        ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }
}
