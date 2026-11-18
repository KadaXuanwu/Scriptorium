# Checks followup.ps1: powershell -NoProfile -File followup.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'followup.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# Split: one ticket per ### heading; none, a missing section or plain text without a heading.
$pr = "Closes #1`n`n## Follow-up`n`n### Wheel binds`n**Summary:** The wheel can be a key.`n`n### Gamepad rebinding`nPads too.`n`n## Verified`nTests."
$tickets = @(Split-FollowUps $pr 'Follow-up: Settings')
Assert-Equal $tickets.Count 2 'two headings, two tickets'
Assert-Equal $tickets[0].title 'Wheel binds' 'first title'
Assert-Equal $tickets[0].body '**Summary:** The wheel can be a key.' 'first body stops at the next heading'
Assert-Equal $tickets[1].body 'Pads too.' 'second body stops at the next section'
Assert-Equal @(Split-FollowUps "## Follow-up`n`nNone." 'x').Count 0 'none'
Assert-Equal @(Split-FollowUps "## Follow-up`n`nNone. The rest waits for step 9." 'x').Count 0 'none with a note'
Assert-Equal @(Split-FollowUps "## Follow-up`n`nNone: the parser is a later ticket." 'x').Count 0 'none with a colon'
Assert-Equal @(Split-FollowUps "## Follow-up`n`nNone (Generation 2 soft cap)." 'x').Count 0 'none with a note in brackets'
Assert-Equal @(Split-FollowUps "## Follow-up`n`nNone of the tests pass." 'x').Count 1 'none starting a sentence'
Assert-Equal @(Split-FollowUps 'Closes #1' 'x').Count 0 'no section'
$tickets = @(Split-FollowUps "## Follow-up`nThe export prints nothing." 'Follow-up: Export')
Assert-Equal "$($tickets[0].title)|$($tickets[0].body)" 'Follow-up: Export|The export prints nothing.' 'no heading'
# The Open questions section splits the same way, and neither section takes the other's tickets.
$pr = "## Open questions`n`n### Page size`n**Questions:**`n1. Keep 20 rows? Default: yes.`n`n## Follow-up`n`n### Search box`nx"
Assert-Equal ((@(Split-FollowUps $pr 'x' 'Open questions') | ForEach-Object { $_.title }) -join ',') 'Page size' 'open questions section'
Assert-Equal ((@(Split-FollowUps $pr 'x') | ForEach-Object { $_.title }) -join ',') 'Search box' 'follow-up section beside it'

# Labels: a Repo line replaces the original ticket's repo label; this repo's name drops it; none keeps it.
$here = @('app', 'MyApp')
Assert-Equal ((Get-FollowUpLabels @('area:api/auth', 'size:L') "**Summary:** x`n**Repo:** Tools" $here) -join ',') 'area:api/auth,size:L,repo:Tools' 'repo line adds the label'
Assert-Equal ((Get-FollowUpLabels @('area:api/auth', 'repo:Tools') "**Repo:** app" $here) -join ',') 'area:api/auth' 'this repo drops the label'
Assert-Equal ((Get-FollowUpLabels @('area:api/auth', 'repo:Tools') "**Repo:** MyApp" $here) -join ',') 'area:api/auth' 'the project''s name drops it too'
Assert-Equal ((Get-FollowUpLabels @('area:api/auth', 'repo:Tools') "**Summary:** x" $here) -join ',') 'area:api/auth,repo:Tools' 'no repo line keeps the label'

# An Area line replaces the original ticket's areas; without a name they stay.
Assert-Equal ((Get-FollowUpLabels @('area:api/search', 'size:L') "**Area:** ``area:api/cache``, area:ui/theme") -join ',') 'size:L,area:api/cache,area:ui/theme' 'area line'
Assert-Equal ((Get-FollowUpLabels @('area:api/search', 'size:L') "**Area:** the same") -join ',') 'area:api/search,size:L' 'area line without a name'
Assert-Equal ((Get-FollowUpLabels @('area:ui', 'repo:Tools') "**Area:** area:api/search`n**Repo:** app" $here) -join ',') 'area:api/search' 'area and repo lines'

# Size and Complexity lines give the follow-up's own labels; an open question's size:S stays without a Size line.
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Size:** M`n**Complexity:** high") -join ',') 'area:api,size:M,complexity:high' 'size and complexity lines'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Size:** ``size:l```n**Complexity:** ``complexity:Design``: a structure that stays") -join ',') 'area:api,size:L,complexity:design' 'label forms and a note'
Assert-Equal ((Get-FollowUpLabels @('area:api', 'size:S') "**Size:** M") -join ',') 'area:api,size:M' 'a size line replaces a size'
Assert-Equal ((Get-FollowUpLabels @('area:api', 'size:S') "**Size:** big`n**Complexity:** hard") -join ',') 'area:api,size:S' 'no valid value changes nothing'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Summary:** Medium-size.`n**Scope:** S") -join ',') 'area:api' 'no lines, no labels'
# The playbook's template lines, copied unchanged, give no label (PLAYBOOK.md, Follow-up).
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Size:** one of S, M, L.`n**Complexity:** one of low, medium, high, design.") -join ',') 'area:api' 'template lines'

# View: the Summary line, else the first sentence; the Questions part up to the next label.
$body = "**Summary:** The search answers fast while the cache is warm.`n`n**Now:** 840 queries take 26 ms each.`n" +
    "**Questions:**`n1. Should the cache hold old results? Default: no.`n2. Keep the old test? Default: yes.`n`n" +
    "**Done when:** the slowest query is under 4 ms.`n`nFollow-up from u (ticket #3)."
$view = Get-FollowUpView $body
Assert-Equal $view.summary 'The search answers fast while the cache is warm.' 'summary line'
Assert-Equal ($view.questions -split "`n")[0] '1. Should the cache hold old results? Default: no.' 'questions stop at the next label'
Assert-Equal $view.details "**Now:** 840 queries take 26 ms each.`n**Done when:** the slowest query is under 4 ms.`n`nFollow-up from u (ticket #3)." 'details leave out the summary and questions'
$view = Get-FollowUpView "The log keeps errors per request. The report doesn't print them.`n`nFollow-up from u (ticket #4)."
Assert-Equal $view.summary 'The log keeps errors per request.' 'first sentence without a Summary line'
Assert-Equal $view.details "The report doesn't print them.`n`nFollow-up from u (ticket #4)." 'details leave out the first sentence'
Assert-Equal $view.questions '' 'no questions'
Assert-Equal (Get-FollowUpView "**Summary:** x`n**Questions:** None.").questions '' 'questions: none'
Assert-Equal (Get-FollowUpView "**Summary:** x`n**Questions:** None (Ask or queue).").questions '' 'questions: none with a note'
Assert-Equal (Get-FollowUpView "**Summary:** x`n**Questions:**`n1. Keep? Default: yes.`n`n$(Get-GenerationLine 3)`n`nFollow-up from u").questions '1. Keep? Default: yes.' 'questions stop at the generation line'

# Generation: the ticket's plus one; a front-desk ticket is 0; an old follow-up without the line counts as 1.
Assert-Equal (Get-FollowUpGeneration '**Summary:** x') 1 'front-desk ticket'
Assert-Equal (Get-FollowUpGeneration "x`n`nFollow-up from u (ticket #4).") 2 'old follow-up'
Assert-Equal (Get-FollowUpGeneration "x`n`n$(Get-GenerationLine 3)`n`nFollow-up from u") 4 'line read back'
Assert-Equal (Get-GenerationLine 1) '**Generation:** 1.' 'no cap at 1'
Assert-Equal ((Get-GenerationLine 2) -like '*Soft cap: *') $true 'cap at 2'
Assert-Equal ((Get-GenerationLine 3) -like '*Soft cap, stricter*') $true 'stricter at 3'
Assert-Equal ((Get-GenerationLine 6) -like '*strictest: this ticket is generation 6*') $true 'strictest from 4'

# A title with quotes reaches a program as one argument (git prints its arguments back, each in single quotes).
$title = 'When is a saved filter "out of date" for a user?'
Assert-Equal (& git rev-parse --sq-quote (ConvertTo-NativeArg $title) 'next') " '$title' 'next'" 'a title with quotes stays one argument'

Write-Output 'ok'
