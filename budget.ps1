# The queue's budget arithmetic (docs/QUEUE.md, Dispatching): whether the workers take a ticket of a size on an account
# (limits.ps1: the ceiling and the pick-up limits) and which account wants its room spent first; and an account's
# usage reading as the PC keeps it. Pure functions, but Read-RecordFile, Save-Reading and Save-ModelRefused, which read
# and write the PC's records of the accounts (pc.ps1, $PcRecords). Dot-sourced by worker.ps1 and app/state.ps1 (the page's Ping saves a reading too), checked by
# budget.test.ps1.

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

# Whether a worker reads an account's usage with a probe while a run works and when it ends (worker.ps1, Update-Usage,
# Invoke-Worker): the provider reads none from a run's log and has a probe. The stored reading is then from before the
# run, and it counts as fresh for 30 minutes (Get-FreshUsage): without the probe the page shows it, the stop line never
# ends the run, and the next tickets are taken on it.
function Test-ProbeAfterRun([bool] $readsLog, [bool] $probes) {
    return $probes -and -not $readsLog
}

# The seconds between two probes while such a run works: a probe starts a process, and the watch looks more often.
$RunProbeSeconds = 120

# When an account has room again: the latest reset of its windows at or over the workers' ceiling, 0 with none.
# $budget: per window @{ used; ceiling; resetsAt } (worker.ps1, Save-Budget).
function Get-RoomAt($budget) {
    return [long](@($budget.Keys) | Where-Object { $budget[$_].used -ge $budget[$_].ceiling } |
        ForEach-Object { [long]$budget[$_].resetsAt } | Measure-Object -Maximum).Maximum
}

# A provider's usage reading (docs/PLUGINS.md, ReadUsage, ReadProbe) as the queue keeps it, read at $now: each window's
# share used and reset, and whether the plan refused the request. The refusal of a window of some models is not
# `refused` but `modelRefused`, that window's name: it stops only those models. Only the windows that the provider's
# models.json names. $null for no reading.
function ConvertTo-Reading($read, [long] $now) {
    if (-not $read) {
        return $null
    }
    $refused = [string]$read.Refused
    $ofModels = [bool]$refused -and $ModelWindows.Contains($refused)
    $usage = @{ at = $now; refused = [bool]$refused -and -not $ofModels; modelRefused = $(if ($ofModels) { $refused } else { '' })
        refusedResetsAt = [long]$read.RefusedResetsAt }
    foreach ($window in @($WindowSeconds.Keys) + @($ModelWindows.Keys)) {
        $value = if ($read.Windows) { $read.Windows[$window] } else { $null }
        if ($value) {
            $usage[$window] = @{ used = [double]$value.Used; resetsAt = [long]$value.ResetsAt; at = $now }
        }
    }
    return $usage
}

# One of the PC's records of the accounts (usage.json, out.json, access.json), by account. Missing or unreadable: none,
# so every account's usage is read again, no account is out and no model is refused. A bad file must not stop a
# worker, and the next save writes it whole again.
function Read-RecordFile([string] $file) {
    $all = @{}
    try {
        $json = Read-JsonFile $file
        if ($json) {
            $json.PSObject.Properties | ForEach-Object { $all[$_.Name] = $_.Value }
        }
    } catch {
    }
    return $all
}

# Saves an account's reading ($usage, with its login's `email`) in the PC's usage file, which the workers of every
# project and the pages share. Under the lock of the accounts' records (pc.ps1, 'Usage') and written whole
# (Save-JsonFile): two workers that saved in the same second once tore the file, and every worker then failed each poll.
function Save-Reading([string] $file, [string] $account, $usage) {
    $lock = Enter-PcLock 'Usage'
    try {
        $all = Read-RecordFile $file
        # Merge-Usage changes $usage itself, so the caller's reading is the account's newest too.
        $all[$account] = Merge-Usage $all[$account] $usage
        Save-JsonFile $file $all
    } finally {
        Exit-PcLock $lock
    }
}

# Saves in the PC's access file that the plan of $account refused $model at $now (worker.ps1, Test-ModelRefused): per
# account, per model the time of the refusal. Under the same lock and written whole, as Save-Reading.
function Save-ModelRefused([string] $file, [string] $account, [string] $model, [long] $now) {
    $lock = Enter-PcLock 'Usage'
    try {
        $all = Read-RecordFile $file
        $mine = @{}
        if ($all[$account]) {
            $all[$account].PSObject.Properties | ForEach-Object { $mine[$_.Name] = $_.Value }
        }
        $mine[$model] = $now
        $all[$account] = $mine
        Save-JsonFile $file $all
    } finally {
        Exit-PcLock $lock
    }
}

# What a reading says, without its read time: the same text for the same event of a log. A run that waits on a long
# task has only an old event in its log, and its worker reads that event again at every look. The worker saves a
# reading only when this text changed (worker.ps1, Save-RunUsage), so an old event never replaces the newer reading
# of another run on the account.
function Get-ReadingKey($usage) {
    return ((@($WindowSeconds.Keys) + @($ModelWindows.Keys) | ForEach-Object { "$($usage.$_.used)@$($usage.$_.resetsAt)" }) -join '|') +
        "|$($usage.refused)|$($usage.modelRefused)"
}
