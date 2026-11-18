# The queue's logon tasks and the setup of one worker (docs/QUEUE.md): shared by setup.ps1 and the queue app's Add a
# worker and Remove (app/server.ps1). Dot-sourced; nothing runs on load.

. (Join-Path $PSScriptRoot 'project.ps1')

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

function Get-WorkerTaskName([string] $name, [string] $id) {
    return Get-TaskName $name "worker $id"
}

function Get-WorkerArguments([string] $main, [string] $id, [string] $clone, [string] $unityEditors) {
    return "-File `"$PSScriptRoot\worker.ps1`" $(Get-ProjectArg $main) -Id $id -Clone `"$clone`" -UnityEditors `"$unityEditors`""
}

# The Unity editors folder setup.ps1 gave the workers, from a worker's task; Unity Hub's default without one.
function Get-UnityEditors([string] $name) {
    foreach ($task in @(Get-ScheduledTask -TaskName (Get-WorkerTaskName $name '*') -ErrorAction SilentlyContinue)) {
        if ($task.Actions[0].Arguments -match '-UnityEditors "([^"]+)"') {
            return $Matches[1]
        }
    }
    return 'C:\Program Files\Unity\Hub\Editor'
}

# .gitattributes routes Unity's YAML through this driver; the driver itself is per checkout.
function Set-YamlMerge([string] $checkout, [string] $main, [string] $unityEditors) {
    $version = ((Get-Content (Join-Path $main 'Unity\ProjectSettings\ProjectVersion.txt'))[0] -split ' ')[1]
    $yamlMerge = (Join-Path $unityEditors "$version\Editor\Data\Tools\UnityYAMLMerge.exe").Replace('\', '/')
    & git -C $checkout config merge.unityyamlmerge.name 'Unity SmartMerge'
    & git -C $checkout config merge.unityyamlmerge.driver "'$yamlMerge' merge -h -p --force %O %B %A %A"
    & git -C $checkout config merge.unityyamlmerge.recursive binary
}

# The Asset Store packages a new clone lacks (Unity/AssetStore.json): they are not in git, and a fresh clone cannot
# import them alone (AI/PACKAGES.md). Copied from the main checkout, root folder and its .meta; then our patched files
# go back to what git has.
function Copy-AssetStorePackages([string] $main, [string] $clone) {
    foreach ($package in (Get-Content (Join-Path $main 'Unity\AssetStore.json') -Raw -ErrorAction Stop | ConvertFrom-Json).Packages) {
        $from = (Join-Path $main "Unity\$($package.Root)").Replace('/', '\')
        $to = (Join-Path $clone "Unity\$($package.Root)").Replace('/', '\')
        if (-not (Test-Path $from) -or (Test-Path (Join-Path $clone "Unity\$($package.Probe)"))) {
            continue
        }
        & robocopy $from $to /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "copying $($package.Root) into $clone failed"
        }
        Copy-Item "$from.meta" "$to.meta" -ErrorAction SilentlyContinue
        # Only a root with tracked files: on none, git checkout writes an error.
        if (& git -C $clone ls-files -- "Unity/$($package.Root)") {
            & git -C $clone checkout -- "Unity/$($package.Root)"
        }
    }
}

# One worker more (the queue app's Add a worker): its clone beside the main checkout (one left by a removed worker of
# that number is used again) with the Asset Store packages, Unity's YAML merge in it, its `worker:N` label in this repo
# and in each repo a `repo:<Name>` label names, and its logon task, started. Throws at the first step that fails.
function Install-Worker([string] $main, [string] $name, [string] $slug, [string] $id, [string] $unityEditors) {
    $clone = "$main-w$id"
    if (-not (Test-Path $clone)) {
        & git clone --quiet (& git -C $main remote get-url origin) $clone
        if ($LASTEXITCODE -ne 0) {
            throw "git clone into $clone failed"
        }
    }
    Copy-AssetStorePackages $main $clone
    Set-YamlMerge $clone $main $unityEditors
    $repos = @($slug) + @(& gh label list -R $slug --search 'repo:' --limit 100 --json name -q '.[].name' |
        Where-Object { $_ -like 'repo:*' } | ForEach-Object { "$($slug.Split('/')[0])/$($_.Substring(5))" })
    foreach ($repo in $repos) {
        & gh label create "worker:$id" --color 0e8a16 --description "Claimed by worker $id" --force -R $repo | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "the label worker:$id could not be made in $repo"
        }
    }
    Register-QueueTask (Get-WorkerTaskName $name $id) (Get-WorkerArguments $main $id $clone $unityEditors) $main
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
