# The queue's budget arithmetic (docs/QUEUE.md, Dispatching): whether the workers take a ticket of a size on an account
# (limits.ps1: the ceiling and the pick-up limits) and which account wants its room spent first. Pure functions,
# dot-sourced by worker.ps1, checked by budget.test.ps1.

. (Join-Path $PSScriptRoot 'limits.ps1')

# A plan's size relative to Pro, from the login's rate limit tier: a run costs a bigger plan a smaller share.
function Get-PlanSize([string] $tier) {
    if ($tier -match 'max_20x') {
        return 20.0
    }
    if ($tier -match 'max_5x') {
        return 5.0
    }
    return 1.0
}

# A ticket's priority label from its label names, the highest if it has more than one; '' if none.
# Select-Object, not (...)[0]: one match is a bare string, and [0] of it is 'P', which ties every priority.
function Get-Priority($labels) {
    return [string](@($labels) | Where-Object { $_ -match '^P[0-2]$' } | Sort-Object | Select-Object -First 1)
}

# How urgently an account's free weekly room wants spending: room per hour left before it resets and is lost.
function Get-Pace([double] $room, [long] $left) {
    return $room / ([math]::Max($left, 3600) / 3600.0)
}

# A new usage reading ($new, a hashtable), with each window taken from the stored reading where that one is further
# on: the same login's, with a later reset. A share can fall before its reset: the plan's owner resets a limit
# early, and the window keeps its reset time. A reading with the same reset and a lower share therefore replaces the
# stored one (it once did not, and the page showed the old week for hours). So a caller saves only a reading that is
# new to it (Get-ReadingKey).
# The Fable window too (limits.ps1): only Fable runs carry it, so it stays from the last Fable run until a newer
# reading. A Fable window that is used up (1 or more: the plan refused Fable, worker.ps1, Save-FableOut) stays until
# its reset, or a refused start would give its ticket back to the account every poll. A kept window takes the new
# one's read time (`at`): it was read again. The queue app shows the Fable window's (Accounts).
function Merge-Usage($stored, $new) {
    if (-not $stored -or $stored.email -ne $new.email) {
        return $new
    }
    foreach ($window in @('five_hour', 'seven_day', $FableWindow)) {
        $old = $stored.$window
        $now = $new.$window
        if ($old -and (-not $now -or [long]$old.resetsAt -gt [long]$now.resetsAt -or
                ($window -eq $FableWindow -and [long]$old.resetsAt -eq [long]$now.resetsAt -and
                    [double]$old.used -ge 1 -and [double]$old.used -gt [double]$now.used))) {
            $new[$window] = if ($now -and $now.at) { @{ used = [double]$old.used; resetsAt = [long]$old.resetsAt; at = [long]$now.at } } else { $old }
        }
    }
    return $new
}

# What a reading says, without its read time: the same text for the same event of a log. A run that waits on a long
# task has only an old event in its log, and its worker reads that event again at every look. The worker saves a
# reading only when this text changed (worker.ps1, Save-RunUsage), so an old event never replaces the newer reading
# of another run on the account.
function Get-ReadingKey($usage) {
    return ((@('five_hour', 'seven_day', $FableWindow) | ForEach-Object { "$($usage.$_.used)@$($usage.$_.resetsAt)" }) -join '|') +
        "|$($usage.refused)|$($usage.fableRefused)"
}
