# The queue's budget arithmetic (docs/QUEUE.md, Dispatching): whether the workers take a ticket of a size on an account
# (limits.ps1: the ceiling and the pick-up limits) and which account wants its room spent first. Pure functions,
# dot-sourced by worker.ps1, checked by budget.test.ps1.

. (Join-Path $PSScriptRoot 'limits.ps1')

# A ticket's priority label from its label names, the highest if it has more than one; '' if none.
# Select-Object, not (...)[0]: one match is a bare string, and [0] of it is 'P', which ties every priority.
function Get-Priority($labels) {
    return [string](@($labels) | Where-Object { $_ -match '^P[0-2]$' } | Sort-Object | Select-Object -First 1)
}

# How urgently an account's free room in a window wants spending: room per hour left before it resets and is lost.
function Get-Pace([double] $room, [long] $left) {
    return $room / ([math]::Max($left, 3600) / 3600.0)
}

# A new usage reading ($new, a hashtable), with each window taken from the stored reading where that one is further
# on: the same login's, with a later reset. A share can fall before its reset: the plan's owner resets a limit
# early, and the window keeps its reset time. A reading with the same reset and a lower share therefore replaces the
# stored one (it once did not, and the page showed the old window for hours). So a caller saves only a reading that is
# new to it (Get-ReadingKey).
# A window of some models too (limits.ps1, $ModelWindows): only runs on its models carry it, so it stays from the last
# such run until a newer reading. One that is used up (1 or more: the plan refused its models, worker.ps1,
# Save-WindowOut) stays until its reset, or a refused start would give its ticket back to the account every poll. A
# kept window takes the new one's read time (`at`): it was read again. The queue app shows it (Accounts).
function Merge-Usage($stored, $new) {
    if (-not $stored -or [string]$stored.email -ne [string]$new.email) {
        return $new
    }
    foreach ($window in @($WindowSeconds.Keys) + @($ModelWindows.Keys)) {
        $old = $stored.$window
        $now = $new.$window
        if ($old -and (-not $now -or [long]$old.resetsAt -gt [long]$now.resetsAt -or
                ($ModelWindows.Contains($window) -and [long]$old.resetsAt -eq [long]$now.resetsAt -and
                    [double]$old.used -ge 1 -and [double]$old.used -gt [double]$now.used))) {
            $new[$window] = if ($now -and $now.at) { @{ used = [double]$old.used; resetsAt = [long]$old.resetsAt; at = [long]$now.at } } else { $old }
        }
    }
    return $new
}

# Whether a worker reads an account's usage with a probe when a run ends (worker.ps1, Invoke-Worker): the provider
# reads none from a run's log and has a probe. The stored reading is then from before the run, and it counts as fresh
# for 30 minutes (Get-FreshUsage): without the probe the next tickets are taken on it, and the page shows it.
function Test-ProbeAfterRun([bool] $readsLog, [bool] $probes) {
    return $probes -and -not $readsLog
}

# What a reading says, without its read time: the same text for the same event of a log. A run that waits on a long
# task has only an old event in its log, and its worker reads that event again at every look. The worker saves a
# reading only when this text changed (worker.ps1, Save-RunUsage), so an old event never replaces the newer reading
# of another run on the account.
function Get-ReadingKey($usage) {
    return ((@($WindowSeconds.Keys) + @($ModelWindows.Keys) | ForEach-Object { "$($usage.$_.used)@$($usage.$_.resetsAt)" }) -join '|') +
        "|$($usage.refused)|$($usage.modelRefused)"
}
