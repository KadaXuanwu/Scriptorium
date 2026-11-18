# Checks project.ps1: powershell -NoProfile -File project.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A process is this project's only by its whole -Project argument: never another project, a path that starts with this
# one, or a queue from before -Project. A task's process has no quotes around a path with no space.
$bare = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -File C:\S\worker.ps1 -Project D:\Work\App -Id 2 -Clone D:\Work\App-w2'
Assert-Equal (Test-ProjectProcess $bare 'worker.ps1' 'D:\Work\App') $true 'a path without its quotes'
Assert-Equal (Test-ProjectProcess $bare 'worker.ps1' 'D:\Work\Ap') $false 'a bare path that this one starts with'
Assert-Equal (Test-ProjectProcess 'powershell.exe -File C:\S\merge.ps1 -Project D:\Work\App' 'merge.ps1' 'D:\Work\App') $true 'a bare path at the end'
Assert-Equal (Test-ProjectProcess 'powershell.exe -File C:\S\merge.ps1 -Project D:\Work\App2' 'merge.ps1' 'D:\Work\App') $false 'a longer bare path'
Assert-Equal (Test-ProjectProcess 'powershell.exe -File "C:\S\merge.ps1" -Project "D:\My Work\App"' 'merge.ps1' 'D:\My Work\App') $true 'a path with a space'
$line = 'powershell.exe -NoProfile -File "C:\S\worker.ps1" -Project "D:\Work\App" -Id 2 -Clone "D:\Work\App-w2"'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'D:\Work\App') $true 'this project''s worker'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'd:\work\app') $true 'the path in another case'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'D:\Work\Ap') $false 'a path that this one starts with'
Assert-Equal (Test-ProjectProcess $line 'merge.ps1' 'D:\Work\App') $false 'another script'
$longer = 'powershell.exe -File "C:\S\worker.ps1" -Project "D:\Work\App2" -Id 2'
Assert-Equal (Test-ProjectProcess $longer 'worker.ps1' 'D:\Work\App') $false 'a project whose path starts with this one'
$old = 'powershell.exe -File "D:\Work\App\Tools\Queue\worker.ps1" -Id 2 -Clone "D:\Work\App-w2"'
Assert-Equal (Test-ProjectProcess $old 'worker.ps1' 'D:\Work\App') $false 'a queue from before -Project'
Assert-Equal (Test-ProjectProcess $null 'worker.ps1' 'D:\Work\App') $false 'no command line'
Assert-Equal (Get-TaskName 'App' 'worker 3') 'Scriptorium App worker 3' 'a task name'

# The config: the defaults fill what the file leaves out; a bad name stops.
$dir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-project-test-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
try {
    Set-Content (Join-Path $dir 'scriptorium.json') '{ "name": "My-App2" }' -Encoding utf8
    $config = Read-Project $dir
    Assert-Equal "$($config.name) $($config.port) $(@($config.repos).Count) $(@($config.allowedTools).Count)" 'My-App2 8770 0 0' 'defaults'
    Set-Content (Join-Path $dir 'scriptorium.json') '{ "name": "My App", "port": 9000 }' -Encoding utf8
    $threw = $false
    try { Read-Project $dir | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'a name with a space'
    Remove-Item (Join-Path $dir 'scriptorium.json')
    $threw = $false
    try { Read-Project $dir | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'no scriptorium.json'
} finally {
    Remove-Item $dir -Recurse -Force
}

# The complexities: models.json's, with the project's over them; its own stand between high and design. Every place
# reads this one list: the run's model and advisor, a follow-up's label, the page.
. (Join-Path $PSScriptRoot 'followup.ps1')
. (Join-Path $PSScriptRoot 'limits.ps1')
. (Join-Path $PSScriptRoot 'app\state.ps1')
$models = Read-Models
$own = '{ "name": "App", "compactWindow": 250000, "complexities": { "medium": { "models": ["claude-sonnet-5-5@high"] },
    "review": { "description": "A second look at a change", "models": ["claude-opus-5-5@high"], "advisor": true, "advisorFallback": "xhigh", "compactWindow": 400000 },
    "tidy": { "description": "Small cleanups" } } }' | ConvertFrom-Json
$list = Get-Complexities $models $own
Assert-Equal (($list | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'the project''s own between high and design'
Assert-Equal "$(($list | Where-Object { $_.name -eq 'medium' }).models) $(($list | Where-Object { $_.name -eq 'medium' }).advisor)" 'claude-sonnet-5-5@high True' 'a change keeps what it does not name'
Assert-Equal ($list | Where-Object { $_.name -eq 'tidy' }).models (($list | Where-Object { $_.name -eq 'medium' }).models) 'no models: medium''s'
# As the worker reads them: through a pipe, one complexity at a time.
function Get-Listed { return Get-Complexities $models $own }
Assert-Equal @(Get-Listed | Where-Object { $_.name -eq 'design' }).Count 1 'a pipe sees each complexity'
Assert-Equal ((Get-ComplexityModels (Get-Listed) 'design') -join ',') 'claude-fable-5-2@high' 'the models of one complexity'
Assert-Equal (Get-ComplexityModels (Get-Listed) 'none').Count 0 'no models for a name not in the list'
Assert-Equal (Get-TicketComplexity @('P1', 'complexity:design') (Get-Listed)) 'design' 'a ticket''s complexity'
Assert-Equal (Get-TicketComplexity @('complexity:review') (Get-Listed)) 'review' 'a complexity of the project''s own'
Assert-Equal (Get-TicketComplexity @('complexity:art', 'size:S') (Get-Listed)) 'medium' 'a label not in the list counts as medium'
Assert-Equal (Get-TicketComplexity @() (Get-Listed)) 'medium' 'no label counts as medium'
$rule = Get-AdvisorRule $models $list
Assert-Equal "$($rule.model) $($rule.complexities -join ',') $($rule.fallback.review)" 'claude-fable-5-2 medium,high,review xhigh' 'the advisor rule'
Assert-Equal (Get-FallbackEffort $rule 'review' 'claude-opus-5-5' 'high' $false) 'xhigh' 'the project''s fallback effort'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Complexity:** review" @() @($list | ForEach-Object { $_.name })) -join ',') 'area:api,complexity:review' 'a follow-up of the project''s complexity'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Complexity:** review") -join ',') 'area:api' 'not without the project''s list'
$snapshot = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); complexities = $list
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
Assert-Equal (($snapshot.workers[0].takes | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'a worker takes each'
$review = $snapshot.complexities | Where-Object { $_.name -eq 'review' }
Assert-Equal "$($review.description)|$($review.model)|$($review.effort)|$($review.advisor)" 'A second look at a change|claude-opus-5-5|high|claude-fable-5-2' 'the page gets each complexity'
$threw = $false
try { Get-Complexities $models ('{ "complexities": { "art": { "models": ["x"] } } }' | ConvertFrom-Json) | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'a complexity of the project''s own needs a description'
# The compact window: the complexity's own, else the project's, else models.json's; a name not in the list has medium's.
Assert-Equal "$(Get-ComplexityWindow $list 'low') $(Get-ComplexityWindow $list 'review') $(Get-ComplexityWindow $list 'none')" '250000 400000 250000' 'the project''s window, a complexity''s own, medium''s for no complexity'
Assert-Equal (Get-ComplexityWindow (Get-Complexities $models $null) 'design') 200000 'models.json''s window with no config'
# The page's window (settings.json) goes over the project's, and a complexity's own stays.
$paged = Get-Complexities $models $own ('{ "compactWindow": 283000 }' | ConvertFrom-Json)
Assert-Equal "$(Get-ComplexityWindow $paged 'low') $(Get-ComplexityWindow $paged 'review') $(Get-CompactWindow $models $own $null)" '283000 400000 250000' 'the page''s window over the project''s'
Assert-Equal $review.compactWindow 400000 'the page gets each window'
# Only what Claude Code takes: it read '250k' as its 100k minimum without a word.
foreach ($bad in '"250k"', '99999', '"099999"', '1000001', '250000.5', '""') {
    $threw = $false
    try { Get-Complexities $models ("{ `"compactWindow`": $bad }" | ConvertFrom-Json) | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no compact window: $bad"
}

Write-Output 'ok'
