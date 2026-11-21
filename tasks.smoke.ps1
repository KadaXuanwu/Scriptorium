# Registers a logon task on macOS or Linux, starts it, sees it start again after a restart on new code, and removes
# it: the launchd and systemd half of tasks.ps1 for real. CI runs it (.github/workflows/test.yml) and nothing else
# should: it adds and removes the task `Scriptorium Smoke app` on the PC.
$ErrorActionPreference = 'Stop'
if (-not $env:CI) {
    throw 'tasks.smoke.ps1 runs in CI only: it registers a logon task.'
}
. (Join-Path $PSScriptRoot 'tasks.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

function Wait-Until([scriptblock] $test, [int] $seconds = 60) {
    for ($i = 0; $i -lt $seconds; $i++) {
        if (& $test) {
            return $true
        }
        Start-Sleep 1
    }
    return $false
}

$dir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-smoke-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
$dir = Resolve-Project $dir
$starts = Join-Path $dir 'starts.txt'
$script = Join-Path $dir 'once.ps1'
# The first start exits as a restart on new code does; the second stays.
Set-Content $script @'
param([string] $Project)
$file = Join-Path $Project 'starts.txt'
Add-Content $file 'start'
if (@(Get-Content $file).Count -eq 1) {
    exit 75
}
Start-Sleep 600
'@
$name = 'Scriptorium Smoke app'
$running = { @(Get-CommandLines | Where-Object { Test-ProjectProcess $_.CommandLine 'once.ps1' $dir }).Count -gt 0 }
try {
    Register-QueueTask $name "-File `"$script`" -Project `"$dir`"" $dir
    $task = Get-QueueTasks 'Scriptorium Smoke *'
    Assert-Equal "$($task.TaskName)|$(Get-TaskProject $task.Arguments)" "$name|$dir" 'the task is listed with its project'
    Start-QueueTask $name
    Assert-Equal (Wait-Until { (Test-Path $starts) -and @(Get-Content $starts).Count -ge 2 }) $true 'the script started, exited for a restart and started again'
    Assert-Equal (& $running) $true 'the process lookup finds it'
} catch {
    Write-Output (Get-Content (Get-UnitFile $name) -Raw -ErrorAction SilentlyContinue)
    $ErrorActionPreference = 'Continue'
    if ($OnMac) {
        & launchctl print "gui/$(& id -u)/$([IO.Path]::GetFileNameWithoutExtension((Get-UnitFile $name)))" 2>&1 | Select-Object -First 40
    } else {
        & systemctl --user status (Split-Path (Get-UnitFile $name) -Leaf) 2>&1 | Select-Object -First 40
    }
    throw
} finally {
    Remove-QueueTask $name
}
Assert-Equal @(Get-QueueTasks 'Scriptorium Smoke *').Count 0 'the task is gone'
Assert-Equal (Wait-Until { -not (& $running) } 15) $true 'and its script has ended'
Remove-Tree $dir
'ok'
