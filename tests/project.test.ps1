# Checks project.ps1: powershell -NoProfile -File tests/project.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
# The PC's files of a test are in a folder of its own (pc.ps1): set before anything loads.
$PcDir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-test-$PID"
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'project.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A ticket's branch is t<N> and nothing else: the merger reads the ticket's number from it.
Assert-Equal (Test-TicketBranch 't12') $true 'a ticket''s branch'
Assert-Equal (Test-TicketBranch 'providers') $false 'the owner''s own branch'
Assert-Equal (Test-TicketBranch 't12-fix') $false 'a branch that starts like a ticket''s'
Assert-Equal (Test-TicketBranch 'shots-t12') $false 'a ticket''s pictures'
Assert-Equal (Test-TicketBranch '') $false 'no branch'

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
# On macOS and Linux, ps shows the arguments without their quotes.
$unix = '/usr/bin/pwsh -NoProfile -File /opt/S/worker.ps1 -Project /home/me/App -Id 2 -Clone /home/me/App-w2'
Assert-Equal "$(Test-ProjectProcess $unix 'worker.ps1' '/home/me/App') $(Test-ProjectProcess $unix 'worker.ps1' '/home/me/Ap')" 'True False' 'a command line on macOS or Linux'
Assert-Equal (Test-CopyProcess '/opt/Unity/Editor/Unity -projectPath /home/me/App-w1/Unity -batchmode' '/home/me/App-w1') $true 'an editor in a copy on macOS or Linux'
Assert-Equal (Get-TaskName 'App' 'worker 3') 'Scriptorium App worker 3' 'a task name'
# What runs from a worker's copy: its path in a command line, with either slash, any case, as a whole path.
$editor = '"C:\Unity\Editor\Unity.exe" -projectPath "D:\Work\App-w1\Unity" -batchmode'
Assert-Equal (Test-CopyProcess $editor 'D:\Work\App-w1') $true 'an editor in the copy'
Assert-Equal (Test-CopyProcess 'node.exe D:/Work/App-w1/x.js' 'D:\Work\App-w1') $true 'the path with forward slashes'
Assert-Equal (Test-CopyProcess 'git -C d:\work\app-w1 status' 'D:\Work\App-w1') $true 'another case, then a space'
Assert-Equal (Test-CopyProcess 'cmd /c cd /d "D:\Work\App-w1"' 'D:\Work\App-w1') $true 'the path before a quote'
Assert-Equal (Test-CopyProcess 'git -C D:\Work\App-w1' 'D:\Work\App-w1') $true 'the path at the end'
Assert-Equal (Test-CopyProcess "powershell -Command cd 'D:\Work\App-w1'" 'D:\Work\App-w1') $true 'the path before a single quote'
Assert-Equal (Test-CopyProcess 'git -C D:\Work\App-w10 status' 'D:\Work\App-w1') $false 'another worker''s copy'
Assert-Equal (Test-CopyProcess 'git -C D:\Work\App-w1-old status' 'D:\Work\App-w1') $false 'a longer folder name'
Assert-Equal (Test-CopyProcess $line 'D:\Work\App-w1') $false 'a command line that names no copy of worker 1'
Assert-Equal (Test-CopyProcess $null 'D:\Work\App-w1') $false 'no command line'

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
. (Join-Path $baseDir 'followup.ps1')
. (Join-Path $baseDir 'limits.ps1')
. (Join-Path $baseDir 'app/state.ps1')
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/provider') 'test' $null)
$models = Read-Models
$own = '{ "name": "App", "compactAt": 250000, "complexities": { "medium": { "models": ["mid-1@high"] },
    "review": { "description": "A second look at a change", "models": ["main-1@high"], "advisor": true, "advisorFallback": "xhigh", "compactAt": 400000 },
    "tidy": { "description": "Small cleanups" } } }' | ConvertFrom-Json
$list = Get-Complexities $models $own
Assert-Equal (($list | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'the project''s own between high and design'
Assert-Equal "$(($list | Where-Object { $_.name -eq 'medium' }).models) $(($list | Where-Object { $_.name -eq 'medium' }).advisor)" 'mid-1@high True' 'a change keeps what it does not name'
Assert-Equal ($list | Where-Object { $_.name -eq 'tidy' }).models (($list | Where-Object { $_.name -eq 'medium' }).models) 'no models: medium''s'
# As the worker reads them: through a pipe, one complexity at a time.
function Get-Listed { return Get-Complexities $models $own }
Assert-Equal @(Get-Listed | Where-Object { $_.name -eq 'design' }).Count 1 'a pipe sees each complexity'
Assert-Equal ((Get-ComplexityModels (Get-Listed) 'design') -join ',') 'deep-1@high' 'the models of one complexity'
Assert-Equal (Get-ComplexityModels (Get-Listed) 'none').Count 0 'no models for a name not in the list'
Assert-Equal (Get-TicketComplexity @('P1', 'complexity:design') (Get-Listed)) 'design' 'a ticket''s complexity'
Assert-Equal (Get-TicketComplexity @('complexity:review') (Get-Listed)) 'review' 'a complexity of the project''s own'
Assert-Equal (Get-TicketComplexity @('complexity:art', 'size:S') (Get-Listed)) 'medium' 'a label not in the list counts as medium'
Assert-Equal (Get-TicketComplexity @() (Get-Listed)) 'medium' 'no label counts as medium'
$rule = Get-AdvisorRule $models $list
Assert-Equal "$($rule.model) $($rule.complexities -join ',') $($rule.fallback.review)" 'deep-1 medium,high,review xhigh' 'the advisor rule'
Assert-Equal (Get-FallbackEffort $rule 'review' 'main-1' 'high' $false) 'xhigh' 'the project''s fallback effort'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Complexity:** review" @() @($list | ForEach-Object { $_.name })) -join ',') 'area:api,complexity:review' 'a follow-up of the project''s complexity'
Assert-Equal ((Get-FollowUpLabels @('area:api') "**Complexity:** review") -join ',') 'area:api' 'not without the project''s list'
$snapshot = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); complexities = $list
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
Assert-Equal (($snapshot.workers[0].takes | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'a worker takes each'
$review = $snapshot.complexities | Where-Object { $_.name -eq 'review' }
Assert-Equal "$($review.description)|$($review.model)|$($review.effort)|$($review.advisor)" 'A second look at a change|main-1|high|deep-1' 'the page gets each complexity'
$threw = $false
try { Get-Complexities $models ('{ "complexities": { "art": { "models": ["x"] } } }' | ConvertFrom-Json) | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'a complexity of the project''s own needs a description'
# The compact size: the complexity's own, else the project's, else models.json's; a name not in the list has medium's.
Assert-Equal "$(Get-ComplexityCompactAt $list 'low') $(Get-ComplexityCompactAt $list 'review') $(Get-ComplexityCompactAt $list 'none')" '250000 400000 250000' 'the project''s compact size, a complexity''s own, medium''s for no complexity'
Assert-Equal (Get-ComplexityCompactAt (Get-Complexities $models $null) 'design') 250000 'models.json''s compact size with no config'
# The page's size for a complexity (settings.json) goes over the project's and over the complexity's own; one for
# a name not in the list changes nothing.
$paged = Get-Complexities $models $own ('{ "complexities": { "review": { "compactAt": 90000 }, "low": { "compactAt": 300000 }, "gone": { "compactAt": 1 } } }' | ConvertFrom-Json)
Assert-Equal "$(Get-ComplexityCompactAt $paged 'low') $(Get-ComplexityCompactAt $paged 'review') $(Get-ComplexityCompactAt $paged 'high')" '300000 90000 250000' 'the page''s compact size over the project''s'
Assert-Equal $review.compactAt 400000 'the page gets each compact size'
# Only a size within the provider's range (models.json, `compactRange`): a size written as '250k' was once read as
# the least without a word. Any size where the provider gives no range.
Assert-Equal "$(ConvertTo-CompactAt 67000 'x' @(67000, 967000)) $(ConvertTo-CompactAt '967000' 'x' @(67000, 967000)) $(ConvertTo-CompactAt 5 'x')" '67000 967000 5' 'the ends of the range, and any size without one'
foreach ($bad in '"250k"', '66999', '967001', '250000.5', '""') {
    $threw = $false
    try { Get-Complexities $models ("{ `"compactAt`": $bad }" | ConvertFrom-Json) | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no compact size: $bad"
}
$threw = $false
try { Get-Complexities $models $null ('{ "complexities": { "low": { "compactAt": 5 } } }' | ConvertFrom-Json) | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'a bad compact size in settings.json stops the scripts'

# The owner's pick of a model on the page (settings.json, `complexities.<name>.model`) is the complexity's one
# candidate, and `base` keeps the first candidate without it. A complexity with no models follows medium's pick; a pick
# for a name not in the list changes nothing.
$picked = Get-Complexities $models $own ('{ "complexities": { "medium": { "model": "small-1@low" }, "review": { "model": "deep-1@max" }, "gone": { "model": "x" } } }' | ConvertFrom-Json)
Assert-Equal ((Get-ComplexityModels $picked 'medium') -join ',') 'small-1@low' 'the page''s pick is the one candidate'
Assert-Equal "$(($picked | Where-Object { $_.name -eq 'medium' }).base) $(($picked | Where-Object { $_.name -eq 'review' }).base)" 'mid-1@high main-1@high' 'the base is the first candidate without the pick'
Assert-Equal "$((Get-ComplexityModels $picked 'tidy') -join ',') $((Get-ComplexityModels $picked 'high') -join ',')" 'small-1@low main-1@xhigh' 'no models: medium''s pick; no pick: its own'
Assert-Equal (($picked | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'a pick for a name not in the list changes nothing'
$alone = Get-Complexities $models $own ('{ "complexities": { "tidy": { "model": "small-1@low" } } }' | ConvertFrom-Json)
Assert-Equal "$((Get-ComplexityModels $alone 'tidy') -join ',') $((Get-ComplexityModels $alone 'medium') -join ',')" 'small-1@low mid-1@high' 'a pick leaves medium alone'
# A pick as its model and effort: after `@`, else the model's in models.json, xhigh for a model not listed.
Assert-Equal ((@('main-1@high', 'main-1', 'x') | ForEach-Object { $run = Split-Pick $models $_; "$($run.model)=$($run.effort)" }) -join ' ') 'main-1=high main-1=medium x=xhigh' 'a pick as its model and effort'
# The page offers models.json's two lists, and nothing else is saved: they hold every model and effort that
# models.json itself names.
$view = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); complexities = $picked
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
$named = @($models.complexities.PSObject.Properties | ForEach-Object { $_.Value.models }) + @($models.windows.deep.after) +
    @($models.models.PSObject.Properties | ForEach-Object { $_.Name }) | ForEach-Object { Split-Pick $models $_ }
Assert-Equal "$($named.Count -gt 8) $(@($named | Where-Object { $view.models -cnotcontains $_.model -or $view.efforts -cnotcontains $_.effort }).Count)" 'True 0' 'the two lists hold every model and effort that models.json names'
$medium = $view.complexities | Where-Object { $_.name -eq 'medium' }
Assert-Equal "$($medium.model) $($medium.effort) $($medium.base.model) $($medium.base.effort)" 'small-1 low mid-1 high' 'the page gets the pick and the base'
Assert-Equal ($view.workers[0].takes | Where-Object { $_.name -eq 'medium' }).model 'small-1' 'a worker runs on the pick'
Assert-Equal "$($medium.advisor)|$(($view.complexities | Where-Object { $_.name -eq 'review' }).advisor)|" 'deep-1||' 'no advisor for a run on the advisor''s own model'
# The pick as a change to the settings: saved as model@effort beside what is there; the base's own pick takes it away
# and makes no entry.
$file = '{ "complexities": { "low": { "compactAt": 300000 } } }' | ConvertFrom-Json
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'low' 'small-1' 'max'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'tidy' 'main-1' 'low'
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000,"model":"small-1@max"},"tidy":{"model":"main-1@low"}}' 'a pick is saved as model@effort'
Assert-Equal ((Get-ComplexityModels (Get-Complexities $models $own $file) 'low') -join ',') 'small-1@max' 'the worker reads the saved pick'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'low' 'main-1' 'medium'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'high' 'main-1' 'xhigh'
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000},"tidy":{"model":"main-1@low"}}' 'the base''s pick is not saved'
foreach ($bad in @('none', 'main-1', 'high'), @('low', 'main', 'high'), @('low', 'main 1 with extra high', 'high'), @('low', 'main-1', 'extra high'), @('low', '', '')) {
    $threw = $false
    try { Set-ComplexityModel $file $models (Get-Complexities $models $own $file) $bad[0] $bad[1] $bad[2] | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no pick: $($bad -join ' / ')"
}
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000},"tidy":{"model":"main-1@low"}}' 'a refused pick changes nothing'
# A model that the project names outside models.json's list stays a valid pick for its complexity: its effort alone
# changes, and the way back to it is open.
$other = '{ "complexities": { "low": { "models": ["main-0@high"] } } }' | ConvertFrom-Json
$file = Set-ComplexityModel ('{}' | ConvertFrom-Json) $models (Get-Complexities $models $other) 'low' 'main-0' 'max'
Assert-Equal $file.complexities.low.model 'main-0@max' 'the base''s own model with another effort'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $other $file) 'low' 'main-0' 'high'
Assert-Equal ($file.complexities.low | ConvertTo-Json -Compress) '{}' 'and back to the base'

# The owner's advisor switch and fallback effort (settings.json, `complexities.<name>.advisor`, `.advisorFallback`) go
# over the project's file, also as off and as '': review has the advisor and xhigh without it in scriptorium.json.
$file = Set-ComplexityAdvisor ('{}' | ConvertFrom-Json) $models $list 'review' $false 'xhigh'
Assert-Equal ($file.complexities | ConvertTo-Json -Compress) '{"review":{"advisor":false}}' 'off is saved, the fallback of the file is not'
$off = Get-Complexities $models $own $file
$rule = Get-AdvisorRule $models $off
Assert-Equal "$(@($rule.complexities) -join ',')|$($rule.fallback.review)" 'medium,high|' 'a complexity switched off has no advisor'
Assert-Equal (Get-FallbackEffort $rule 'review' 'main-1' 'high' $false) 'high' 'and no fallback effort'
$file = Set-ComplexityAdvisor $file $models $off 'review' $true ''
Assert-Equal ($file.complexities | ConvertTo-Json -Compress) '{"review":{"advisorFallback":""}}' 'on as in the file; no other effort is saved'
$rule = Get-AdvisorRule $models (Get-Complexities $models $own $file)
Assert-Equal "$(@($rule.complexities) -join ',')|$($rule.fallback.review)" 'medium,high,review|' 'the advisor with the fallback '''''
Assert-Equal (Get-FallbackEffort $rule 'review' 'main-1' 'high' $false) 'high' 'the same effort without the advisor'
$file = Set-ComplexityAdvisor $file $models (Get-Complexities $models $own $file) 'review' $true 'xhigh'
$file = Set-ComplexityAdvisor $file $models (Get-Complexities $models $own $file) 'low' $true 'max'
Assert-Equal ($file.complexities | ConvertTo-Json -Compress) '{"review":{},"low":{"advisor":true,"advisorFallback":"max"}}' 'the values of the files leave no key'
$picked = @(Get-Complexities $models $own $file) | Where-Object { $_.name -eq 'low' }
Assert-Equal "$($picked.advisor) $($picked.advisorFallback) $($picked.baseAdvisor) '$($picked.baseFallback)'" "True max False ''" 'the pick and the values of the files'
foreach ($bad in @('none', $true, 'high'), @('low', $true, 'extra high'), @('low', $true, 'High')) {
    $threw = $false
    try { Set-ComplexityAdvisor $file $models $list $bad[0] $bad[1] $bad[2] | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no advisor pick: $($bad -join ' / ')"
}
# The advisor's model: the owner's pick for the project goes over models.json's; models.json's own is not saved.
$file = Set-AdvisorModel $file $models 'main-1'
Assert-Equal (Get-AdvisorRule $models $list $file).model 'main-1' 'the advisor''s model of the settings'
Assert-Equal (Get-AdvisorRule $models $list $null).model 'deep-1' 'models.json''s without settings'
$file = Set-AdvisorModel $file $models 'deep-1'
Assert-Equal ($file.advisor | ConvertTo-Json -Compress) '{}' 'models.json''s advisor model is not saved'
foreach ($bad in 'main-0', 'main', '') {
    $threw = $false
    try { Set-AdvisorModel $file $models $bad | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no advisor model: '$bad'"
}
# The project's colour: #rrggbb in lower case; '' takes it away.
$file = Set-ProjectColor $file '#A0b1C2'
Assert-Equal $file.color '#a0b1c2' 'a colour in lower case'
foreach ($bad in 'red', '#abc', '#a0b1c2ff', 'a0b1c2', "#a0b1c2`n", '#g0b1c2') {
    $threw = $false
    try { Set-ProjectColor $file $bad | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no colour: '$bad'"
}
Assert-Equal $file.color '#a0b1c2' 'a refused colour changes nothing'
$file = Set-ProjectColor $file ''
Assert-Equal $file.PSObject.Properties['color'] $null 'no colour'

# The page's address on Tailscale is read from Serve's own mapping (the shape of `tailscale serve status --json`), and
# setup gives a later project an address that no other one has.
$site = '"pc.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8770"}}}'
$one = "{`"TCP`":{`"443`":{`"HTTPS`":true}},`"Web`":{$site}}" | ConvertFrom-Json
$two = "{`"TCP`":{`"443`":{`"HTTPS`":true},`"8443`":{`"HTTPS`":true}},`"Web`":{$site,`"pc.tail.ts.net:8443`":{`"Handlers`":{`"/`":{`"Proxy`":`"http://127.0.0.1:8771`"}}}}}" | ConvertFrom-Json
$empty = '{}' | ConvertFrom-Json
Assert-Equal (Get-ServeUrl $one 8770) 'https://pc.tail.ts.net' 'the PC''s plain address'
Assert-Equal (Get-ServeUrl $two 8771) 'https://pc.tail.ts.net:8443' 'an address with a port'
Assert-Equal "$(Get-ServeUrl $one 8771)|$(Get-ServeUrl $one 877)|$(Get-ServeUrl $empty 8770)|$(Get-ServeUrl $null 8770)" '|||' 'no address: another port, a port that this one starts with, nothing served, no Tailscale'
$path = '{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail.ts.net:443":{"Handlers":{"/docs":{"Proxy":"http://127.0.0.1:8770"}}}}}' | ConvertFrom-Json
$plain = '{"TCP":{"80":{"HTTP":true}},"Web":{"pc.tail.ts.net:80":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8770"}}}}}' | ConvertFrom-Json
Assert-Equal "$(Get-ServeUrl $path 8770)|$(Get-ServeUrl $plain 8770)" '|' 'a path and plain HTTP are no address of the page'
Assert-Equal (Get-ServeCommand $empty 8770) 'serve --bg 8770' 'the first project gets the plain address'
Assert-Equal "$(Get-ServeCommand $one 8770)|$(Get-ServeCommand $two 8771)|$(Get-ServeCommand $null 8770)" '||' 'nothing to run: the address is there, or the mapping cannot be read'
Assert-Equal (Get-ServeCommand $one 8771) 'serve --bg --https=8443 8771' 'a second project never takes the plain address'
Assert-Equal (Get-ServeCommand $two 8772) 'serve --bg --https=8444 8772' 'a third project gets the next port'
Assert-Equal (Get-ServeCommand $one 8443) 'serve --bg --https=8444 8443' 'never the page''s own port'
Assert-Equal (Get-ServeCommand $path 8770) 'serve --bg --https=8443 8770' 'port 443 with another use stays as it is'
$forward = '{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}}}' | ConvertFrom-Json
Assert-Equal (Get-ServeCommand $forward 8770) 'serve --bg --https=8443 8770' 'also a forwarder at port 443'
Assert-Equal "$(Get-ServeOffCommand $one 8770)|$(Get-ServeOffCommand $two 8771)" 'serve --https=443 off|serve --https=8443 off' 'uninstall takes off the address of its port'
Assert-Equal "$(Get-ServeOffCommand $two 8772)|$(Get-ServeOffCommand $path 8770)|$(Get-ServeOffCommand $null 8770)" '||' 'and nothing else'

# One app for every project of the PC: the projects with their addresses, the pages that may ask a server, and the
# address a push opens.
Assert-Equal (Get-TaskProject '-File "C:\S\app\server.ps1" -Project "D:\My Work\App"') 'D:\My Work\App' 'a task''s project, with a space'
Assert-Equal "$(Get-TaskProject '-File C:\S\app\server.ps1 -Project D:\Work\App -Port 9')|$(Get-TaskProject '-File C:\S\x.ps1')" 'D:\Work\App|' 'a bare path, and no project'
$pc = @([pscustomobject]@{ name = 'Game'; port = 8770 }, [pscustomobject]@{ name = 'App'; port = 8771 }, [pscustomobject]@{ name = 'Tool'; port = 8772 })
$views = Get-ProjectViews $pc $two
Assert-Equal (($views | ForEach-Object { "$($_.name) $($_.local) $($_.url)" }) -join '; ') 'App http://127.0.0.1:8771 https://pc.tail.ts.net:8443; Game http://127.0.0.1:8770 https://pc.tail.ts.net; Tool http://127.0.0.1:8772 ' 'each project with its two addresses'
# The main checkout of a project stays on the server: the page gets no path.
$withMain = @([pscustomobject]@{ name = 'Game'; port = 8770; main = 'D:\Work\Game' })
$json = Get-ProjectViews $withMain $null | ConvertTo-Json -Compress
Assert-Equal ($json -match 'main|Work') $false 'no path in the views'
$alone = @(Get-ProjectViews @($pc[0]) $null)
Assert-Equal "$($alone.Count) $($alone[0].name) $($alone[0].url)" '1 Game ' 'one project, no Tailscale'
Assert-Equal "$(Get-PageOrigin $views 'http://127.0.0.1:8771')|$(Get-PageOrigin $views 'https://pc.tail.ts.net')|$(Get-PageOrigin $views 'https://pc.tail.ts.net:8443')" 'http://127.0.0.1:8771|https://pc.tail.ts.net|https://pc.tail.ts.net:8443' 'the pages of the PC''s projects may ask'
foreach ($foreign in 'https://evil.example', 'http://127.0.0.1:9999', 'https://pc.tail.ts.net:9443', 'https://pc.tail.ts.net.evil.example', 'HTTPS://PC.TAIL.TS.NET', 'http://127.0.0.1:8771/', 'null', '') {
    Assert-Equal (Get-PageOrigin $views $foreign) '' "no other page may ask: '$foreign'"
}
Assert-Equal (Get-PageOrigin @() 'http://127.0.0.1:8770') '' 'no list, no page'
Assert-Equal (Get-PushUrl $views 'https://pc.tail.ts.net:8443' 'questions') 'https://pc.tail.ts.net/#questions' 'a push opens the app at the plain address'
Assert-Equal (Get-PushUrl (Get-ProjectViews $pc $null) 'http://127.0.0.1:8771' 'queue') 'http://127.0.0.1:8771/#queue' 'without Tailscale, the project''s own address'
$snapshot = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); name = 'App'; projects = $views }
Assert-Equal "$($snapshot.name) $(@($snapshot.projects).Count) $($snapshot.projects[0].name)" 'App 3 App' 'the snapshot names the project and lists the PC''s projects'
Assert-Equal @((New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).projects).Count 0 'a snapshot without the list'

# The PC's files (pc.ps1). The settings of two projects merge into one register: an account is its login folder, a
# name that another folder has gets a number, uses add up, and only missing fields come in.
function New-Json([string] $text) {
    return $text | ConvertFrom-Json
}
$game = '{"accounts":{"main":{"stopAt":{"short":0.9},"uses":["frontdesk","personal","worker:1"]},"second":{"configDir":"C:/Users/u/.test-second","uses":[]}},"keep":{"personal":0.07},"workers":{"1":{"enabled":true},"3":{"enabled":false}},"ntfy":{"topic":"t"}}'
$app = '{"accounts":{"main":{"uses":["personal","worker:4"]},"second":{"configDir":"C:\\Users\\u\\.test-other\\","uses":["worker:5"]}},"keep":{"personal":0.15,"frontdesk":0.1},"workers":{"4":{"enabled":true},"3":{"enabled":true,"ghConfigDir":"x"}}}'
function Show-Register($pc) {
    $accounts = $pc.accounts.PSObject.Properties | ForEach-Object { "$(Get-FolderKey ([string]$_.Value.configDir))=$(@($_.Value.uses | Sort-Object) -join ',')/$([bool]$_.Value.stopAt)" } | Sort-Object
    return "$($accounts -join ' ') keep=$($pc.keep.personal),$($pc.keep.frontdesk) workers=$(($pc.workers.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Value.enabled):$($_.Value.ghConfigDir)" }) -join ',')"
}
$merged = Merge-PcSettings (Merge-PcSettings ([pscustomobject]@{}) (New-Json $game)) (New-Json $app)
Assert-Equal (Show-Register $merged) '=frontdesk,personal,worker:1,worker:4/True c:/users/u/.test-other=worker:5/False c:/users/u/.test-second=/False keep=0.07,0.1 workers=1:True:,3:False:x,4:True:' 'two projects merge into one register'
Assert-Equal (@($merged.accounts.PSObject.Properties.Name) -join ',') 'main,second,second-2' 'a name that another login folder has gets a number'
Assert-Equal $merged.ntfy $null 'only the PC keys merge'
$again = Merge-PcSettings $merged (New-Json $app)
Assert-Equal (Show-Register $again) (Show-Register $merged) 'a second merge of the same project changes nothing'
Assert-Equal @($again.accounts.PSObject.Properties).Count 3 'and adds no entry'
$other = Merge-PcSettings (Merge-PcSettings ([pscustomobject]@{}) (New-Json '{"accounts":{"main":{"uses":["personal","worker:4"]}},"workers":{"4":{"enabled":true}}}')) (New-Json '{"accounts":{"main":{"stopAt":{"short":0.9},"uses":["frontdesk","personal","worker:1"]}},"workers":{"1":{"enabled":false}}}')
Assert-Equal (Show-Register $other) '=frontdesk,personal,worker:1,worker:4/True keep=, workers=1:False:,4:True:' 'the other order of the projects gives the same register'

# On disk: a read moves a project's PC keys to the PC's file, once; a save puts each key into its file.
$one = Join-Path $PcDir 'one'
$two = Join-Path $PcDir 'two'
New-Item -ItemType Directory -Force (Join-Path $one '.queue'), (Join-Path $two '.queue') | Out-Null
$PcDir = Join-Path $PcDir 'pc'
Assert-Equal (Read-ProjectSettings $one) $null 'no settings anywhere'
Set-Content (Join-Path $one '.queue/settings.json') $game -Encoding utf8
Set-Content (Join-Path $two '.queue/settings.json') $app -Encoding utf8
$read = Read-ProjectSettings $one
Assert-Equal "$($read.ntfy.topic) $(@($read.accounts.main.uses).Count) $($read.workers.'3'.enabled)" 't 3 False' 'the settings of a project with the PC keys'
Assert-Equal ((Get-Content (Join-Path $one '.queue/settings.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name -join ',') 'ntfy' 'the project''s file keeps its own keys only'
Assert-Equal ((Read-PcSettings).PSObject.Properties.Name -join ',') 'accounts,keep,workers' 'the PC''s file has the PC keys'
Initialize-Pc $two
Initialize-Pc $two
Assert-Equal (Show-Register (Read-PcSettings)) (Show-Register $merged) 'the second project joins the same register, also when the move runs twice'
$read = Read-ProjectSettings $two
Assert-Equal "$($read.ntfy) $(@($read.accounts.main.uses).Count)" ' 4' 'the second project reads the PC''s register, and no key of the first'
$read.workers.'4'.enabled = $false
Set-JsonProperty $read 'model' 'main-1'
Save-ProjectSettings $two $read
Assert-Equal "$((Read-ProjectSettings $one).workers.'4'.enabled) $((Read-ProjectSettings $one).model)" 'False ' 'a save of a PC key reaches the other project; a key of its own does not'
Assert-Equal (Get-Content (Join-Path $two '.queue/settings.json') -Raw | ConvertFrom-Json).model 'main-1' 'the project''s own key is in its file'
# A file that does not parse is not an empty one.
Set-Content (Join-Path $PcDir 'settings.json') '{ "accounts": ' -Encoding utf8
$threw = $false
try {
    Read-ProjectSettings $one | Out-Null
} catch {
    $threw = $true
}
Assert-Equal $threw $true 'a PC file that does not parse stops the read'
Set-Content (Join-Path $PcDir 'settings.json') '' -Encoding utf8
$threw = $false
try {
    Read-ProjectSettings $one | Out-Null
} catch {
    $threw = $true
}
Assert-Equal $threw $true 'so does an empty one'

# The accounts' records move too: the newer reading goes on, with the window that only the older one has.
Set-Content (Join-Path $one '.queue/usage.json') '{"default":{"at":5,"short":{"used":0.1},"deep":{"used":0.4}},"x":{"at":1}}' -Encoding utf8
Set-Content (Join-Path $PcDir 'usage.json') '{"default":{"at":9,"short":{"used":0.3}}}' -Encoding utf8
Set-Content (Join-Path $one '.queue/out.json') 'not json' -Encoding utf8
Move-PcRecords $one
$usage = Get-Content (Join-Path $PcDir 'usage.json') -Raw | ConvertFrom-Json
Assert-Equal "$($usage.default.at) $($usage.default.short.used) $($usage.default.deep.used) $($usage.x.at)" '9 0.3 0.4 1' 'the usage of two projects in one file'
Assert-Equal "$(Test-Path (Join-Path $one '.queue/usage.json')) $(Test-Path (Join-Path $one '.queue/out.json')) $(Test-Path (Join-Path $PcDir 'out.json'))" 'False False False' 'the project keeps no record; one that does not parse is dropped'

# An account is one provider's (docs/QUEUE.md, Accounts). A PC from before that has accounts with no provider: a
# project whose worker is on one of them claims them all, in any order of the projects. A project that is new on the
# PC has no worker there, so it claims none, whichever starts first.
function Claim([string] $json, [string[]] $workers, [string] $provider) {
    $settings = $json | ConvertFrom-Json
    $changed = Set-AccountProviders $settings $workers $provider
    return "$changed $(($settings.accounts.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.provider)" }) -join ' ')"
}
$old = '{"accounts":{"main":{"stopAt":{"short":0.97},"pickUp":{"short":{"S":0.92}},"uses":["personal","frontdesk","worker:1","worker:3"]},"second":{"configDir":"C:/u/.one-second","uses":[]}}}'
Assert-Equal (Claim $old @('3') 'one') 'True main=one second=one' 'the old project claims every account that names no provider'
Assert-Equal (Claim $old @('6') 'two') 'False main= second=' 'a project that is new on the PC claims none'
Assert-Equal (Claim $old @() 'two') 'False main= second=' 'a project with no worker claims none'
Assert-Equal (Claim $old @('3') '') 'False main= second=' 'a project with no provider claims none'
$claimed = $old | ConvertFrom-Json
[void](Set-AccountProviders $claimed @('1') 'one')
Assert-Equal ($claimed | ConvertTo-Json -Depth 8 -Compress) '{"accounts":{"main":{"stopAt":{"short":0.97},"pickUp":{"short":{"S":0.92}},"uses":["personal","frontdesk","worker:1","worker:3"],"provider":"one"},"second":{"configDir":"C:/u/.one-second","uses":[],"provider":"one"}}}' 'a claim changes nothing else of an account'
Assert-Equal (Claim ($claimed | ConvertTo-Json -Depth 8 -Compress) @('1') 'two') 'False main=one second=one' 'an account keeps its provider'
# The new project first, then the old one: the same end.
$mixed = '{"accounts":{"main":{"uses":["worker:1"]},"two":{"provider":"two","configDir":"C:/u/.two-two","uses":["worker:6"]}}}'
Assert-Equal (Claim $mixed @('6') 'two') 'False main= two=two' 'the new project''s own account is no reason to claim the old ones'
Assert-Equal (Claim $mixed @('1') 'one') 'True main=one two=two' 'the old project claims its own after the new one'
# Whose the command-line login is: the PC's one entry with no folder.
$pcAccounts = $mixed | ConvertFrom-Json
Assert-Equal "$(Test-AccountOf $pcAccounts.accounts.two 'two') $(Test-AccountOf $pcAccounts.accounts.two 'one') $(Test-AccountOf $pcAccounts.accounts.main 'one') $(Test-AccountOf $pcAccounts.accounts.two '')" 'True False False False' 'an account is of the provider it names'
Assert-Equal "$(Test-LoginTaken $pcAccounts 'two') $(Test-LoginTaken $pcAccounts 'one')" 'True True' 'a command-line login that no provider has claimed is taken'
[void](Set-AccountProviders $pcAccounts @('1') 'one')
Assert-Equal "$(Test-LoginTaken $pcAccounts 'two') $(Test-LoginTaken $pcAccounts 'one') $(Test-LoginTaken ('{"accounts":{"x":{"configDir":"C:/x"}}}' | ConvertFrom-Json) 'two') $(Test-LoginTaken $null 'two')" 'True False False False' 'the command-line login is taken from every provider but its own; a PC without such an entry has none taken'
# Setup puts a project's workers on accounts of its provider.
function Place([string] $json, [string[]] $workers, [string] $provider) {
    $settings = $json | ConvertFrom-Json
    $changed = Set-WorkerAccounts $settings $workers $provider 'C:\Users\me'
    return "$changed $($settings.accounts | ConvertTo-Json -Depth 8 -Compress)"
}
Assert-Equal (Place '{}' @('1', '2') 'one') 'True {"main":{"uses":["worker:1","worker:2","personal"],"provider":"one"}}' 'a PC with no accounts gets the command-line login, of the project''s provider'
Assert-Equal (Place '{}' @('1') '') 'True {"main":{"uses":["worker:1","personal"]}}' 'a project with no provider: an account with none'
# The shape of a PC from before an account had a provider: the project's own setup claims the accounts and changes
# nothing else; a worker more goes to the command-line login.
$real = '{"accounts":{"main":{"weeklyOverride":false,"stopAt":{"long":1,"short":0.97},"pickUp":{"short":{"S":0.92,"M":0.86,"L":0.76}},"uses":["personal","frontdesk","worker:1","worker:2","worker:3"]},"second":{"configDir":"C:/Users/me/.one-second","stopAt":{"short":0.95},"uses":[]}}}'
Assert-Equal (Place $real @('3') 'one') 'True {"main":{"weeklyOverride":false,"stopAt":{"long":1,"short":0.97},"pickUp":{"short":{"S":0.92,"M":0.86,"L":0.76}},"uses":["personal","frontdesk","worker:1","worker:2","worker:3"],"provider":"one"},"second":{"configDir":"C:/Users/me/.one-second","stopAt":{"short":0.95},"uses":[],"provider":"one"}}' 'the setup of an old project claims its accounts'
Assert-Equal ((Place $real @('3', '4') 'one') -like '*"worker:3","worker:4"]*') $true 'a worker more goes to the command-line login of its provider'
# A project of another coding tool, new on that PC, before and after the old project claimed: its worker never goes
# on the command-line login. It gets an account of its own, named after the provider, with a folder as its key.
$expected = '"two":{"configDir":"C:/Users/me/.two-two","provider":"two","uses":["worker:6"]}}'
Assert-Equal ((Place $real @('6') 'two').EndsWith($expected)) $true 'a new tool''s first worker gets an account of its own'
Assert-Equal ((Place $real @('6') 'two') -match '"uses":\["personal","frontdesk","worker:1","worker:2","worker:3"\]\},"second"') $true 'the old accounts stay as they are, with no provider'
$after = (Place $real @('3') 'one').Substring(5)
Assert-Equal ((Place "{`"accounts`":$after}" @('6') 'two').EndsWith($expected)) $true 'the same after the old project claimed'
# Its second worker goes to that account, and a name that is taken gets a number.
Assert-Equal ((Place "{`"accounts`":$((Place $real @('6') 'two').Substring(5))}" @('6', '7') 'two').EndsWith('"two":{"configDir":"C:/Users/me/.two-two","provider":"two","uses":["worker:6","worker:7"]}}')) $true 'a second worker goes to the provider''s first account'
Assert-Equal ((Place '{"accounts":{"two":{"provider":"one","uses":["worker:1"]}}}' @('6') 'two').EndsWith('"two-2":{"configDir":"C:/Users/me/.two-two-2","provider":"two","uses":["worker:6"]}}')) $true 'a name that is taken gets a number'
# A PC whose accounts all have folders: a new worker is in none, as before.
Assert-Equal (Place '{"accounts":{"a":{"provider":"one","configDir":"C:/a","uses":["worker:1"]}}}' @('1', '2') 'one') 'False {"a":{"provider":"one","configDir":"C:/a","uses":["worker:1"]}}' 'no command-line login entry: a new worker is in no entry'
# Under the lock, on the PC's file: a project's settings come back with the claim.
New-Item -ItemType Directory -Force $PcDir, (Join-Path $one '.queue') | Out-Null
Set-Content (Join-Path $PcDir 'settings.json') $old -Encoding utf8
Update-AccountProviders $one @('1') 'one'
Assert-Equal ((Read-ProjectSettings $one).accounts.second.provider) 'one' 'the claim is saved in the PC''s file'

Remove-Item (Split-Path $PcDir) -Recurse -Force

Write-Output 'ok'
