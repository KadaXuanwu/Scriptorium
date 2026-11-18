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
$own = '{ "name": "App", "compactAt": 250000, "complexities": { "medium": { "models": ["claude-sonnet-5-5@high"] },
    "review": { "description": "A second look at a change", "models": ["claude-opus-5-5@high"], "advisor": true, "advisorFallback": "xhigh", "compactAt": 400000 },
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
# The compact size: the complexity's own, else the project's, else models.json's; a name not in the list has medium's.
Assert-Equal "$(Get-ComplexityCompactAt $list 'low') $(Get-ComplexityCompactAt $list 'review') $(Get-ComplexityCompactAt $list 'none')" '250000 400000 250000' 'the project''s compact size, a complexity''s own, medium''s for no complexity'
Assert-Equal (Get-ComplexityCompactAt (Get-Complexities $models $null) 'design') 167000 'models.json''s compact size with no config'
# The page's size for a complexity (settings.json) goes over the project's and over the complexity's own; one for
# a name not in the list changes nothing.
$paged = Get-Complexities $models $own ('{ "complexities": { "review": { "compactAt": 90000 }, "low": { "compactAt": 300000 }, "gone": { "compactAt": 1 } } }' | ConvertFrom-Json)
Assert-Equal "$(Get-ComplexityCompactAt $paged 'low') $(Get-ComplexityCompactAt $paged 'review') $(Get-ComplexityCompactAt $paged 'high')" '300000 90000 250000' 'the page''s compact size over the project''s'
Assert-Equal $review.compactAt 400000 'the page gets each compact size'
# Claude Code gets the window that compacts there: 33k more.
Assert-Equal (Get-CompactWindow 250000) 283000 'the window of a compact size'
# Only what makes a window Claude Code takes (100k to 1M): it read '250k' as its minimum without a word.
Assert-Equal "$(ConvertTo-CompactAt 67000 'x') $(ConvertTo-CompactAt '967000' 'x')" '67000 967000' 'the ends of the range'
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
$picked = Get-Complexities $models $own ('{ "complexities": { "medium": { "model": "claude-haiku-5-5@low" }, "review": { "model": "claude-fable-5-2@max" }, "gone": { "model": "x" } } }' | ConvertFrom-Json)
Assert-Equal ((Get-ComplexityModels $picked 'medium') -join ',') 'claude-haiku-5-5@low' 'the page''s pick is the one candidate'
Assert-Equal "$(($picked | Where-Object { $_.name -eq 'medium' }).base) $(($picked | Where-Object { $_.name -eq 'review' }).base)" 'claude-sonnet-5-5@high claude-opus-5-5@high' 'the base is the first candidate without the pick'
Assert-Equal "$((Get-ComplexityModels $picked 'tidy') -join ',') $((Get-ComplexityModels $picked 'high') -join ',')" 'claude-haiku-5-5@low claude-opus-5-5@xhigh' 'no models: medium''s pick; no pick: its own'
Assert-Equal (($picked | ForEach-Object { $_.name }) -join ',') 'low,medium,high,review,tidy,design' 'a pick for a name not in the list changes nothing'
$alone = Get-Complexities $models $own ('{ "complexities": { "tidy": { "model": "claude-haiku-5-5@low" } } }' | ConvertFrom-Json)
Assert-Equal "$((Get-ComplexityModels $alone 'tidy') -join ',') $((Get-ComplexityModels $alone 'medium') -join ',')" 'claude-haiku-5-5@low claude-sonnet-5-5@high' 'a pick leaves medium alone'
# A pick as its model and effort: after `@`, else the model's in models.json, xhigh for a model not listed.
Assert-Equal ((@('claude-opus-5-5@high', 'claude-opus-5-5', 'x') | ForEach-Object { $run = Split-Pick $models $_; "$($run.model)=$($run.effort)" }) -join ' ') 'claude-opus-5-5=high claude-opus-5-5=medium x=xhigh' 'a pick as its model and effort'
# The page offers models.json's two lists, and nothing else is saved: they hold every model and effort that
# models.json itself names.
$view = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); complexities = $picked
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
$named = @($models.complexities.PSObject.Properties | ForEach-Object { $_.Value.models }) + @($models.afterFable) +
    @($models.models.PSObject.Properties | ForEach-Object { $_.Name }) | ForEach-Object { Split-Pick $models $_ }
Assert-Equal "$($named.Count -gt 8) $(@($named | Where-Object { $view.models -cnotcontains $_.model -or $view.efforts -cnotcontains $_.effort }).Count)" 'True 0' 'the two lists hold every model and effort that models.json names'
$medium = $view.complexities | Where-Object { $_.name -eq 'medium' }
Assert-Equal "$($medium.model) $($medium.effort) $($medium.base.model) $($medium.base.effort)" 'claude-haiku-5-5 low claude-sonnet-5-5 high' 'the page gets the pick and the base'
Assert-Equal ($view.workers[0].takes | Where-Object { $_.name -eq 'medium' }).model 'claude-haiku-5-5' 'a worker runs on the pick'
Assert-Equal "$($medium.advisor)|$(($view.complexities | Where-Object { $_.name -eq 'review' }).advisor)|" 'claude-fable-5-2||' 'no advisor for a run on the advisor''s own model'
# The pick as a change to the settings: saved as model@effort beside what is there; the base's own pick takes it away
# and makes no entry.
$file = '{ "complexities": { "low": { "compactAt": 300000 } } }' | ConvertFrom-Json
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'low' 'claude-haiku-5-5' 'max'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'tidy' 'claude-opus-5-5' 'low'
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000,"model":"claude-haiku-5-5@max"},"tidy":{"model":"claude-opus-5-5@low"}}' 'a pick is saved as model@effort'
Assert-Equal ((Get-ComplexityModels (Get-Complexities $models $own $file) 'low') -join ',') 'claude-haiku-5-5@max' 'the worker reads the saved pick'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'low' 'claude-opus-5-5' 'medium'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $own $file) 'high' 'claude-opus-5-5' 'xhigh'
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000},"tidy":{"model":"claude-opus-5-5@low"}}' 'the base''s pick is not saved'
foreach ($bad in @('none', 'claude-opus-5-5', 'high'), @('low', 'opus', 'high'), @('low', 'claude opus 5.5 with extra high', 'high'), @('low', 'claude-opus-5-5', 'extra high'), @('low', '', '')) {
    $threw = $false
    try { Set-ComplexityModel $file $models (Get-Complexities $models $own $file) $bad[0] $bad[1] $bad[2] | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no pick: $($bad -join ' / ')"
}
Assert-Equal ($file.complexities | ConvertTo-Json -Depth 8 -Compress) '{"low":{"compactAt":300000},"tidy":{"model":"claude-opus-5-5@low"}}' 'a refused pick changes nothing'
# A model that the project names outside models.json's list stays a valid pick for its complexity: its effort alone
# changes, and the way back to it is open.
$other = '{ "complexities": { "low": { "models": ["claude-opus-4-8@high"] } } }' | ConvertFrom-Json
$file = Set-ComplexityModel ('{}' | ConvertFrom-Json) $models (Get-Complexities $models $other) 'low' 'claude-opus-4-8' 'max'
Assert-Equal $file.complexities.low.model 'claude-opus-4-8@max' 'the base''s own model with another effort'
$file = Set-ComplexityModel $file $models (Get-Complexities $models $other $file) 'low' 'claude-opus-4-8' 'high'
Assert-Equal ($file.complexities.low | ConvertTo-Json -Compress) '{}' 'and back to the base'

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

# One app for every project of the PC: the projects with their addresses, the pages that may ask a server, and the
# address a push opens.
Assert-Equal (Get-TaskProject '-File "C:\S\app\server.ps1" -Project "D:\My Work\App"') 'D:\My Work\App' 'a task''s project, with a space'
Assert-Equal "$(Get-TaskProject '-File C:\S\app\server.ps1 -Project D:\Work\App -Port 9')|$(Get-TaskProject '-File C:\S\x.ps1')" 'D:\Work\App|' 'a bare path, and no project'
$pc = @([pscustomobject]@{ name = 'Game'; port = 8770 }, [pscustomobject]@{ name = 'App'; port = 8771 }, [pscustomobject]@{ name = 'Tool'; port = 8772 })
$views = Get-ProjectViews $pc $two
Assert-Equal (($views | ForEach-Object { "$($_.name) $($_.local) $($_.url)" }) -join '; ') 'App http://127.0.0.1:8771 https://pc.tail.ts.net:8443; Game http://127.0.0.1:8770 https://pc.tail.ts.net; Tool http://127.0.0.1:8772 ' 'each project with its two addresses'
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

Write-Output 'ok'
