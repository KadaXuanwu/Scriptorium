# A queue script restarts itself on new code (docs/QUEUE.md): a pull of Scriptorium or of a plugin it loaded, or a
# change to the project's scriptorium.json, ends the loop at its next safe point, and its own logon task starts it
# again. Dot-sourced by worker.ps1, merge.ps1 and app/server.ps1.

# The folders and files watched: the install folder (without the plugins it holds and the tests), then what
# Start-CodeWatch adds.
$script:watched = @()

# Every .ps1 under the watched folders but the tests, and each watched file: a change to any of them restarts the
# script, with no list to keep.
function Get-CodeStamp {
    $files = @(Get-ChildItem $PSScriptRoot -Recurse -Filter *.ps1 | Where-Object {
        $_.Name -notlike '*.test.ps1' -and $_.FullName -notlike "$PSScriptRoot\plugins\*" -and $_.FullName -notlike "$PSScriptRoot\_source\*"
    })
    foreach ($path in $script:watched) {
        if (Test-Path $path -PathType Container) {
            $files += @(Get-ChildItem $path -Recurse -Filter *.ps1 | Where-Object { $_.Name -notlike '*.test.ps1' })
        } elseif (Test-Path $path) {
            $files += Get-Item $path
        }
    }
    return ($files | Sort-Object FullName -Unique | ForEach-Object { "$($_.FullName)=$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
}

# Watches $paths too (the project's scriptorium.json, the loaded plugins' folders) from now on.
function Start-CodeWatch([string[]] $paths) {
    $script:watched = @($paths | Where-Object { $_ })
    $script:codeAt = Get-CodeStamp
}

$script:codeAt = Get-CodeStamp

function Test-CodeChanged {
    return (Get-CodeStamp) -ne $script:codeAt
}

# Through the task once this loop has ended (each task runs one instance), so the task still owns the loop.
function Restart-OnNewCode([string] $Task) {
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList ("--headless `"$powershell`" -NoProfile " +
        "-Command `"Start-Sleep 10; Start-ScheduledTask -TaskName '$Task'`"")
    exit
}
