# A queue script restarts itself on new code (docs/QUEUE.md): a pull of Scriptorium or of a plugin it loaded, a
# change to the project's scriptorium.json, or the files of a plugin it waited for (plugins.ps1, Get-MissingPlugins)
# ends the loop at its next safe point, and its own logon task starts it again. Dot-sourced by worker.ps1, merge.ps1
# and app/server.ps1.

# The folders and files watched: the install folder (without the plugins it holds, the tests and its .claude folder),
# then what Start-CodeWatch adds.
$script:watched = @()

# Every .ps1 under the watched folders but the tests, and each watched file: a change to any of them restarts the
# script, with no list to keep. The install's .claude folder is left out: a Claude Code worktree there is a whole
# checkout, and an edit in it is not new code of the install.
function Get-CodeStamp {
    $files = @(Get-ChildItem $PSScriptRoot -Recurse -Filter *.ps1 | Where-Object {
        $_.Name -notlike '*.test.ps1' -and $_.FullName -notlike (Join-Path $PSScriptRoot 'plugins/*') -and
            $_.FullName -notlike (Join-Path $PSScriptRoot 'tests/*') -and $_.FullName -notlike (Join-Path $PSScriptRoot '_source/*') -and
            $_.FullName -notlike (Join-Path $PSScriptRoot '.claude/*')
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

# Watches $paths too (the project's scriptorium.json, the loaded plugins' folders, where a plugin that is not
# installed yet will be) from now on. A path that is not there yet counts once it is.
function Start-CodeWatch([string[]] $paths) {
    $script:watched = @($paths | Where-Object { $_ })
    $script:codeAt = Get-CodeStamp
}

$script:codeAt = Get-CodeStamp

function Test-CodeChanged {
    return (Get-CodeStamp) -ne $script:codeAt
}

# Ends the wait of the scripts that watch $file (docs/QUEUE.md, Wakes). A write that fails (two scripts write at
# once) is no loss: the poll still comes.
function Send-Wake([string] $file) {
    try {
        [System.IO.File]::WriteAllText($file, '')
    } catch {
    }
}

# Through the task once this loop has ended (each task runs one instance), so the task still owns the loop. On macOS
# and Linux the exit code alone does it: launchd and systemd start the script again (tasks.ps1, Get-UnitText).
function Restart-OnNewCode([string] $Task) {
    if (-not $OnWindows) {
        exit $RestartCode
    }
    Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList ("--headless `"$(Get-ShellPath)`" -NoProfile " +
        "-Command `"Start-Sleep 10; Start-ScheduledTask -TaskName '$Task'`"")
    exit
}
