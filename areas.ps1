# Areas (docs/QUEUE.md, Labels): a ticket waits while one in flight holds an area that clashes with one of its own.
# Dot-sourced by worker.ps1 and app/state.ps1, checked by app/app.test.ps1.

# Of $areas, those that clash with an area in $busy: the same one, or one inside the other (area:api holds
# area:api/auth, so the two clash; area:api/auth and area:api/search do not).
function Get-Clashes($areas, $busy) {
    return @($areas | Where-Object {
        $area = [string]$_
        @($busy | Where-Object { $area -eq $_ -or $area.StartsWith("$_/") -or ([string]$_).StartsWith("$area/") }).Count -gt 0
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
    return @(([string]$issue.body -split "`n") | Where-Object { $_ -match '^\s*blocked by' } |
        ForEach-Object { [regex]::Matches($_, '#(\d+)') } | ForEach-Object { [int]$_.Groups[1].Value } |
        Where-Object { $open -contains $_ })
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

# The ticket a worker takes for Now, from the open tickets: $wanted while it is queued (a priority, not waiting on the
# owner), no other worker than $me holds it, and it has no PR and no open blocker. $null when it left the queue: the
# worker then drops its force file. It never takes another ticket in its place, as Select-Forced does.
function Select-Now($issues, [int] $wanted, [string] $me, $prBranches) {
    $ticket = $issues | Where-Object { $_.number -eq $wanted } | Select-Object -First 1
    $names = @($ticket.labels | ForEach-Object { $_.name })
    if (-not $ticket -or -not ($names | Where-Object { $_ -match '^P[0-2]$' }) -or
        ($names | Where-Object { $_ -eq 'needs-owner' -or ($_ -like 'worker:*' -and $_ -ne $me) }) -or
        $prBranches -contains "t$wanted" -or @(Get-Blockers $ticket @($issues | ForEach-Object { $_.number })).Count -gt 0) {
        return $null
    }
    return $ticket
}
