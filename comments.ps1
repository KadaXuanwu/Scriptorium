# Owner comments (PLAYBOOK.md, Comments): the ones a run hasn't marked read, for the merger (back to the worker) and
# the worker script (a note in the run's queue folder). Dot-sourced by merge.ps1 and worker.ps1, checked by
# comments.test.ps1.

# Of a ticket's or PR's comments (the GitHub API's objects), the owner's a run hasn't marked read (👀): anything
# not starting **Worker.
function Select-Unread($comments) {
    return @($comments | Where-Object { -not ([string]$_.body).StartsWith('**Worker') -and $_.reactions.eyes -eq 0 })
}

function Get-UnreadCount([int] $number, [string] $slug) {
    $comments = ((& gh api "repos/$slug/issues/$number/comments" --paginate) -join "`n") | ConvertFrom-Json
    return @(Select-Unread $comments).Count
}

# The note a run reads at its checkpoint: written while $unread (a hashtable, place => count) has a comment, deleted
# once it has none, so a run that read them finds no note at its next checkpoint.
function Write-CommentNote([string] $file, $unread) {
    $places = @($unread.Keys | Where-Object { $unread[$_] -gt 0 } | Sort-Object | ForEach-Object { "$_ ($($unread[$_]))" })
    if ($places.Count -eq 0) {
        Remove-Item $file -ErrorAction SilentlyContinue
        return
    }
    Set-Content $file ("The owner commented and you have not read it: $($places -join ', '). At your next " +
        'checkpoint, read the comments, react eyes to each and reply in one line what you do with it (PLAYBOOK.md, Comments).') -Encoding utf8
}
