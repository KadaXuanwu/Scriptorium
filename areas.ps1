# Areas (docs/QUEUE.md, Labels): a ticket waits while one in flight holds an area that clashes with one of its own.
# Dot-sourced by worker.ps1 and app/state.ps1, checked by app/app.test.ps1.

# Of $areas, those that clash with an area in $busy: the same one, or one inside the other (area:api holds
# area:api/auth, so the two clash; area:api/auth and area:api/search do not).
function Get-Clashes($areas, $busy) {
    # foreach, not a pipeline: the page's snapshot calls this for every queued ticket every few seconds.
    return @(foreach ($item in $areas) {
        $area = [string]$item
        foreach ($held in $busy) {
            $other = [string]$held
            if ($area -eq $other -or $area.StartsWith("$other/") -or $other.StartsWith("$area/")) {
                $item
                break
            }
        }
    })
}

# The ticket a forced worker takes from $queue, the unblocked queued tickets in order: the one the queue app showed
# as its next ($wanted), else the first whose area is free, else the first.
function Select-Forced($queue, [int] $wanted, $busy) {
    $pick = $queue | Where-Object { $_.number -eq $wanted } | Select-Object -First 1
    if (-not $pick) {
        $pick = $queue | Where-Object {
            $areas = @($_.labels | ForEach-Object { $_.name } | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })
            (Get-Clashes $areas $busy).Count -eq 0
        } | Select-Object -First 1
    }
    if (-not $pick) {
        $pick = @($queue)[0]
    }
    return $pick
}

# The open tickets that block this one (its `Blocked by` lines).
function Get-Blockers($issue, $open) {
    return @(foreach ($line in [string]$issue.body -split "`n") {
        if ($line -match '^\s*blocked by') {
            foreach ($match in [regex]::Matches($line, '#(\d+)')) {
                $number = [int]$match.Groups[1].Value
                if ($open -contains $number) { $number }
            }
        }
    })
}

# Now (docs/QUEUE.md, Now): the ticket that a worker's force file names with `now`, 0 without one. That worker takes
# the ticket before every other job and ends its run for it; no other worker takes the ticket meanwhile.
function Read-Now([string] $file) {
    try {
        $force = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($force.now) {
            return [int]$force.ticket
        }
    } catch {
    }
    return 0
}

# Queue next (docs/QUEUE.md, Queue next): the ticket that the owner queued as a worker's next (`.queue/next-<N>.json`),
# 0 without one. The worker takes it when it looks for its next job, so its run in progress goes on; no other worker
# takes the ticket meanwhile. -Forced: only a ticket that the owner also forced (`force` in the file, the arrow on the
# worker's card): the worker takes that one past the blockers, the areas and the stop line.
function Read-Next([string] $file, [switch] $Forced) {
    try {
        $next = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
        if (-not $Forced -or $next.force) {
            return [int]$next.ticket
        }
    } catch {
    }
    return 0
}

# Why a ticket queued as a worker's next waits, for the worker and for its card: an open blocker, or an area that a
# ticket in flight holds ($busy). '' when neither holds it.
function Get-NextWait($ticket, $open, $busy) {
    $blockers = @(Get-Blockers $ticket $open)
    if ($blockers.Count -gt 0) {
        return "blocked by #$($blockers -join ', #')"
    }
    $clash = Get-Clashes @($ticket.labels | ForEach-Object { $_.name } | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' }) $busy
    if ($clash.Count -gt 0) {
        return "$(($clash | ForEach-Object { $_ -replace '^area:', '' }) -join ', ') busy"
    }
    return ''
}

# Whether a held run ($held: the worker's paused.json) ended at a checkpoint: at the workers' limit or for the owner's
# pause. Its work is pushed and its handoff comment posted, so the owner's Now may free it (docs/QUEUE.md, Now). Any
# other held run was cut off mid-work (the plan's own limit, a model's window, its account): freeing it would lose work.
function Test-HeldAtCheckpoint($held) {
    return [bool]($held.AtLimit -or $held.Stopped)
}

# The ticket a worker takes for Now, from the open tickets: $wanted while it is queued (a priority, not waiting on the
# owner), no other worker than $me holds it, and it has no PR. An open blocker does not hold it: the owner accepts a
# merge conflict with the blocker. $null when it left the queue: the worker then drops its force file. It never takes
# another ticket in its place, as Select-Forced does.
function Select-Now($issues, [int] $wanted, [string] $me, $prBranches) {
    $ticket = $issues | Where-Object { $_.number -eq $wanted } | Select-Object -First 1
    $names = @($ticket.labels | ForEach-Object { $_.name })
    if (-not $ticket -or -not ($names | Where-Object { $_ -match '^P[0-2]$' }) -or
        ($names | Where-Object { $_ -eq 'needs-owner' -or ($_ -like 'worker:*' -and $_ -ne $me) }) -or
        $prBranches -contains "t$wanted") {
        return $null
    }
    return $ticket
}
