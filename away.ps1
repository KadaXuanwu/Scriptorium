# No blocking (docs/QUEUE.md, No blocking): while the owner is away, nothing that waits on the owner stops the work. What the merger
# does with a PR or a ticket that waits on the owner, and the note that tells a run. Pure functions but the note,
# dot-sourced by merge.ps1 (with followup.ps1, which Get-HeldTicket needs) and worker.ps1 (the note only), checked by
# away.test.ps1.

# The start of the merger's comment on what it hands back for the owner. One that has it is not handed back again, so
# a ticket that fails or asks twice waits for the owner after all.
$AwayNote = '**Merger:** the owner is away'

# The rest of that comment, for each step (Get-AwayPrStep, Get-AwayTicketStep).
$AwayText = @{
    default = ". Take your default: build the answer that you recommend so that it is easy to change, and put the " +
        "question under the PR's Open questions (PLAYBOOK.md, No blocking)."
    retry = ', so this run gets one more try.'
}

# Whether the merger handed this one back before ($comments: the bodies of its comments).
function Test-AwayNoted([string[]] $comments) {
    return [bool]@($comments | Where-Object { $_ -and $_.StartsWith($AwayNote) }).Count
}

# What the merger does with a worker's PR that waits on the owner ($names: its labels):
# - 'release': a held PR. Its default is built, so it merges, and its questions wait as an open question.
# - 'retry': a PR that its run could not finish (an answer or a rebase). It goes back to its worker, once.
# - '': anything else.
function Get-AwayPrStep([string[]] $names) {
    if ($names -notcontains 'needs-owner' -or -not ($names | Where-Object { $_ -like 'worker:*' })) {
        return ''
    }
    if ($names -contains 'answered' -or $names -contains 'needs-rebase') {
        return 'retry'
    }
    return 'release'
}

# What the merger does with a ticket that waits on the owner ($comments: the bodies of its comments, oldest first),
# by its last worker comment, as the page reads it (app/state.ps1, Get-Waiting):
# - 'default': a worker's question. The ticket goes back to its worker, which takes its default.
# - 'retry': a run that stopped without a PR or a question. It goes back to its worker.
# - '': a ticket handed back before, one that the owner holds (no worker comment), one paused for a usage limit, or a
#   run that reached the cap for one run: a second try would spend the cap twice.
function Get-AwayTicketStep([string[]] $comments) {
    if (Test-AwayNoted $comments) {
        return ''
    }
    $last = @($comments | Where-Object { $_ -and $_.StartsWith('**Worker') }) | Select-Object -Last 1
    $text = ([string]$last -replace '^\*\*Worker[^*]*\*\*\s*', '').Trim()
    if (-not $text -or $text -match '^(paused by|reached the cap)') {
        return ''
    }
    if ($text -match '^stopped without') {
        return 'retry'
    }
    return 'default'
}

# The open question that a released PR leaves for the owner: its Decision line and its Held questions, as a ticket
# that the merger files (merge.ps1, New-FollowUp). $null when the PR names neither. Size M: a blocking question is
# one whose answer is expensive to change.
function Get-HeldTicket($pr) {
    $asked = Get-HeldQuestions ([string]$pr.body)
    $decision = Get-Decision ([string]$pr.body)
    if (-not $asked -and -not $decision) {
        return $null
    }
    $body = "**Summary:** $(if ($decision) { $decision } else { 'The questions that held this PR.' })`n" +
        "**Where:** $($pr.url), Held questions. The owner was away, so the PR merged with its default built.`n" +
        "**Size:** M`n**Questions:**`n$(if ($asked) { $asked } else { "1. $decision" })"
    return @{ title = "Open question: $($pr.title)"; body = $body; state = 'open-question' }
}

# The note a run reads at its checkpoint and before it ships: there while the owner is away. It carries the whole
# rule, so a run that read an older playbook follows it too.
function Write-AwayNote([string] $file, [bool] $away) {
    if (-not $away) {
        Remove-Item $file -ErrorAction SilentlyContinue
        return
    }
    if (Test-Path $file) {
        return
    }
    Set-Content $file ('The owner is away, and no question may stop the work (PLAYBOOK.md, No blocking). Ask no blocking ' +
        'question: build the answer that you recommend so that it is easy to change, write it where the project keeps ' +
        'its decisions, and put the question under the PR''s Open questions, with a **Size:** line (S, M or L) for the ' +
        'work to change it. Never hold a PR, and never add needs-owner for a question.') -Encoding utf8
}
