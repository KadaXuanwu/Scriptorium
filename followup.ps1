# Follow-ups (PLAYBOOK.md, Ship): a merged PR's Follow-up section split into draft tickets for the
# merger, and a draft ticket's summary and questions for the queue app. Pure functions, dot-sourced by merge.ps1 and
# app/state.ps1, checked by followup.test.ps1.

# Whether a section's text says there is nothing: "None" or "Nothing" alone or with a note after it ("None. The rest
# waits for step 9.", "None: the parser is a later ticket.", "None (Generation 2 soft cap)."), but not "None of the tests
# pass."
function Test-NoneText([string] $text) {
    return $text -match '^(none|nothing)\s*([.:;,(\p{Pd}]|$)'
}

# A text as one argument to a program: Windows PowerShell 5.1 passes a double quote inside an argument unescaped, so the
# program splits the text there. A title with quotes made gh refuse the issue, and a follow-up was lost. PowerShell 7.3
# and later escape it themselves ($PSNativeCommandArgumentPassing), so the text goes as it is.
function ConvertTo-NativeArg([string] $text) {
    if ($PSNativeCommandArgumentPassing -and $PSNativeCommandArgumentPassing -ne 'Legacy') {
        return $text
    }
    return $text -replace '"', '\"'
}

# The tickets a PR body's Follow-up section (or $section: Open questions) asks for: one per `### <title>` heading, each
# @{ title; body }. Text before the first heading belongs to the first ticket; a section without headings is one ticket
# named $fallbackTitle.
function Split-FollowUps([string] $prBody, [string] $fallbackTitle, [string] $section = 'Follow-up') {
    $match = [regex]::Match($prBody, "(?ms)^##\s*$([regex]::Escape($section))\s*\r?\n(.*?)(?=^##\s|\z)")
    $text = if ($match.Success) { $match.Groups[1].Value.Trim() } else { '' }
    if (-not $text -or (Test-NoneText $text)) {
        return @()
    }
    $parts = [regex]::Split($text, '(?m)^###\s+')
    $preamble = $parts[0].Trim()
    $tickets = New-Object System.Collections.ArrayList
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $lines = $parts[$i] -split "\r?\n", 2
        $body = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
        [void]$tickets.Add(@{ title = $lines[0].Trim(); body = $body })
    }
    if ($tickets.Count -eq 0) {
        return @(@{ title = $fallbackTitle; body = $preamble })
    }
    if ($preamble) {
        $tickets[0].body = "$preamble`n`n$($tickets[0].body)".Trim()
    }
    return @($tickets)
}

# A follow-up's generation: its ticket's plus one; a ticket the front desk filed is 0.
# shortcut: a follow-up from before the Generation line has none and counts as 1.
function Get-FollowUpGeneration([string] $ticketBody) {
    $match = [regex]::Match($ticketBody, '(?m)^\*\*Generation:\*\*[ \t]*(\d+)')
    if ($match.Success) {
        return [int]$match.Groups[1].Value + 1
    }
    if ($ticketBody -match '(?m)^Follow-up from ') {
        return 2
    }
    return 1
}

# The line the merger ends a follow-up with. From generation 2 it is a soft cap on more follow-ups, stricter in each
# generation; none forbids one outright (PLAYBOOK-followup.md, Generation).
function Get-GenerationLine([int] $generation) {
    $note = switch ($generation) {
        { $_ -le 1 } { ''; break }
        2 { ' Soft cap: this ticket is a follow-up of a follow-up. File a follow-up only when it is necessary: a crash, lost work, a fault that a user meets in normal use, or a broken test or tool that stops other runs. Put anything else under Not filed in the PR.'; break }
        3 { ' Soft cap, stricter: this ticket is the third generation of follow-ups. File at most one follow-up, and only for a crash, lost work, a fault that most users meet, or a broken test or tool on main. If you can fix it in this PR, fix it. Put anything else under Not filed in the PR.'; break }
        default { " Soft cap, strictest: this ticket is generation $generation of follow-ups. File no follow-up unless the product crashes, work is lost, or main does not build or pass its tests. Put anything else under Not filed in the PR." }
    }
    return "**Generation:** $generation.$note"
}

# A follow-up's labels (a follow-up decides its own size, complexity and area): $ticketLabels
# with each line of the body in place of the labels of its kind. `**Size:**` gives `size:S`/`M`/`L`, `**Complexity:**`
# `complexity:*`, `**Area:**` its `area:*` names, and `**Repo:** <Name>` the repo its work is in (PLAYBOOK-repo.md;
# a name in $thisRepo, this repo's GitHub name or the project's, is this repo). $complexities: the
# names a Complexity line may give (project.ps1, Get-Complexities). A line without a valid value changes nothing.
function Get-FollowUpLabels([string[]] $ticketLabels, [string] $body, [string[]] $thisRepo = @(),
    [string[]] $complexities = @('low', 'medium', 'high', 'design')) {
    $labels = @($ticketLabels)
    $size = [regex]::Match($body, '(?mi)^\*\*Size:?\*\*:?[ \t`]*(?:size:)?([SML])\b')
    if ($size.Success) {
        $labels = @($labels | Where-Object { $_ -notlike 'size:*' }) + "size:$($size.Groups[1].Value.ToUpperInvariant())"
    }
    $names = ($complexities | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $complexity = [regex]::Match($body, "(?mi)^\*\*Complexity:?\*\*:?[ \t``]*(?:complexity:)?($names)(?![\w-])")
    if ($complexity.Success) {
        $labels = @($labels | Where-Object { $_ -notlike 'complexity:*' }) + "complexity:$($complexity.Groups[1].Value.ToLowerInvariant())"
    }
    $areas = @([regex]::Matches([regex]::Match($body, '(?m)^\*\*Area:?\*\*.*$').Value, 'area:[\w./-]+') | ForEach-Object { $_.Value })
    if ($areas.Count -gt 0) {
        $labels = @($labels | Where-Object { $_ -notlike 'area:*' }) + $areas
    }
    $match = [regex]::Match($body, '(?m)^\*\*Repo:?\*\*:?[ \t]*([\w.-]+)')
    if (-not $match.Success) {
        return $labels
    }
    $labels = @($labels | Where-Object { $_ -notlike 'repo:*' })
    if ($thisRepo -notcontains $match.Groups[1].Value) {
        $labels += "repo:$($match.Groups[1].Value)"
    }
    return $labels
}

# What the queue app shows of a draft ticket: its one-line summary (the `**Summary:**` line, else the body's first
# sentence), its open questions (the `**Questions:**` part, '' for none) and the details the page folds away: the
# body without those two, so nothing shows twice.
function Get-FollowUpView([string] $body) {
    $summary = ''
    $summaryMatch = [regex]::Match($body, '(?m)^\*\*Summary:?\*\*:?[ \t]*(.+)$')
    if ($summaryMatch.Success) {
        $summary = $summaryMatch.Groups[1].Value.Trim()
    } else {
        $plain = (($body -split "\r?\n") | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } | Select-Object -First 3) -join ' '
        $plain = ($plain -replace '\*\*[^*]+:\*\*', '' -replace '\s+', ' ').Trim()
        $sentence = [regex]::Match($plain, '^.+?[.!?](?=\s|$)')
        $summary = if ($sentence.Success) { $sentence.Value } else { $plain }
    }
    if ($summary.Length -gt 240) {
        $summary = $summary.Substring(0, 237) + '...'
    }
    $questions = ''
    $questionsMatch = [regex]::Match($body, '(?ms)^\*\*Questions:?\*\*:?[ \t]*(.*?)(?=^\*\*[^*\r\n]+:\*\*|^\*\*[^*\r\n]+\*\*:|^#{1,6}\s|^Follow-up from |\z)')
    if ($questionsMatch.Success) {
        $questions = $questionsMatch.Groups[1].Value.Trim()
        if (Test-NoneText $questions) {
            $questions = ''
        }
    }
    $details = $body
    foreach ($part in @(@($questionsMatch, $summaryMatch) | Where-Object { $_.Success } | Sort-Object Index -Descending)) {
        $details = $details.Remove($part.Index, $part.Length)
    }
    $details = ($details -replace '(\r?\n){3,}', "`n`n").Trim()
    if (-not $summaryMatch.Success -and $details.StartsWith($summary)) {
        $details = $details.Substring($summary.Length).Trim()
    }
    return @{ summary = $summary; questions = $questions; details = $details }
}

# The titles of the questions a PR body files for the owner (its Open questions, and its Follow-ups that ask) whose
# Questions part has no banner: no picture alone on a line (PLAYBOOK-pictures.md, Banner). The merger sends such a PR
# back to its worker once (merge.ps1).
function Get-BannerlessQuestions([string] $prBody) {
    $items = @(Split-FollowUps $prBody 'Open question' 'Open questions') + @(Split-FollowUps $prBody 'Follow-up')
    return @($items | Where-Object {
            $asked = (Get-FollowUpView $_.body).questions
            $asked -and $asked -notmatch '(?m)^[ 	]*!\[[^\]]*\]\([^)\s]+\)[ 	]*
?$'
        } | ForEach-Object { $_.title })
}
