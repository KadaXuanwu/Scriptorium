# Checks handback.ps1: powershell -NoProfile -File tests/handback.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'handback.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# Test-HandBack: a ticket, held for the plan's own limit, `handBack` set, and both the hold's reset and the account's
# room further away than it. $now is 1000 and `handBack` 2 hours, so "far" is after 8200.
$limited = @{ Limited = $true }
$case = { param($end, $kind, $resetsAt, $roomAt, $hours) Test-HandBack $end $kind $resetsAt $roomAt 1000 $hours }
Assert-Equal (& $case $limited 'ticket' 9000 9000 2) $true 'a long hold of a ticket'
Assert-Equal (& $case $limited 'ticket' 9000 9000 0) $false 'handBack left out'
Assert-Equal (& $case $limited 'ticket' 8200 9000 2) $false 'a hold of exactly that length'
Assert-Equal (& $case $limited 'ticket' 9000 0 2) $false 'no full window in the reading: its workers would take the ticket again'
Assert-Equal (& $case $limited 'ticket' 9000 5000 2) $false 'the account has room sooner'
Assert-Equal (& $case $limited 'answered' 9000 9000 2) $false 'a PR''s job stays its worker''s'
Assert-Equal (& $case @{ Limited = $false; AtLimit = $true } 'ticket' 9000 9000 2) $false 'held at the workers'' line'
foreach ($mark in 'LoggedOut', 'AtLimit', 'Stopped') {
    Assert-Equal (& $case @{ Limited = $true; $mark = $true } 'ticket' 9000 9000 2) $false "a limited run that is $mark"
}
Assert-Equal (& $case @{ Limited = $true; ModelOut = 'deep' } 'ticket' 9000 9000 2) $false 'a model''s window'

# Save-TicketWork, on a copy of a repo with a bare remote. git with a fixed author and no word on the console.
function Run-Git([string] $dir) {
    $ErrorActionPreference = 'Continue'
    & git -C $dir -c user.name=test -c user.email=test@example.com -c core.autocrlf=false @args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git $args failed in $dir"
    }
}
function Try-Save([string] $dir, [string] $branch) {
    try {
        return Save-TicketWork $dir $branch 'WIP'
    } catch {
        return "threw: $_"
    }
}
$root = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-handback-test-$PID"
$remote = Join-Path $root 'remote.git'
$main = Join-Path $root 'App'
$copy = "$main-w1"
try {
    New-Item -ItemType Directory -Force $remote | Out-Null
    Run-Git $remote init --bare
    Run-Git $remote symbolic-ref HEAD refs/heads/main
    Run-Git $root clone $remote $main
    Run-Git $main checkout -b main
    Set-Content (Join-Path $main 'first.txt') 'first' -Encoding utf8
    Run-Git $main add first.txt
    Run-Git $main commit -m first
    Run-Git $main push -u origin main
    Run-Git $root clone $remote $copy
    foreach ($key in 'user.name=test', 'user.email=test@example.com', 'core.autocrlf=false') {
        Run-Git $copy config $key.Split('=')[0] $key.Split('=')[1]
    }

    # A branch with nothing of its own: nothing to save, and GitHub gets no branch.
    Run-Git $copy checkout -b t7 origin/main
    Assert-Equal (Try-Save $copy 't7') '' 'a branch with no work'
    Assert-Equal "$(& git -C $remote branch --list t7)" '' 'no branch on GitHub for it'
    # A changed file and a new one: both arrive in one commit on GitHub's branch.
    Set-Content (Join-Path $copy 'first.txt') 'changed' -Encoding utf8
    Set-Content (Join-Path $copy 'new.txt') 'new' -Encoding utf8
    $commit = Try-Save $copy 't7'
    Assert-Equal $commit "$(& git -C $remote rev-parse t7)" 'the commit that GitHub''s branch holds'
    Assert-Equal "$(& git -C $remote show t7:first.txt) $(& git -C $remote show t7:new.txt) $(& git -C $remote rev-list --count t7 --not main)" 'changed new 1' 'a changed and a new file, in one commit'
    Assert-Equal "$(& git -C $copy status --porcelain)" '' 'the copy holds nothing more'
    # Nothing new since: the same commit, and no second one.
    Assert-Equal (Try-Save $copy 't7') $commit 'work that is on GitHub already'
    # A commit that was not pushed goes too.
    Set-Content (Join-Path $copy 'more.txt') 'more' -Encoding utf8
    Run-Git $copy add more.txt
    Run-Git $copy commit -m more
    Assert-Equal (Try-Save $copy 't7') "$(& git -C $remote rev-parse t7)" 'a commit that was not pushed'
    Assert-Equal "$(& git -C $remote show t7:more.txt)" 'more' 'its file is on GitHub'

    # Changes on another branch than the ticket's are not the ticket's: nothing is committed.
    Run-Git $copy checkout --detach origin/main
    Assert-Equal (Try-Save $copy 't7') '' 'a clean copy on another branch'
    Set-Content (Join-Path $copy 'stray.txt') 'stray' -Encoding utf8
    Assert-Equal ((Try-Save $copy 't7') -like 'threw: *') $true 'changes on another branch'
    Assert-Equal "$(& git -C $copy status --porcelain)" '?? stray.txt' 'they stay as they are'
    Remove-Item (Join-Path $copy 'stray.txt')

    # GitHub's branch moved on (another worker pushed): the push is refused, never forced, and nothing is lost here.
    Run-Git $main fetch
    Run-Git $main checkout t7
    Set-Content (Join-Path $main 'other.txt') 'other' -Encoding utf8
    Run-Git $main add other.txt
    Run-Git $main commit -m other
    Run-Git $main push origin t7
    $theirs = "$(& git -C $remote rev-parse t7)"
    Run-Git $copy checkout t7
    Set-Content (Join-Path $copy 'late.txt') 'late' -Encoding utf8
    Assert-Equal ((Try-Save $copy 't7') -like 'threw: *') $true 'a push that GitHub refuses'
    Assert-Equal "$(& git -C $remote rev-parse t7)" $theirs 'GitHub''s branch is as the other worker left it'
    Assert-Equal "$(& git -C $copy show HEAD:late.txt)" 'late' 'the work is committed in the copy'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

'ok'
