# Checks comments.ps1: powershell -NoProfile -File comments.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'comments.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

function New-Comment([string] $body, [int] $eyes) {
    return [pscustomobject]@{ body = $body; reactions = [pscustomobject]@{ eyes = $eyes } }
}

$file = Join-Path ([IO.Path]::GetTempPath()) "comments-test-$PID.md"
Remove-Item $file -ErrorAction SilentlyContinue

# An unread owner comment writes the note.
$unread = @(Select-Unread @((New-Comment 'Wrap it up.' 0)))
Assert-Equal $unread.Count 1 'unread owner comment'
Write-CommentNote $file @{ 'ticket #2' = $unread.Count; 'PR #3' = 0 }
Assert-Equal (Test-Path $file) $true 'note written'
Assert-Equal ((Get-Content $file -Raw) -match 'ticket #2 \(1\)') $true 'note names the ticket'
Assert-Equal ((Get-Content $file -Raw) -match 'PR #3') $false 'note leaves out a place with none'

# A comment with 👀, or one a worker wrote, writes none, and deletes the note left from before.
$unread = @(Select-Unread @((New-Comment 'Wrap it up.' 1), (New-Comment '**Worker 2:** Read. Wrapping up.' 0)))
Assert-Equal $unread.Count 0 'read comment and worker comment'
Write-CommentNote $file @{ 'ticket #2' = $unread.Count }
Assert-Equal (Test-Path $file) $false 'note deleted'
Assert-Equal @(Select-Unread @()).Count 0 'no comments'

Write-Output 'ok'
