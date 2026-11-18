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
