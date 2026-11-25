# What differs between Windows and macOS or Linux, in one place (README.md, What it needs). Windows runs the scripts in
# Windows PowerShell 5.1, macOS and Linux in PowerShell 7 (pwsh), so the code runs in both. Dot-sourced through
# pc.ps1; only definitions.

# $IsWindows and $IsMacOS are not there in Windows PowerShell 5.1.
$OnWindows = $env:OS -eq 'Windows_NT'
$OnMac = -not $OnWindows -and [bool]$IsMacOS
# The exit code of a script that restarts on new code on macOS or Linux (restart.ps1): launchd and systemd start it
# again (tasks.ps1, Get-UnitText).
$RestartCode = 75

# The program that runs the scripts: Windows PowerShell on Windows, the pwsh that runs this one elsewhere.
function Get-ShellPath {
    if ($OnWindows) {
        return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    return (Get-Process -Id $PID).Path
}

# Every process with its command line: ProcessId, ParentProcessId, CommandLine. -Shells: on Windows only the Windows
# PowerShell processes, a faster lookup for the queue's own scripts.
function Get-CommandLines([switch] $Shells) {
    if ($OnWindows) {
        $found = if ($Shells) { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" } else { Get-CimInstance Win32_Process }
        return @($found | Select-Object ProcessId, ParentProcessId, CommandLine)
    }
    return @(& /bin/ps -A -ww -o 'pid=' -o 'ppid=' -o 'args=' | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(\d+)\s+(.*)$') {
            [pscustomobject]@{ ProcessId = [int]$Matches[1]; ParentProcessId = [int]$Matches[2]; CommandLine = $Matches[3] }
        }
    })
}

# Ends a process and every process it started, at once.
function Stop-ProcessTree([int] $id) {
    if ($OnWindows) {
        & taskkill /T /F /PID $id | Out-Null
        return
    }
    $all = Get-CommandLines
    $tree = @($id)
    for ($i = 0; $i -lt $tree.Count; $i++) {
        $tree += @($all | Where-Object { $_.ParentProcessId -eq $tree[$i] } | ForEach-Object { $_.ProcessId })
    }
    foreach ($one in $tree) {
        Stop-Process -Id $one -Force -ErrorAction SilentlyContinue
    }
}
