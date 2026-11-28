# Hand back (docs/QUEUE.md, The usage limit): a ticket whose run the plan's limit would hold for long goes back to the
# queue, with its work on its branch on GitHub. Dot-sourced by worker.ps1, checked by tests/handback.test.ps1.

# Whether a run that the plan's limit ended hands its ticket back instead of being held: a ticket (a PR's job stays
# its worker's), held for the plan's own limit ($end, what Invoke-Worker returns: not for the workers' line, a pause,
# its account or a model's window), `handBack` set ($hours above 0), and both the hold's reset ($resetsAt) and the
# account's room ($roomAt: budget.ps1, Get-RoomAt, 0 with no full window) more than $hours after $now.
# The room counts because a dispatcher reads only the windows: with no full window in the account's reading its
# workers would take the ticket again at once, be refused and hand it back, with a comment each time. That run is held.
function Test-HandBack($end, [string] $kind, [long] $resetsAt, [long] $roomAt, [long] $now, [double] $hours) {
    if ($kind -ne 'ticket' -or $hours -le 0 -or -not $end.Limited -or $end.LoggedOut -or $end.AtLimit -or $end.Stopped -or $end.ModelOut) {
        return $false
    }
    $far = $now + [long]($hours * 3600)
    return $resetsAt -gt $far -and $roomAt -gt $far
}

# Puts what the checkout $dir holds of a ticket's run on the ticket's branch $branch on GitHub: every change that is
# not committed, as one commit with $message, and every commit that is not pushed. Returns the commit that GitHub's
# branch then holds, '' when the ticket has no work (no branch on GitHub and nothing to push). Throws when the work is
# not safe on GitHub, and the caller then keeps the run: changes on another branch than the ticket's, a commit that a
# hook of the repo refuses, a push that GitHub refuses. Never a forced push.
# shortcut: `git add -A` takes every file that .gitignore does not leave out, also one the run would not have
# committed; take the run's own list of files if a stray one is ever pushed.
function Save-TicketWork([string] $dir, [string] $branch, [string] $message) {
    $changes = @(& git -C $dir status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in $dir"
    }
    $head = "$(& git -C $dir branch --show-current)"
    if ($head -ne $branch) {
        if ($changes) {
            throw "$dir holds changes on '$head', not on $branch"
        }
        return ''
    }
    if ($changes) {
        & git -C $dir add -A | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed in $dir"
        }
        & git -C $dir commit -q -m $message | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed in $dir"
        }
    }
    $commit = "$(& git -C $dir rev-parse HEAD)"
    if ([int]"$(& git -C $dir rev-list --count HEAD --not --remotes)" -gt 0) {
        & git -C $dir push -q origin "${branch}:refs/heads/$branch" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub refused the push of $branch"
        }
    }
    $pushed = "$(& git -C $dir rev-parse -q --verify "refs/remotes/origin/$branch")"
    if (-not $pushed) {
        return ''
    }
    if ($pushed -ne $commit) {
        throw "GitHub's $branch is not the copy's: $pushed, not $commit"
    }
    return $commit
}
