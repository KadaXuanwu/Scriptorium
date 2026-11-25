# Checks restart.ps1, what restarts a script: powershell -NoProfile -File tests/restart.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# Get-CodeStamp reads the folder of restart.ps1 itself, so the install here is a folder with a copy of it.
$root = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-restart-test-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
try {
    Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'restart.ps1') $root
    . (Join-Path $root 'restart.ps1')
    Assert-Equal (Test-CodeChanged) 'False' 'no change yet'

    # A Claude Code worktree of the install is a whole checkout under .claude: its scripts are not the install's.
    $worktree = Join-Path $root '.claude/worktrees/one'
    New-Item -ItemType Directory -Force $worktree | Out-Null
    Set-Content (Join-Path $worktree 'worker.ps1') '# a session''s edit' -Encoding utf8
    Assert-Equal (Test-CodeChanged) 'False' 'a script under .claude of the install'

    Set-Content (Join-Path $root 'worker.ps1') '# a pull' -Encoding utf8
    Assert-Equal (Test-CodeChanged) 'True' 'a script of the install'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'ok'
