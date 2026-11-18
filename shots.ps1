# Pictures for a question to the owner (PLAYBOOK.md, Pictures): puts PNG or JPEG files on the branch
# shots-t<ticket>, never on the ticket's branch or main, and prints a markdown line for each, to paste into the question.
# GitHub and the queue app show them. Run in the worker's clone, with the path of the Scriptorium folder:
#   powershell -NoProfile -File <Scriptorium>/shots.ps1 -Ticket 12 shots/header-a.png shots/header-b.png
# A file with the name of one already there replaces it. Plumbing with a temporary index, so the clone's checkout, index
# and branch stay as they are.
param(
    [Parameter(Mandatory)] [int] $Ticket,
    [Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Files
)
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    $out = & git @args
    if ($LASTEXITCODE) {
        throw "git $($args -join ' ') failed"
    }
    return $out
}

$branch = "shots-t$Ticket"
$paths = foreach ($file in $Files) {
    $path = (Resolve-Path $file).Path
    $name = Split-Path $path -Leaf
    # The queue app serves only these names (app/server.ps1, /api/shot).
    if ($name -notmatch '^[\w.-]+\.(png|jpe?g)$') {
        throw "$name`: use a PNG or JPEG named with letters, digits, '.', '-' and '_' only"
    }
    $path
}
# The clone the run works in: the current folder's repo, never the Scriptorium folder.
Set-Location (Invoke-Git rev-parse --show-toplevel)
$slug = & gh repo view --json nameWithOwner -q .nameWithOwner
$index = Join-Path ([System.IO.Path]::GetTempPath()) "shots-$Ticket-$PID.index"
$oldIndex = $env:GIT_INDEX_FILE
$env:GIT_INDEX_FILE = $index
try {
    # No such branch yet is no fault. Windows PowerShell turns a program's error text into a stop when it is redirected.
    $ErrorActionPreference = 'Continue'
    & git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/$branch" 2>$null
    $fetched = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    $parent = @()
    if ($fetched) {
        Invoke-Git read-tree "origin/$branch" | Out-Null
        $parent = @('-p', "origin/$branch")
    }
    foreach ($path in $paths) {
        # The picture itself, not a Git LFS pointer: .gitattributes may put PNG and JPEG in LFS, which GitHub's API
        # and its pages then show as the pointer's text.
        $blob = Invoke-Git hash-object -w --no-filters -- $path
        Invoke-Git update-index --add --cacheinfo "100644,$blob,$(Split-Path $path -Leaf)" | Out-Null
    }
    $tree = Invoke-Git write-tree
    $commit = Invoke-Git commit-tree $tree @parent -m "Pictures for #$Ticket"
    Invoke-Git push -q origin "${commit}:refs/heads/$branch" | Out-Null
} finally {
    $env:GIT_INDEX_FILE = $oldIndex
    Remove-Item $index -ErrorAction SilentlyContinue
}
foreach ($path in $paths) {
    $name = Split-Path $path -Leaf
    "![$([System.IO.Path]::GetFileNameWithoutExtension($name))](https://github.com/$slug/blob/$branch/${name}?raw=true)"
}
