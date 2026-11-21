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

# A login's credentials as Claude Code keeps them, as text: '' while it is signed out. $configDir '' is the
# command-line login (~/.claude). Windows and Linux keep them in the folder's .credentials.json, macOS in the login
# keychain, under a name with a hash of the folder for any folder but the default one.
# shortcut: the keychain name (the first 8 hex digits of the SHA-256 of the folder's path) is what other tools found,
# not a documented contract; if a Mac shows every account signed out, compare with `security dump-keychain | grep Claude`.
function Get-CredentialsText([string] $configDir) {
    $dir = if ($configDir) { $configDir } else { Join-Path $HOME '.claude' }
    $file = Join-Path $dir '.credentials.json'
    if (Test-Path $file) {
        return [string](Get-Content $file -Raw -Encoding UTF8)
    }
    if (-not $OnMac) {
        return ''
    }
    $service = 'Claude Code-credentials'
    if ($configDir) {
        $service += '-' + (Get-TextHash $configDir).Substring(0, 8)
    }
    $ErrorActionPreference = 'Continue'
    $text = & /usr/bin/security find-generic-password -s $service -w 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return ($text -join "`n")
}

# The credentials as an object, $null while signed out or unreadable.
function Read-Credentials([string] $configDir) {
    $text = Get-CredentialsText $configDir
    if (-not $text.Trim()) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        return $null
    }
}

# What changes when the login changes (a sign-in, a refresh): the file's time, or a hash of the keychain's text.
function Get-CredentialsStamp([string] $configDir) {
    $dir = if ($configDir) { $configDir } else { Join-Path $HOME '.claude' }
    $file = Join-Path $dir '.credentials.json'
    if (Test-Path $file) {
        return [string](Get-Item $file).LastWriteTimeUtc.Ticks
    }
    $text = Get-CredentialsText $configDir
    if (-not $text) {
        return '0'
    }
    return Get-TextHash $text
}

# The SHA-256 of a text, in lowercase hex.
function Get-TextHash([string] $text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}
