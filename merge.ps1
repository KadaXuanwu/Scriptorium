# The queue's merger (docs/QUEUE.md): squash-merges every worker PR GitHub can merge, oldest first, and labels a
# conflicting one needs-rebase for its worker. Never resolves anything itself. While the owner is away (away.ps1), it
# hands back what waits on the owner. Loops until stopped.
param(
    [Parameter(Mandatory = $true)] [string] $Project,
    [int] $PollSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project.ps1')
. (Join-Path $PSScriptRoot 'followup.ps1')
. (Join-Path $PSScriptRoot 'comments.ps1')
. (Join-Path $PSScriptRoot 'away.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')
# gh writes UTF-8; Windows PowerShell would read it in the console's old code page and garble titles.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Project = Resolve-Project $Project
$config = Read-Project $Project
Start-CodeWatch @((Join-Path $Project 'scriptorium.json'))

# One merger per project: stopping the task ends only its console host, so an older loop may still run, on old code.
# End it.
Get-CommandLines -Shells |
    Where-Object { $_.ProcessId -ne $PID -and (Test-ProjectProcess $_.CommandLine 'merge.ps1' $Project) } |
    ForEach-Object { Stop-ProcessTree $_.ProcessId }

Set-Location $Project
$slug = (& gh repo view --json nameWithOwner -q .nameWithOwner)
# A follow-up's `**Repo:**` line names this repo by its GitHub name or by the project's name.
$thisRepo = @($slug.Split('/')[1], $config.name)
$log = Join-Path $Project '.queue/merge.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
# A squash commit is its PR's title alone: the branch's own commit messages stay out of main.
$emptyBody = Join-Path $Project '.queue/empty-body.txt'
[System.IO.File]::WriteAllText($emptyBody, '')
# Wakes (docs/QUEUE.md, Wakes): a worker writes the first when its run ends; this script writes the second after a
# pass that changed a PR, for the idle workers.
# The start of the merger's comment on a PR whose question has no banner; a PR that has it is not sent back again.
$bannerNote = '**Merger:** a question has no banner picture:'
$wakeMerger = Join-Path $Project '.queue/wake-merger'
$wakeWorkers = Join-Path $Project '.queue/wake-workers'

# A merged PR's Follow-up section (PLAYBOOK.md, Ship) filed as draft tickets for the owner, one per
# `### <title>`. One with no questions has nothing for the owner to decide, so it is queued (P1) at once; one with
# questions is labelled follow-up, no priority, so no worker takes it until the owner answers and queues it from the
# queue app. Its `**Size:**`, `**Complexity:**`, `**Area:**` and `**Repo:**` lines give its labels (Get-FollowUpLabels);
# without a line it has no size or complexity label (M, medium) and keeps the original ticket's areas and repo.
# The Open questions section is filed the same way, each labelled open-question: the PR built its default, so the
# ticket waits in the queue app's Q&A until the owner keeps the default (closed) or changes it (queued).
# $held: the one ticket to file in place of the body's sections, for a held PR that merges while the owner is away
# (away.ps1, Get-HeldTicket).
function New-FollowUp($pr, [string] $where, [int] $ticket, $held = $null) {
    if ($held) {
        $tickets = @($held)
    } else {
        $tickets = @(Split-FollowUps ([string]$pr.body) "Follow-up: $($pr.title)" | ForEach-Object { $_.state = $null; $_ })
        $tickets += @(Split-FollowUps ([string]$pr.body) "Open question: $($pr.title)" 'Open questions' |
            ForEach-Object { $_.state = 'open-question'; $_ })
    }
    if ($tickets.Count -eq 0) {
        return
    }
    $issue = ((& gh issue view $ticket --json labels,body -R $slug) -join "`n") | ConvertFrom-Json
    $generation = Get-GenerationLine (Get-FollowUpGeneration ([string]$issue.body))
    # The size and complexity are the original's work, not the follow-up's: never copied.
    $labels = @($issue.labels | ForEach-Object { $_.name } | Where-Object { $_ -match '^(area|repo):' })
    $known = @(((& gh label list --search area: --limit 1000 --json name -R $slug) -join "`n") | ConvertFrom-Json | ForEach-Object { $_.name })
    $file = Join-Path $Project '.queue/follow-up.md'
    foreach ($item in $tickets) {
        [System.IO.File]::WriteAllText($file, "$($item.body)`n`n$generation`n`nFollow-up from $($pr.url) (ticket https://github.com/$slug/issues/$ticket).`n")
        $state = if ($item.state) { $item.state } elseif ((Get-FollowUpView $item.body).questions) { 'follow-up' } else { 'P1' }
        $createArgs = @('issue', 'create', '--title', (ConvertTo-NativeArg $item.title), '--body-file', $file, '--label', $state, '-R', $slug)
        # Changing a built default is a small edit (PLAYBOOK.md, Hold or merge), whatever the original's size.
        $own = if ($state -eq 'open-question') { @($labels) + 'size:S' } else { $labels }
        $names = @(Get-Complexities (Read-Models) $config | ForEach-Object { $_.name })
        foreach ($label in (Get-FollowUpLabels $own $item.body $thisRepo $names)) {
            # gh refuses an unknown label, which would lose the follow-up; a run may name a new area.
            if ($label -like 'area:*' -and $known -notcontains $label) {
                & gh label create $label --color c5def5 -R $slug | Out-Null
                $known += $label
            }
            $createArgs += @('--label', $label)
        }
        $url = & gh @createArgs
        if (-not $url) {
            $url = "NOT FILED: $($item.title)"
        }
        Add-Content $log "$(Get-Date -Format s) follow-up from $where#$($pr.number): $url" -Encoding utf8
    }
}

# Merges as the settings' `merger.ghConfigDir` bot when that is signed in (docs/QUEUE.md, Settings), else as the owner.
function Set-GitHubIdentity {
    $file = Join-Path $Project '.queue/settings.json'
    $dir = $null
    if (Test-Path $file) {
        $json = Get-Content $file -Raw | ConvertFrom-Json
        if ($json.merger) {
            $dir = $json.merger.ghConfigDir
        }
    }
    if ($dir) {
        $env:GH_CONFIG_DIR = $dir
        $ErrorActionPreference = 'Continue'
        & gh auth token 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }
    Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
}

while ($true) {
    if (Test-CodeChanged) {
        Add-Content $log "$(Get-Date -Format s) script changed: restarting on the new code" -Encoding utf8
        Restart-OnNewCode (Get-TaskName $config.name 'merger')
    }
    $passAt = Get-Date
    $changed = $false
    try {
        Set-GitHubIdentity
        # Worker PRs in this repo and in every other repo an open ticket names with a `repo:<Name>` label
        # (PLAYBOOK-repo.md). The parentheses unroll the list Windows PowerShell's ConvertFrom-Json passes on as one object.
        $labels = ((((& gh issue list --state open --limit 500 --json labels -R $slug) -join "`n") | ConvertFrom-Json) |
            ForEach-Object { $_.labels } | ForEach-Object { $_.name })
        $repos = @(@($slug) + @($labels | Where-Object { $_ -like 'repo:*' } |
            ForEach-Object { "$($slug.Split('/')[0])/$($_.Substring(5))" }) | Sort-Object -Unique)
        $prs = @()
        foreach ($where in $repos) {
            $prs += @((((& gh pr list --state open --limit 200 --json number,title,body,url,headRefName,labels,mergeable,createdAt -R $where) -join "`n") |
                ConvertFrom-Json) | ForEach-Object { $_ | Add-Member -NotePropertyName Repo -NotePropertyValue $where -PassThru })
        }
        # No blocking (docs/QUEUE.md, No blocking): while the owner is away, what waits on the owner goes on without an answer. A
        # ticket goes back to its worker, once: with a question, to take its default; stuck, for one more try.
        # Settings that do not parse count as not away: the merges go on.
        $away = $false
        try {
            $away = [bool](Read-ProjectSettings $Project).away
        } catch {
            Add-Content $log "$(Get-Date -Format s) settings: $_" -Encoding utf8
        }
        if ($away) {
            $waiting = ((& gh issue list --state open --label needs-owner --limit 100 --json number,comments -R $slug) -join "`n") | ConvertFrom-Json
            foreach ($issue in $waiting) {
                $step = Get-AwayTicketStep @($issue.comments | ForEach-Object { [string]$_.body })
                if ($step) {
                    & gh issue comment $issue.number --body (ConvertTo-NativeArg "$AwayNote$($AwayText[$step])") -R $slug | Out-Null
                    & gh issue edit $issue.number --remove-label needs-owner -R $slug | Out-Null
                    Add-Content $log "$(Get-Date -Format s) away: #$($issue.number) back to its worker ($step)" -Encoding utf8
                    $changed = $true
                }
            }
        }
        foreach ($pr in ($prs | Sort-Object createdAt)) {
            $where = $pr.Repo
            $ticket = [int]$pr.headRefName.Substring(1)
            $names = @($pr.labels | ForEach-Object { $_.name })
            $step = if ($away) { Get-AwayPrStep $names } else { '' }
            if ($step -eq 'release') {
                # A held PR has its default built: it merges in this pass, and its questions wait as an open question.
                # The label first: a ticket filed before a label that stays would be filed again each pass.
                & gh pr edit $pr.number --remove-label needs-owner -R $where | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $names = @($names | Where-Object { $_ -ne 'needs-owner' })
                    Add-Content $log "$(Get-Date -Format s) away: released $where#$($pr.number)" -Encoding utf8
                    $changed = $true
                    $held = Get-HeldTicket $pr
                    if ($held) {
                        New-FollowUp $pr $where $ticket $held
                    }
                }
            } elseif ($step -eq 'retry' -and
                -not (Test-AwayNoted @((((& gh pr view $pr.number --json comments -R $where) -join "`n") | ConvertFrom-Json).comments | ForEach-Object { [string]$_.body }))) {
                # A PR that its run could not finish goes back to its worker, once: the comment marks it.
                & gh pr comment $pr.number --body (ConvertTo-NativeArg "$AwayNote$($AwayText.retry)") -R $where | Out-Null
                & gh pr edit $pr.number --remove-label needs-owner -R $where | Out-Null
                Add-Content $log "$(Get-Date -Format s) away: $where#$($pr.number) back to its worker (retry)" -Encoding utf8
                $changed = $true
            }
            if (-not ($names | Where-Object { $_ -like 'worker:*' }) -or
                ($names | Where-Object { @('needs-rebase', 'needs-owner', 'answered') -contains $_ })) {
                continue
            }
            # UNKNOWN: a list doesn't make GitHub compute it, asking for the one PR does. A wake comes seconds after a
            # run opened its PR, so ask up to three times, 5 seconds apart; else the answer is there next pass.
            for ($try = 0; $pr.mergeable -eq 'UNKNOWN' -and $try -lt 3; $try++) {
                if ($try) {
                    Start-Sleep 5
                }
                # A view that fails reads as '': the PR waits for the next pass, and the pass goes on.
                $pr.mergeable = [string](& gh pr view $pr.number --json mergeable -q .mergeable -R $where)
            }
            if ($pr.mergeable -eq 'MERGEABLE' -and (Get-UnreadCount $ticket $slug) + (Get-UnreadCount $pr.number $where) -gt 0) {
                # A comment the run never read (it came after its last checkpoint): back to its worker first.
                & gh pr edit $pr.number --add-label answered -R $where | Out-Null
                Add-Content $log "$(Get-Date -Format s) unread comments, answered $where#$($pr.number)" -Encoding utf8
                $changed = $true
            } elseif ($pr.mergeable -eq 'MERGEABLE' -and ($bare = @(Get-BannerlessQuestions ([string]$pr.body))) -and
                -not (@((((& gh pr view $pr.number --json comments -R $where) -join "`n") | ConvertFrom-Json).comments) |
                    Where-Object { ([string]$_.body).StartsWith($bannerNote) })) {
                # The banner gate (PLAYBOOK-pictures.md): back to its worker, once. A PR that already has this comment
                # merges as it is, so a run that cannot take a picture never stalls the queue.
                & gh pr comment $pr.number --body (ConvertTo-NativeArg "$bannerNote $($bare -join '; '). Add it (PLAYBOOK-pictures.md, Banner), or reply why none can be taken.") -R $where | Out-Null
                & gh pr edit $pr.number --add-label answered -R $where | Out-Null
                Add-Content $log "$(Get-Date -Format s) no banner, answered $where#$($pr.number)" -Encoding utf8
                $changed = $true
            } elseif ($pr.mergeable -eq 'MERGEABLE') {
                # Under the workers' dispatch lock (worker.ps1) from the merge to the ticket's close: a worker that
                # looks between the two sees its ticket open without a PR, and starts it again or parks it.
                $merged = $false
                $lock = Enter-PcLock "$($config.name)-Queue"
                try {
                    & gh pr merge $pr.number --squash --body-file $emptyBody -R $where
                    $merged = $LASTEXITCODE -eq 0
                    if ($merged) {
                        $changed = $true
                        & gh api -X DELETE "repos/$where/git/refs/heads/$($pr.headRefName)" | Out-Null
                        Add-Content $log "$(Get-Date -Format s) merged $where#$($pr.number)" -Encoding utf8
                        # GitHub's close from "Closes #N" can miss, and an open ticket goes back to its worker; close it here.
                        # No comment: GitHub's own close often comes after this check, so one would land on most tickets.
                        if ((((& gh issue view $ticket --json state -R $slug) -join "`n") | ConvertFrom-Json).state -eq 'OPEN') {
                            & gh issue close $ticket -R $slug | Out-Null
                        }
                    }
                } finally {
                    Exit-PcLock $lock
                }
                if ($merged) {
                    New-FollowUp $pr $where $ticket
                }
            } elseif ($pr.mergeable -eq 'CONFLICTING') {
                & gh pr edit $pr.number --add-label needs-rebase -R $where | Out-Null
                Add-Content $log "$(Get-Date -Format s) needs-rebase $where#$($pr.number)" -Encoding utf8
                $changed = $true
            }
        }
    } catch {
        Add-Content $log "$(Get-Date -Format s) error: $_" -Encoding utf8
    }
    # At the end of the pass, after the ticket closed and the follow-ups were filed: a merge frees the ticket's
    # areas, and a label gives a worker a job. The idle workers look now, not at their next poll.
    if ($changed) {
        Send-Wake $wakeWorkers
    }
    # Changed code or a wake (a worker's run ended, the owner acted on the page) wakes the next pass early.
    $wake = (Get-Date).AddSeconds($PollSeconds)
    while ((Get-Date) -lt $wake -and -not (Test-CodeChanged) -and
        -not ((Test-Path $wakeMerger) -and (Get-Item $wakeMerger).LastWriteTime -gt $passAt)) {
        Start-Sleep 5
    }
}
