# Checks away.ps1: powershell -NoProfile -File tests/away.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'followup.ps1')
. (Join-Path $baseDir 'away.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A PR: only a worker's PR that waits on the owner gets a step. A held one merges; a stuck one goes back.
Assert-Equal (Get-AwayPrStep @('worker:1', 'needs-owner')) 'release' 'a held PR'
Assert-Equal (Get-AwayPrStep @('worker:1', 'needs-owner', 'answered')) 'retry' 'a PR stuck on its answers'
Assert-Equal (Get-AwayPrStep @('worker:1', 'needs-owner', 'needs-rebase')) 'retry' 'a PR stuck on its rebase'
Assert-Equal (Get-AwayPrStep @('worker:1')) '' 'a PR that does not wait'
Assert-Equal (Get-AwayPrStep @('needs-owner')) '' 'a PR that is no worker''s'
Assert-Equal (Get-AwayPrStep @()) '' 'a PR with no labels'

# A ticket: by its last worker comment, once.
$question = '**Worker 2:** May a user delete a shared file? A: yes. B: no (default).'
Assert-Equal (Get-AwayTicketStep @('File it.', $question)) 'default' 'a worker''s question'
Assert-Equal (Get-AwayTicketStep @($question, '**Worker 2:** stopped without a PR or a question. Log: `x.log`')) 'retry' 'a stuck run'
Assert-Equal (Get-AwayTicketStep @($question, '**Worker 2:** reached the cap of 5 dollars for one run (runCap in models.json) and stopped without a PR or a question. Log: `x.log`')) '' 'a run at its cap is not tried again'
Assert-Equal (Get-AwayTicketStep @('**Worker 2:** paused by the plan''s usage limit; resumes on its own after it resets (10:00).')) '' 'a run paused for a limit'
Assert-Equal (Get-AwayTicketStep @('Keep this one for me.')) '' 'a ticket that the owner holds'
Assert-Equal (Get-AwayTicketStep @()) '' 'a ticket with no comment'
Assert-Equal (Get-AwayTicketStep @($question, "$AwayNote$($AwayText.default)", $question)) '' 'a ticket handed back before'
Assert-Equal (Test-AwayNoted @('x', "$AwayNote$($AwayText.retry)")) $true 'the merger''s comment is found'
Assert-Equal (Test-AwayNoted @('x', $null)) $false 'no comment of the merger'

# A released PR's questions become one open question that the page shows, of size M.
$pr = [pscustomobject]@{ title = 'Shared files'; url = 'https://github.com/o/r/pull/7'
    body = "Closes #3`n`n**Decision:** May a user delete a shared file? Default: no.`n**Held questions:**`n![b](https://x/b.png?raw=true)`n1. Delete for all? Default: no.`n**Verified:** 12 tests" }
$held = Get-HeldTicket $pr
$view = Get-FollowUpView $held.body
Assert-Equal "$($held.title)|$($held.state)" 'Open question: Shared files|open-question' 'the held ticket'
Assert-Equal $view.summary 'May a user delete a shared file? Default: no.' 'its summary is the Decision line'
Assert-Equal $view.questions "![b](https://x/b.png?raw=true)`n1. Delete for all? Default: no." 'its questions, with the banner'
Assert-Equal ((Get-FollowUpLabels @('area:files', 'size:S') $held.body) -join ' ') 'area:files size:M' 'its size is M'
Assert-Equal (Get-BannerlessQuestions "## Open questions`n### x`n$($held.body)").Count 0 'the banner stays the first line of its questions'
$bare = Get-HeldTicket ([pscustomobject]@{ title = 'x'; url = 'u'; body = "**Decision:** Keep the old export? Default: yes.`n**Held questions:** None" })
Assert-Equal (Get-FollowUpView $bare.body).questions '1. Keep the old export? Default: yes.' 'a Decision line alone is the question'
Assert-Equal ($null -eq (Get-HeldTicket ([pscustomobject]@{ title = 'x'; url = 'u'; body = "Closes #3`n**Held questions:** None" }))) $true 'a PR that asks nothing leaves no ticket'

# The note is there while the owner is away, and gone after.
$file = Join-Path ([IO.Path]::GetTempPath()) "away-test-$PID.md"
Remove-Item $file -ErrorAction SilentlyContinue
Write-AwayNote $file $true
Assert-Equal ((Get-Content $file -Raw) -match 'Never hold a PR') $true 'the note carries the rule'
Write-AwayNote $file $true
Write-AwayNote $file $false
Assert-Equal (Test-Path $file) $false 'the note is deleted'
Write-AwayNote $file $false

Write-Output 'ok'
