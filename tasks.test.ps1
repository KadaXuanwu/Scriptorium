# Checks tasks.ps1, what a worker's copy holds and its delete: powershell -NoProfile -File tasks.test.ps1
# (prints ok or throws).
$ErrorActionPreference = 'Stop'
# The PC's files of a test are in a folder of its own (pc.ps1): set before anything loads.
$PcDir = Join-Path $env:TEMP "scriptorium-test-$PID"
. (Join-Path $PSScriptRoot 'tasks.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# git with a fixed author and no word on the console. Its notes on the error stream do not stop the test.
function Run-Git([string] $dir) {
    $ErrorActionPreference = 'Continue'
    & git.exe -C $dir -c user.name=test -c user.email=test@example.com -c core.autocrlf=false @args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git $args failed in $dir"
    }
}

function Commit([string] $dir, [string] $file) {
    Set-Content (Join-Path $dir $file) $file -Encoding utf8
    Run-Git $dir add $file
    Run-Git $dir commit -m $file
}

$root = Join-Path $env:TEMP "scriptorium-tasks-test-$PID"
$remote = Join-Path $root 'remote.git'
$main = Join-Path $root 'App'
$copy = "$main-w1"
New-Item -ItemType Directory -Force $remote | Out-Null
Run-Git $remote init --bare
Run-Git $remote symbolic-ref HEAD refs/heads/main
Run-Git $root clone $remote $main
Run-Git $main checkout -b main
Commit $main 'first.txt'
Run-Git $main push -u origin main
Run-Git $root clone $remote $copy

# What the copy holds that GitHub does not have.
Assert-Equal (@(Get-CopyWork $copy) -join ' | ') '' 'a fresh copy holds nothing'
# A ticket branch that was pushed and merged: its GitHub branch is gone.
Run-Git $copy checkout -b t1
Commit $copy 't1.txt'
Run-Git $copy push -u origin t1
Run-Git $copy push origin --delete t1
Run-Git $copy fetch --prune
# One that was pushed, with a commit after the push.
Run-Git $copy checkout -b t2 origin/main
Commit $copy 't2.txt'
Run-Git $copy push -u origin t2
Commit $copy 't2b.txt'
# One that another worker rebased after the push: the commit here is ahead of GitHub's branch and holds nothing new.
Run-Git $copy checkout -b t4 origin/main
Commit $copy 't4.txt'
Run-Git $copy push -u origin t4
Run-Git $main fetch
Run-Git $main checkout t4
Run-Git $main commit --amend -m rebased
Run-Git $main push --force origin t4
Run-Git $copy fetch
Assert-Equal "$(& git.exe -C $copy rev-list --count t4 --not origin/t4)" '1' 'the rebased branch here is ahead of GitHub''s branch'
# One that was never pushed.
Run-Git $copy checkout --no-track -b t3 origin/main
Commit $copy 't3.txt'
Commit $copy 't3b.txt'
Run-Git $copy checkout --detach origin/main
Assert-Equal (@(Get-CopyWork $copy) -join ' | ') 'commits not pushed on t2: 1 | commits not pushed on t3: 2' 'a merged branch does not count; a branch ahead of GitHub and one never pushed do'
Commit $copy 'loose.txt'
Assert-Equal (@(Get-CopyWork $copy) -join ' | ') 'commits on no branch: 1 | commits not pushed on t2: 1 | commits not pushed on t3: 2' 'a commit on no branch'
Run-Git $copy checkout --detach origin/main
Set-Content (Join-Path $copy 'first.txt') 'changed' -Encoding utf8
Run-Git $copy stash
foreach ($name in 'a.txt', 'b.txt', 'c.txt', 'd.txt') {
    Set-Content (Join-Path $copy $name) $name -Encoding utf8
}
Set-Content (Join-Path $copy 'first.txt') 'changed again' -Encoding utf8
Assert-Equal @(Get-CopyWork $copy)[0] 'changed files: first.txt, a.txt, b.txt and 2 more' 'the changed files by name, the first three'
Assert-Equal @(Get-CopyWork $copy)[1] 'stashes: 1' 'a stash'
Assert-Equal (@(Get-CopyWork $root) -join ' | ') 'it is no git checkout, so nothing in it was checked' 'a folder that is no checkout'

# The rename: only a worker's copy, and never while a program uses a file in it.
Assert-Equal (Rename-CopyToDelete $main '2') '' 'a worker with no copy'
Assert-Equal (Rename-CopyToDelete $main '1\..\App') '' 'a number only: nothing else becomes a path'
$open = [System.IO.File]::Open((Join-Path $copy 'a.txt'), 'Open', 'Read', 'None')
try {
    Assert-Equal (Rename-CopyToDelete $main '1' 1) '' 'a copy that a program uses stays'
} finally {
    $open.Close()
}
Assert-Equal (Test-Path -LiteralPath $copy) $true 'the used copy has its name still'
$trash = Rename-CopyToDelete $main '1'
Assert-Equal "$(Test-Path -LiteralPath $copy) $(Test-Path -LiteralPath $trash)" 'False True' 'the copy has the name to delete, and its own name is free'
Assert-Equal (Test-CopyToDelete $main (Split-Path $trash -Leaf)) $true 'a folder to delete, by its name'
Assert-Equal "$(Test-CopyToDelete $main 'App-w1') $(Test-CopyToDelete $main 'App-w1.deleting-old') $(Test-CopyToDelete $main 'Other-w1.deleting-20260101000000') $(Test-CopyToDelete $main 'App.deleting-20260101000000')" 'False False False False' 'no other folder is one'

# The delete: a path longer than 260 characters, a read-only file (git's packs are too), and a link out of the tree.
$long = "\\?\$trash"
1..6 | ForEach-Object { $long += '\' + ('d' * 50) }
[System.IO.Directory]::CreateDirectory($long) | Out-Null
[System.IO.File]::WriteAllText("$long\deep.txt", 'deep')
Set-ItemProperty (Join-Path $trash 'b.txt') IsReadOnly $true
$outside = Join-Path $root 'outside'
New-Item -ItemType Directory -Force $outside | Out-Null
Set-Content (Join-Path $outside 'keep.txt') 'keep' -Encoding utf8
New-Item -ItemType Junction -Path (Join-Path $trash 'link') -Target $outside | Out-Null
Assert-Equal (Test-Path -LiteralPath (Join-Path $trash 'link\keep.txt')) $true 'the link shows the outside file'
Remove-Tree $trash
Assert-Equal (Test-Path -LiteralPath $trash) $false 'the folder is gone'
Assert-Equal (Get-Content (Join-Path $outside 'keep.txt')) 'keep' 'what a link points at stays'
Assert-Equal (Test-Path -LiteralPath $main) $true 'the main checkout stays'

Remove-Tree $root
'ok'
