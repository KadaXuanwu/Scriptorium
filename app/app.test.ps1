# Checks state.ps1, the queue app's snapshot and notifications: powershell -NoProfile -File app\app.test.ps1
# (prints ok or throws).
$ErrorActionPreference = 'Stop'
# The PC's files of a test are in a folder of its own (pc.ps1): set before anything loads.
$PcDir = Join-Path $env:TEMP "scriptorium-test-$PID"
. (Join-Path $PSScriptRoot 'state.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

function Label([string] $name) {
    return [pscustomobject]@{ name = $name }
}

function Issue([int] $number, [string[]] $labels, [string] $body = '', [string] $created = '2026-10-10T10:00:00Z') {
    return [pscustomobject]@{
        number = $number; title = "Ticket $number"; url = "u$number"; body = $body; createdAt = $created
        labels = @($labels | ForEach-Object { Label $_ })
    }
}

function Pr([int] $number, [int] $ticket, [string[]] $labels, [string] $body = '') {
    return [pscustomobject]@{
        number = $number; title = "PR $number"; url = "p$number"; body = $body; headRefName = "t$ticket"; repo = 'o/r'
        labels = @($labels | ForEach-Object { Label $_ })
    }
}

# The control as the worker script reads it back from JSON.
function Json($value) {
    return ($value | ConvertTo-Json -Depth 5) | ConvertFrom-Json
}

# Worker status: the owner's pick becomes a control entry, `enabled`, or a kill, by how the run ends.
$set = Set-WorkerStatus $null '1' 'paused' 'finish' $true
Assert-Equal "$($set.control.workers['1']) $($set.enabled) $($set.kill)" 'drain True False' 'pause after the ticket is a drain'
$set = Set-WorkerStatus (Json $set.control) '2' 'paused' 'checkpoint' $true
Assert-Equal "$($set.control.workers['1']) $($set.control.workers['2']) $($set.kill)" 'drain stop False' 'pause at the checkpoint is a stop; worker 1 keeps its entry'
Assert-Equal (Set-WorkerStatus $null '1' 'paused' 'now' $true).kill $true 'pause now ends the run'
Assert-Equal (Set-WorkerStatus $null '1' 'paused' 'now' $false).kill $false 'no run, nothing to end'
Assert-Equal (Set-WorkerStatus $null '1' 'paused' 'finish' $false).control.workers['1'] 'stop' 'a free worker pauses at once'
$set = Set-WorkerStatus $null '1' 'disabled' 'finish' $true
Assert-Equal "$($set.control.workers['1']) $($set.control.disable['1']) $($set.enabled)" 'drain True True' 'disable after the ticket: a drain with a mark, still enabled'
$marked = Json $set.control
Assert-Equal ((Get-DueDisables $marked @{ '1' = 'running' }) -join ',') '' 'not due while the run works'
Assert-Equal ((Get-DueDisables $marked @{ '1' = 'paused' }) -join ',') '' 'not due while the run waits for its limit'
Assert-Equal ((Get-DueDisables $marked @{ '1' = 'drained' }) -join ',') '1' 'due when the run has ended'
$set = Set-WorkerStatus $null '1' 'disabled' 'checkpoint' $true
Assert-Equal "$($set.enabled) $($set.kill) $($set.control.workers['1'])" 'False False stop' 'disable at the checkpoint: not enabled, and a stop entry'
# From paused to disabled, the worker script never sees a moment with neither: the stop entry stays.
$set = Set-WorkerStatus (Json (Set-WorkerStatus $null '1' 'paused' 'now' $false).control) '1' 'disabled' 'now' $false
Assert-Equal "$($set.enabled) $($set.control.workers['1'])" 'False stop' 'paused to disabled keeps the stop entry'
$set = Set-WorkerStatus $marked '1' 'active' '' $true
Assert-Equal "$($set.enabled) $($set.control.workers.Count) $($set.control.disable.Count)" 'True 0 0' 'active discards the pause and the disable'
Assert-Equal (Get-Mode $marked '1') 'drain' 'mode read back'
Assert-Equal (Get-Mode $marked '2') '' 'no entry, no mode'

# The status shown: active until the run reaches the pause or the disable, with the target pending.
function Status([string] $raw, $mode, [bool] $enabled = $true, [bool] $marked = $false) {
    $s = Get-WorkerStatus $raw $mode $enabled $marked
    return "$($s.status) $($s.pending.to) $($s.pending.how)".Trim()
}
Assert-Equal (Status 'running' $null) 'active' 'running'
Assert-Equal (Status 'paused' $null) 'active' 'a worker at its usage limit stays active'
Assert-Equal (Status 'over-budget' $null) 'active' 'a worker at its stop line stays active'
Assert-Equal (Status 'running' 'drain') 'active paused finish' 'pause after the ticket is pending'
Assert-Equal (Status 'running' 'stop') 'active paused checkpoint' 'pause at the checkpoint is pending'
Assert-Equal (Status 'running' 'drain' $true $true) 'active disabled finish' 'disable after the ticket is pending'
Assert-Equal (Status 'paused' 'drain') 'active paused finish' 'a run at its limit finishes first under a drain'
Assert-Equal (Status 'paused' 'stop') 'paused' 'a stop holds a run at its limit'
Assert-Equal (Status 'idle' 'drain') 'paused' 'a free worker is paused before its script sees it'
Assert-Equal (Status 'drained' 'drain') 'paused' 'drained is paused'
Assert-Equal (Status 'drained' $null) 'active' 'set active before its script sees it'
Assert-Equal (Status 'running' $null $false) 'active disabled checkpoint' 'disable is pending while the run wraps up'
Assert-Equal (Status 'idle' $null $false) 'disabled' 'disabled'
Assert-Equal (Status 'stopped' 'stop' $false) 'disabled' 'a disabled worker with its stop entry shows disabled'

# Accounts: moving a worker takes it off every other account; the command-line login is in no entry; the round trip
# through JSON keeps single uses as lists.
$settings = '{"accounts":{"main":{"uses":["worker:1","frontdesk"]},"temp":{"configDir":"C:/t","uses":["worker:3"]}}}' | ConvertFrom-Json
$settings = (Set-WorkerAccount $settings '1' 'temp' | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal ($settings.accounts.main.uses -join ',') 'frontdesk' 'worker 1 left main'
Assert-Equal ($settings.accounts.temp.uses -join ',') 'worker:3,worker:1' 'worker 1 on temp'
$settings = (Set-WorkerAccount $settings '3' '' | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal (@($settings.accounts.temp.uses).Count) 1 'worker 3 on the command-line login'
Assert-Equal ($settings | ConvertTo-Json -Depth 8 -Compress) '{"accounts":{"main":{"uses":["frontdesk"]},"temp":{"configDir":"C:/t","uses":["worker:1"]}}}' 'lists stay lists'
$threw = $false
try { Set-WorkerAccount $settings '1' 'nope' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'unknown account'

# Add a worker and Remove: the lowest free number; a fresh entry on its account; removal takes it off every account.
Assert-Equal (Get-FreeWorkerId @('1', '3')) '2' 'a removed worker''s number comes back'
Assert-Equal (Get-FreeWorkerId @()) '1' 'the first worker'
Assert-Equal (Get-FreeWorkerId @('1', '2', '2')) '3' 'a number with a state file and a task is taken once'
$roster = '{"accounts":{"main":{"uses":["frontdesk"]},"temp":{"configDir":"C:/t","uses":["worker:1"]}},"workers":{"2":{"enabled":false,"ghConfigDir":"C:/g"}}}' | ConvertFrom-Json
$roster = (Set-WorkerEntry $roster '2' $true 'temp' | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal ($roster.workers.'2' | ConvertTo-Json -Compress) '{"enabled":true}' 'a new worker starts fresh and active'
Assert-Equal ($roster.accounts.temp.uses -join ',') 'worker:1,worker:2' 'a new worker on its account'
$roster = (Set-WorkerEntry $roster '1' $false | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal "$(@($roster.workers.PSObject.Properties).Count) $($roster.accounts.temp.uses -join ',')" '1 worker:2' 'a removed worker is on no account'
$fresh = [pscustomobject]@{ accounts = [pscustomobject]@{} }
Assert-Equal ((Get-WorkerSettings $fresh '5') -ne $null) $true 'an entry for a worker with none, also under a number'
$threw = $false
try { Set-WorkerEntry $roster '4' $true 'nope' | Out-Null } catch { $threw = $true }
Assert-Equal "$threw $($roster.workers.'4')" 'True ' 'an unknown account adds nothing'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'disabled' }) $false $false) '' 'a disabled worker goes'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'idle' }) $true $false) 'disable it first' 'an enabled worker stays'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'running' }) $false $false) 'its run has not ended yet' 'a run in flight keeps it'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'paused'; ticket = 5; resetsAt = 9 }) $false $false) 'its run has not ended yet' 'a held run keeps it'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'setup' }) $true $true) 'its setup still runs' 'not during its setup'
Assert-Equal (Get-RemoveRefusal ([pscustomobject]@{ state = 'running' }) $false $false $false) '' 'a dead script''s run does not hold it'
# A worker's move to another project: never during its setup or its run, never with a ticket that it holds.
function Refusal([hashtable] $state, [bool] $fresh = $true, [bool] $held = $false, [bool] $marked = $false) {
    return Get-MoveRefusal ([pscustomobject]$state) $fresh $held $marked
}
$holds = 'it holds a ticket: disable it first, then move it'
Assert-Equal (Refusal @{ state = 'idle' }) '' 'a free worker moves'
Assert-Equal (Refusal @{ state = 'disabled' }) '' 'a disabled worker moves'
Assert-Equal (Refusal @{ state = 'setup' }) 'its setup still runs' 'not during its setup'
$works = 'it works on a ticket: pause or disable it, and move it when its run has ended'
Assert-Equal (Refusal @{ state = 'running' }) $works 'not in a run'
Assert-Equal (Refusal @{ state = 'running' } $false) '' 'a dead script''s run does not hold it'
Assert-Equal (Refusal @{ state = 'stopped' } $true $true) $holds 'a run held in its copy'
Assert-Equal (Refusal @{ state = 'paused'; ticket = 5; resetsAt = 9 } $false) $holds 'a run that waits for its limit'
Assert-Equal (Refusal @{ state = 'drained' } $true $false $true) $holds 'a disable after its ticket'
# It arrives with its status: disabled from the PC's settings, paused from its old project's control, else active.
$pcWorkers = '{"workers":{"1":{"enabled":false},"2":{"enabled":true}}}' | ConvertFrom-Json
$oldControl = Json (Set-WorkerStatus $null '1' 'paused' 'now' $false).control
$oldControl = Json (Set-WorkerStatus $oldControl '2' 'paused' 'finish' $true).control
Assert-Equal (Get-CarriedStatus $pcWorkers $oldControl '1') 'disabled' 'a disabled worker arrives disabled'
Assert-Equal (Get-CarriedStatus $pcWorkers $oldControl '2') 'paused' 'a paused worker arrives paused'
Assert-Equal (Get-CarriedStatus $pcWorkers $oldControl '3') 'active' 'a worker with no entry arrives active'
Assert-Equal (Get-CarriedStatus $null $null '3') 'active' 'no settings and no control'
# A new worker's card: set up by the server, then its plugins make its environment ready, in their words. A failed
# setup never reads as a silent script; a hook that threw shows its error.
$setup = @(@{ id = '4'; state = [pscustomobject]@{ state = 'setup-failed'; at = 0; error = 'git clone failed' } })
$view = (New-Snapshot @{ now = 100000; slug = 'o/r'; runs = @(); settings = @{ workers = @{ '4' = @{ enabled = $false } } }; workers = $setup }).workers[0]
Assert-Equal "$($view.activity) $($view.status) $($view.error)" 'setup-failed disabled git clone failed' 'a failed setup'
$setup[0].state = [pscustomobject]@{ state = 'opening'; at = 10; report = 'Opening its editor' }
$view = (New-Snapshot @{ now = 20; slug = 'o/r'; runs = @(); workers = $setup }).workers[0]
Assert-Equal "$($view.activity): $($view.report)" 'opening: Opening its editor' 'a plugin makes the environment ready'
$setup[0].state = [pscustomobject]@{ state = 'error'; at = 10; error = 'plugin x, Start: no editor' }
$view = (New-Snapshot @{ now = 20; slug = 'o/r'; runs = @(); workers = $setup }).workers[0]
Assert-Equal "$($view.activity): $($view.error)" 'error: plugin x, Start: no editor' 'a hook that threw'
$busy = @{ id = '1'; status = 'active'; activity = 'running' }
$old = @{ github = $false; workers = @($busy, @{ id = '4'; status = 'active'; activity = 'setup' }) }
$new = @{ github = $false; workers = @($busy, @{ id = '4'; status = 'disabled'; activity = 'setup-failed' }) }
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Setup failed' 'the push of a failed setup'

Assert-Equal (Get-PlanName ('{"claudeAiOauth":{"subscriptionType":"pro","rateLimitTier":"default_claude_ai"}}' | ConvertFrom-Json)) 'Pro' 'plan pro'
Assert-Equal (Get-PlanName ('{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}' | ConvertFrom-Json)) 'Max 20x' 'plan max 20x'
$snapshot = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $settings
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } })
    logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } }; login = @{ account = 'temp'; state = 'waiting' } }
Assert-Equal $snapshot.workers[0].account 'temp' 'worker card names its account'
# Takes: each complexity with the model and effort of its runs; the effort after `@`, else xhigh for an unknown model.
$idle = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } })
$take = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = @{ model = 'some-model@low' }; workers = $idle }).workers[0].takes[0]
Assert-Equal "$($take.model) $($take.effort)" 'some-model low' 'a model override with its effort'
$take = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = @{ model = 'some-model' }; workers = $idle }).workers[0].takes[0]
Assert-Equal "$($take.model) $($take.effort)" 'some-model xhigh' 'a model not in the list runs at xhigh'
# A worker has no model of its own: its entry in the settings changes nothing.
$own = '{"workers":{"1":{"model":"claude-haiku-5-5@low"}}}' | ConvertFrom-Json
$take = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $own; workers = $idle }).workers[0].takes[0]
Assert-Equal "$($take.model) $($take.effort)" 'claude-opus-5-5 medium' 'a worker''s own model is no model'
# Details: the project's colour (a valid one only), the settings' `model`, the advisor's model with its default, and
# each complexity's advisor switch as the owner set it, apart from the advisor that its run gets.
$owner = '{"color":"#A0B1C2","model":"claude-sonnet-5-5@high","advisor":{"model":"claude-opus-5-5"},
    "complexities":{"design":{"advisor":true},"low":{"advisor":true,"advisorFallback":"max"}}}' | ConvertFrom-Json
$details = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = $owner
    complexities = Get-Complexities (Read-Models) $null $owner }
Assert-Equal "$($details.color) $($details.settingsModel) $($details.advisor.model) $($details.advisor.base)" '#a0b1c2 claude-sonnet-5-5@high claude-opus-5-5 claude-fable-5-2' 'the colour, the settings'' model and the advisor''s model'
$low = $details.complexities | Where-Object { $_.name -eq 'low' }
Assert-Equal "$($low.advisorOn) $($low.advisorFallback) $($low.baseAdvisor) '$($low.baseFallback)' '$($low.advisor)'" "True max False '' ''" 'on, and no advisor for a run on the advisor''s own model'
$design = $details.complexities | Where-Object { $_.name -eq 'design' }
Assert-Equal "$($design.advisorOn) $($design.baseAdvisor) $($design.advisor)" 'True False claude-opus-5-5' 'a complexity that the owner gave the advisor'
Assert-Equal (@($details.advisor.complexities) -join ',') 'low,medium,high,design' 'the switches of the owner in the rule'
foreach ($bad in 'red', '#abc', "#a0b1c2`nx", '') {
    $color = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = @{ color = $bad } }).color
    Assert-Equal "'$color'" "''" "no colour on the page: '$bad'"
}
$plain = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }
Assert-Equal "'$($plain.color)' '$($plain.settingsModel)' $($plain.advisor.model)" "'' '' claude-fable-5-2" 'no settings'
# The plugins and the complexities, for the Details tab: none for a plain git repo; models.json's four without a config.
$info = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @()
    plugins = @(@{ Name = 'unity'; Title = 'Scriptorium for Unity'; Version = '1.0.0'; Description = 'One editor each.'; Hooks = @{} }) }
Assert-Equal (($info.plugins | ForEach-Object { "$($_.name) $($_.title) $($_.version) $($_.description)" }) -join '|') 'unity Scriptorium for Unity 1.0.0 One editor each.' 'the plugins'
Assert-Equal @((New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).plugins).Count 0 'no plugin'
Assert-Equal (($info.complexities | ForEach-Object { "$($_.name)=$($_.effort)/$($_.advisor -ne '')" }) -join ' ') 'low=medium/False medium=high/True high=xhigh/True design=high/False' 'each complexity with its effort and advisor'
# The advisor rule from models.json, for the Details tab.
$advisor = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).advisor
Assert-Equal "$($advisor.model) $(@($advisor.complexities) -join ',')" 'claude-fable-5-2 medium,high' 'the advisor rule'
$temp = $snapshot.accounts | Where-Object { $_.name -eq 'temp' }
Assert-Equal "$($temp.own) $($temp.signedIn) $($temp.email) $($temp.plan) $($temp.status)" 'True True t@x Pro ready' 'account login'
Assert-Equal (($snapshot.accounts | Where-Object { $_.name -eq 'main' }).status) 'signedout' 'an account with no login is signed out'
Assert-Equal $snapshot.login.state 'waiting' 'sign-in passed through'
$future = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1000
foreach ($case in @(@('t@x', 0.5), @('old@x', $null))) {
    $usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = $case[0]; five_hour = [pscustomobject]@{ used = 0.5; resetsAt = $future } } }
    $temp = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $settings; workers = @(); usage = $usage
        logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts | Where-Object { $_.name -eq 'temp' }
    Assert-Equal $temp.five_hour.used $case[1] "reading of $($case[0]) on t@x's login"
}
# The stop line: the default and the account's own; under the week's, what each human use's share keeps for the time
# left (here half a week); at the ceiling, the account is at its limit.
$stops = '{"keep":{"personal":0.3},"accounts":{"temp":{"configDir":"C:/t","uses":["worker:1","frontdesk","personal"],"stopAt":{"five_hour":0.5,"seven_day":0.9},"pickUp":{"five_hour":{"L":0.4}}}}}' | ConvertFrom-Json
$usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = 't@x'; five_hour = [pscustomobject]@{ used = 0.5; resetsAt = $future }
    seven_day = [pscustomobject]@{ used = 0.2; resetsAt = $future - 1000 + 302400 } } }
$temp = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $stops; usage = $usage; workers = @()
    logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts[0]
$round = { param($share) [math]::Round($share, 2) }
Assert-Equal "$($temp.five_hour.stopAt) $($temp.five_hour.ceiling) $($temp.five_hour.kept) $($temp.status)" '0.5 0.5 0 limit' 'the 5-hour stop line keeps no room'
$week = $temp.seven_day
Assert-Equal "$($week.stopAt) $(& $round $week.left) $(& $round $week.kept) $(& $round $week.ceiling)" '0.9 0.5 0.2 0.7' 'the room kept under the week''s stop line'
Assert-Equal "$($temp.five_hour.pickUp.S) $($temp.five_hour.pickUp.L) $($week.ContainsKey('pickUp'))" '0.9 0.4 False' 'pick-up limits: the default and the account''s own, none for the week'
Assert-Equal (($week.guards | ForEach-Object { "$($_.use) $($_.share) $(& $round $_.kept)" }) -join ', ') 'frontdesk 0.1 0.05, personal 0.3 0.15' 'each guard: its share of a week and what it keeps now'
Assert-Equal $temp.ContainsKey($FableWindow) $false 'no Fable reading: no Fable week'
# The Fable week: its share, reset, read time, stop line and design line (each the default, else the account's own);
# nothing used once it has reset.
$own = '{"accounts":{"temp":{"configDir":"C:/t","uses":["worker:1"],"stopAt":{"seven_day_overage_included":0.9},"pickUp":{"seven_day_overage_included":{"design":0.7}}}}}' | ConvertFrom-Json
foreach ($case in @(@($future, $stops, '0.99 0.98 0.98 50 0.9'), @(5, $stops, '0 0.98 0.98 50 0.9'), @($future, $own, '0.99 0.9 0.9 50 0.7'))) {
    $usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = 't@x'
        $FableWindow = [pscustomobject]@{ used = 0.99; resetsAt = $case[0]; at = 50 } } }
    $fable = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $case[1]; usage = $usage; workers = @()
        logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts[0].$FableWindow
    Assert-Equal "$($fable.used) $($fable.stopAt) $($fable.ceiling) $($fable.at) $($fable.pickUp.design)" $case[2] "the Fable week, reset at $($case[0])"
}

# Held questions: the section of a PR body, up to the next heading.
$body = "Closes #1`n`n## Held questions`n`n1. **Merge now?** *(holds the PR)* Default: hold.`n`n## Verified`n`nRungs 1-3."
Assert-Equal (Get-HeldQuestions $body) '1. **Merge now?** *(holds the PR)* Default: hold.' 'held questions'
Assert-Equal (Get-HeldQuestions 'no section') '' 'no held questions'
$bold = "Closes #1`n`n**Decision:** May a user delete a shared file? Default: no.`n`n**Held questions:**`n1. *(holds the PR)* Delete now?`n`n**Verified:** rungs 1-3."
Assert-Equal (Get-HeldQuestions $bold) '1. *(holds the PR)* Delete now?' 'held questions as a bold label'
Assert-Equal (Get-HeldQuestions "**Held questions:** None`n**Verified:** 1") '' 'no held questions on the label line'
Assert-Equal (Get-HeldQuestions "**Held questions:** None: the rules are set.`n**Verified:** 1") '' 'no held questions with a note'
Assert-Equal (Get-Decision $bold) 'May a user delete a shared file? Default: no.' 'decision line'
Assert-Equal (Get-Decision $body) '' 'no decision line'

# Typical run: the median of whole-ticket runs of the size on the model; another model's when the model has none.
$runs = @(
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'opus'; duration = 3600; cost = 10 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'opus'; duration = 7200; cost = 30 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'opus'; duration = 5400; cost = 20 },
    @{ wall = $true; kind = 'ticket'; partial = $true; size = 'L'; model = 'opus'; duration = 100; cost = 1 },
    @{ wall = $true; kind = 'answered'; partial = $true; size = 'L'; model = 'opus'; duration = 100; cost = 1 },
    @{ kind = 'ticket'; partial = $false; size = 'L'; model = 'opus'; duration = 3; cost = 1 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'S'; model = 'sonnet'; duration = 600; cost = 2 }
) | ForEach-Object { [pscustomobject]$_ }
Assert-Equal (Get-Typical $runs 'L' 'opus') 5400 'typical L on opus'
Assert-Equal (Get-Typical $runs 'L' 'opus' 'cost') 20 'typical cost of an L on opus'
Assert-Equal (Get-Typical $runs 'S' 'opus') 600 'typical S falls back to any model'
Assert-Equal (Get-Typical $runs 'M' 'opus') '' 'no history'

# Queue: claimed tickets left out; each waiting one says why, in priority then age order; no priority is parked.
$free = @{ id = '1'; status = 'active'; activity = 'free' }
$issues = @(
    (Issue 1 @('P1', 'area:api', 'worker:2')),
    (Issue 2 @('P1', 'area:api') '' '2026-10-10T09:00:00Z'),
    (Issue 3 @('P0', 'area:ui') "Blocked by #4"),
    (Issue 4 @('P2', 'area:docs')),
    (Issue 5 @('area:db')),
    (Issue 6 @('P1', 'area:db', 'needs-owner'))
)
$rows = Get-QueueRows $issues @($free)
Assert-Equal (($rows.queued | ForEach-Object { $_.number }) -join ',') '3,2,4' 'queue order, without the ticket that waits on the owner'
Assert-Equal $rows.queued[0].reason 'blocked by #4' 'blocked'
Assert-Equal $rows.queued[1].reason 'api busy' 'area busy'
Assert-Equal $rows.queued[2].reason 'next up' 'next up'
Assert-Equal $rows.parked[0].number 5 'parked'
$rows = Get-QueueRows $issues @(@{ status = 'active'; activity = 'running' }, @{ status = 'paused'; activity = 'free' })
Assert-Equal $rows.queued[2].reason 'no free worker' 'no free worker'
$rows = Get-QueueRows $issues @($free) ([pscustomobject]@{ waiting = [pscustomobject]@{ '4' = 'too big' } })
Assert-Equal $rows.queued[2].reason 'too big' 'the dispatcher says it does not fit'
# A parked ticket names the open tickets that its drop frees: those whose Blocked by line names it.
$rows = Get-QueueRows @((Issue 5 @()), (Issue 7 @('P1') 'Blocked by #5, #9'), (Issue 8 @() 'Blocked by #5' '2026-10-11T10:00:00Z')) @($free)
Assert-Equal ($rows.parked[0].blocks -join ',') '7,8' 'the tickets that wait on a parked one'
Assert-Equal $rows.parked[1].blocks.Count 0 'none waits on it'
# A complexity the owner switched off for a worker: the worker does not get such a ticket as its next, and a ticket
# that no worker takes says so. No label is medium.
$off = '{"workers":{"1":{"complexity":{"medium":false}}}}' | ConvertFrom-Json
$hard = @((Issue 7 @('P1', 'area:ui') '' '2026-10-10T09:00:00Z'), (Issue 8 @('P1', 'area:docs', 'complexity:low') '' '2026-10-10T10:00:00Z'))
$rows = Get-QueueRows $hard @($free) $null $off
Assert-Equal "$($rows.queued[0].complexity): $($rows.queued[0].reason) | $($rows.queued[1].reason)" 'medium: no worker takes medium tickets | next up' 'a complexity that every worker has off'
$rows = Get-QueueRows $hard @($free, @{ id = '2'; status = 'active'; activity = 'running' }) $null $off
Assert-Equal $rows.queued[0].reason 'no free worker' 'the worker that takes it is busy'
Assert-Equal "$((Get-NextTickets $hard @() @($free) $null $off)['1'].number)" '8' 'the next ticket skips a complexity that is off'
$answered = [pscustomobject]@{ number = 70; headRefName = 't7'; title = 'x'; url = ''; labels = @(@{ name = 'worker:1' }, @{ name = 'answered' }) }
Assert-Equal "$((Get-NextTickets $hard @($answered) @($free) $null $off)['1'].kind)" 'ticket' 'the answers of a PR wait while its complexity is off'
Assert-Equal "$((Get-NextTickets $hard @($answered) @($free))['1'].kind)" 'answered' 'the answers of a PR come first while it is on'

# Areas clash when the same or one inside the other: the whole api holds each of its parts, the parts not each other.
Assert-Equal ((Get-Clashes @('area:api/auth', 'area:ui') @('area:api/search')) -join ',') '' 'two api parts'
Assert-Equal ((Get-Clashes @('area:api/auth') @('area:api')) -join ',') 'area:api/auth' 'a part under the whole api'
Assert-Equal ((Get-Clashes @('area:api', 'area:ui') @('area:api/cache')) -join ',') 'area:api' 'the whole api over a part'
Assert-Equal ((Get-Clashes @('area:apis') @('area:api')) -join ',') '' 'a longer name is not a part'
$rows = Get-QueueRows @((Issue 1 @('P1', 'area:api/search', 'worker:1')), (Issue 2 @('P1', 'area:api/auth')),
    (Issue 3 @('P1', 'area:api') '' '2026-10-10T11:00:00Z')) @($free)
Assert-Equal (($rows.queued | ForEach-Object { $_.reason }) -join '|') 'next up|api busy' 'api parts in the queue'

# The next ticket: one per worker, a free worker first; the first whose area is free; else the first, not available.
function Next($next, [string] $id) {
    return "$($next[$id].number) $($next[$id].available) $($next[$id].why)".Trim()
}
$working = @{ id = '4'; status = 'active'; activity = 'running'; ticket = 99 }
$idle = @{ id = '5'; status = 'active'; activity = 'free' }
$next = Get-NextTickets $issues @() @($working, $idle)
Assert-Equal (Next $next '5') '4 True' 'the free worker gets the first ticket whose area is free'
Assert-Equal (Next $next '4') '2 False api is busy' 'the working one gets the next in the queue: its area is held by another worker'
$next = Get-NextTickets $issues @() @(@{ id = '4'; status = 'active'; activity = 'running'; ticket = 99 }, @{ id = '5'; status = 'paused'; activity = 'free' }, @{ id = '6'; status = 'disabled'; activity = 'free' })
Assert-Equal (Next $next '5') '4 False the worker is paused' 'a paused worker takes none'
Assert-Equal "$($next.ContainsKey('6'))" 'False' 'a disabled worker has no next ticket'
$next = Get-NextTickets $issues @() @(@{ id = '4'; status = 'active'; activity = 'room' })
Assert-Equal (Next $next '4') '4 False its account is at its stop line' 'no room under the stop line'
# The next ticket follows the pick-up limits of the worker's account (S 90 %, M 75 %, L 50 % of 5 hours here): the
# biggest ticket of the priority that the account takes now; over every limit, the first one, locked, with the reason.
$sized = @((Issue 11 @('P1', 'size:S')), (Issue 12 @('P1')), (Issue 13 @('P1', 'size:L')))
$onAccount = @{ id = '1'; status = 'active'; activity = 'free'; account = 'a' }
function NextAt([double] $used) {
    $account = @{ name = 'a'; five_hour = @{ used = $used; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; seven_day = @{ used = 0.1; ceiling = 0.9 } }
    return Next (Get-NextTickets $sized @() @($onAccount) $null $null @($account)) '1'
}
Assert-Equal (NextAt 0.2) '13 True' 'room for every size: the biggest ticket first'
Assert-Equal (NextAt 0.6) '12 True' 'over the L limit: an M (no size label counts as M)'
Assert-Equal (NextAt 0.8) '11 True' 'over the M limit: an S'
Assert-Equal (NextAt 0.92) '13 False over the pick-up limit for size L' 'over every limit: the first, locked'
Assert-Equal (Next (Get-NextTickets $sized @() @($onAccount)) '1') '13 True' 'no account known: every size'
# A ticket shown locked for the pick-up limit is not given: a worker on an account with room still gets it.
$full = @{ name = 'a'; five_hour = @{ used = 0.92; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; seven_day = @{ used = 0.1; ceiling = 0.9 } }
$room = @{ name = 'b'; five_hour = @{ used = 0.1; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; seven_day = @{ used = 0.1; ceiling = 0.9 } }
$two = Get-NextTickets $sized @() @($onAccount, @{ id = '2'; status = 'active'; activity = 'free'; account = 'b' }) $null $null @($full, $room)
Assert-Equal "$(Next $two '1') | $(Next $two '2')" '13 False over the pick-up limit for size L | 13 True' 'a locked ticket still goes to the worker with room'
Assert-Equal ((Get-QueueRows (@($sized) + @((Issue 14 @('P0', 'size:S')))) @($free)).queued.number -join ',') '14,13,12,11' 'queue order: priority, then the bigger ticket'
# Force takes the ticket shown, also one whose area is busy; a ticket that left the queue falls back to the first free.
$queue = @((Issue 2 @('P1', 'area:api')), (Issue 4 @('P2', 'area:docs')), (Issue 6 @('P2', 'area:api/auth')))
Assert-Equal (Select-Forced $queue 6 @('area:api')).number 6 'force takes the ticket the page showed'
Assert-Equal (Select-Forced $queue 99 @('area:api')).number 4 'else the first whose area is free'
Assert-Equal (Select-Forced $queue 0 @('area:api', 'area:docs')).number 2 'else the first'
# Now: a force file with `now` names the one ticket its worker takes, and only while that ticket is in the queue.
$file = Join-Path $env:TEMP "scriptorium-now-$PID.json"
Set-Content $file '{"ticket":6,"now":true}' -Encoding utf8
Assert-Equal (Read-Now $file) 6 'the ticket of a Now'
Set-Content $file '{"ticket":6}' -Encoding utf8
Assert-Equal (Read-Now $file) 0 'a plain force is no Now'
Remove-Item $file
Assert-Equal (Read-Now $file) 0 'no force file'
$open = @((Issue 2 @('P1')), (Issue 3 @('P1', 'worker:2')), (Issue 4 @('P1', 'worker:1')), (Issue 5 @('P1') 'Blocked by #2'), (Issue 6 @()),
    (Issue 7 @('P1', 'needs-owner')))
Assert-Equal (Select-Now $open 2 'worker:1' @()).number 2 'Now takes a queued ticket'
Assert-Equal (Select-Now $open 4 'worker:1' @()).number 4 'and one the worker claimed already (a start that its plan refused)'
Assert-Equal (Select-Now $open 5 'worker:1' @()).number 5 'and a blocked one: the owner accepts a merge conflict'
foreach ($gone in 3, 6, 7, 9) {
    Assert-Equal "$(Select-Now $open $gone 'worker:1' @())" '' "Now takes no ticket $gone`: another worker's, parked, waiting on the owner or closed"
}
Assert-Equal "$(Select-Now $open 2 'worker:1' @('t2'))" '' 'nor a ticket with a PR'
# The worker for a Now: a free one before one in a run; of those in a run the account with the most room, then the run
# that started last; before all, the worker whose ticket in work holds an area of this one.
function Working([string] $id, [int] $ticket, [string] $account, [long] $started) {
    return @{ id = $id; status = 'active'; activity = 'running'; ticket = $ticket; title = "Ticket $ticket"; account = $account; startedAt = $started }
}
function Account([string] $name, [double] $used) {
    return @{ name = $name; five_hour = @{ used = $used; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; seven_day = @{ used = 0.1; ceiling = 0.9 } }
}
function Now($pick) {
    return $(if ($pick.worker) { "$($pick.worker) stops $($pick.stops) busy '$($pick.busy -join ',')'" } else { $pick.why })
}
$urgent = Issue 20 @('P1', 'area:api')
$flight = @($urgent, (Issue 21 @('P1', 'area:ui', 'worker:1')), (Issue 22 @('P1', 'area:api/auth', 'worker:2')), (Issue 23 @('P1', 'area:db', 'worker:3')))
$accounts = @((Account 'a' 0.2), (Account 'b' 0.6))
$idle = @{ id = '4'; status = 'active'; activity = 'free'; account = 'b' }
Assert-Equal (Now (Select-NowWorker $urgent $flight @((Working '1' 21 'a' 100), (Working '3' 23 'a' 200), $idle) $null $accounts)) "4 stops 0 busy 'api'" 'a free worker first; another ticket in flight still holds the area'
Assert-Equal (Now (Select-NowWorker $urgent $flight @((Working '1' 21 'a' 100), (Working '3' 23 'a' 200)) $null $accounts)) "3 stops 23 busy 'api'" 'one account: the run that started last'
Assert-Equal (Now (Select-NowWorker $urgent $flight @((Working '1' 21 'b' 100), (Working '3' 23 'a' 50)) $null $accounts)) "3 stops 23 busy 'api'" 'the account with the most room'
Assert-Equal (Now (Select-NowWorker $urgent $flight @((Working '2' 22 'b' 50), (Working '3' 23 'a' 200), $idle) $null $accounts)) "2 stops 22 busy ''" 'before all, the worker whose ticket holds the area: its end frees it'
$answers = Working '2' 22 'b' 50
$answers.kind = 'answered'
Assert-Equal (Now (Select-NowWorker $urgent $flight @($answers, (Working '3' 23 'a' 200)) $null $accounts)) "3 stops 23 busy 'api'" 'a PR''s job keeps its ticket and its area'
Assert-Equal (Now (Select-NowWorker $urgent $flight @((Working '1' 21 'b' 100)) $null @((Account 'b' 0.8)))) 'no account has room for a size M ticket now' 'no room for the size'
$not = @(@{ id = '1'; status = 'paused'; activity = 'free' }, @{ id = '2'; status = 'active'; activity = 'held' }, @{ id = '3'; status = 'active'; activity = 'running'; forced = $true },
    @{ id = '5'; status = 'active'; activity = 'running'; pending = @{ to = 'paused' } }, @{ id = '6'; status = 'active'; activity = 'free' })
$off = '{"workers":{"6":{"complexity":{"medium":false}}}}' | ConvertFrom-Json
Assert-Equal (Now (Select-NowWorker $urgent $flight $not $off)) 'no worker can take it: each is paused, held, forced or has its complexity off' 'no worker that looks for a job on its own'
# A ticket that runs on Fable gets no Now on an account at the design line of its Fable week.
$design = Issue 24 @('P1', 'complexity:design')
$onFable = @{ id = '7'; status = 'active'; activity = 'free'; account = 'f'; takes = @(@{ name = 'design'; model = 'claude-fable-5-2' }, @{ name = 'medium'; model = 'claude-opus-5-5' }) }
$week = Account 'f' 0.1
$week[$FableWindow] = @{ used = 0.92; stopAt = 0.98; pickUp = @{ design = 0.9 } }
Assert-Equal (Now (Select-NowWorker $design @($design) @($onFable) $null @($week))) 'no account has Fable left for a design ticket' 'the Fable week at its design line'
Assert-Equal (Now (Select-NowWorker (Issue 25 @('P1')) @() @($onFable) $null @($week))) "7 stops 0 busy ''" 'a ticket on another model still gets its Now there'
$week[$FableWindow].used = 0.5
Assert-Equal (Now (Select-NowWorker $design @($design) @($onFable) $null @($week))) "7 stops 0 busy ''" 'Fable left: the Now goes on'
# The queue and the cards with a Now: the ticket is its worker's next, no other worker's, and has no Now button.
$taking = Working '3' 23 'a' 200
$taking.forced = $true
$taking.now = 20
$rows = Get-QueueRows $flight @($taking, $idle) $null $null $accounts
Assert-Equal "$($rows.queued[0].taken) $($rows.queued[0].reason) $([bool]$rows.queued[0].now)" '3 worker 3 does it now False' 'a ticket that a Now names waits for its worker'
$rows = Get-QueueRows $flight @((Working '3' 23 'a' 200), $idle) $null $null $accounts
Assert-Equal "$($rows.queued[0].now.worker) $([bool]$rows.queued[0].taken)" '4 False' 'a queued ticket names the worker of its Now'
$blocked = (Get-QueueRows @((Issue 30 @('P1') 'Blocked by #31'), (Issue 31 @('P1', 'worker:1'))) @($idle)).queued[0]
Assert-Equal "$($blocked.reason) $($blocked.now.worker)" 'blocked by #31 4' 'a blocked ticket waits, and its Now names a worker'
$next = Get-NextTickets $flight @() @($taking, $idle)
Assert-Equal "$($next['3'].number) $($next['3'].kind) $($next['4'].number)" '20 now ' 'the Now is its worker''s next, and no other worker''s'
# Its own work comes first: a PR to answer, then its claimed ticket without a PR. A ticket it works on now is not next.
$own = @((Issue 7 @('P1', 'worker:1')), (Issue 8 @('P1', 'worker:1')), (Issue 9 @('P0')))
$prs = @((Pr 70 7 @('worker:1', 'answered')))
Assert-Equal (Get-NextTickets $own $prs @(@{ id = '1'; status = 'active'; activity = 'free' }))['1'].kind 'answered' 'its PR to answer first'
Assert-Equal (Next (Get-NextTickets $own @() @(@{ id = '1'; status = 'active'; activity = 'running'; ticket = 7 })) '1') '8 True' 'then its own ticket, not the one in work'
# Its own ticket's area does not hold the next one: the slot is taken as free.
$same = @((Issue 1 @('P1', 'area:api', 'worker:1')), (Issue 2 @('P1', 'area:api')))
$prs = @((Pr 10 1 @('worker:1')))
Assert-Equal (Next (Get-NextTickets $same $prs @(@{ id = '1'; status = 'active'; activity = 'running'; ticket = 1 })) '1') '2 True' 'the area of its own ticket counts as free'

# A queued ticket and a worker's ticket show their areas; the queue's sums come from typical runs by size.
$busyWorker = @{ id = '1'; state = [pscustomobject]@{ state = 'running'; at = 0; ticket = 1; size = 'L'; model = 'opus'; startedAt = 0 } }
$snapshot = New-Snapshot @{ now = 0; slug = 'o/r'; workers = @($busyWorker); runs = $runs; gh = @{ issues = @((Issue 1 @('area:ui', 'area:api/search', 'worker:1', 'size:S')), (Issue 2 @('P1', 'area:api/auth', 'size:L')), (Issue 3 @('P1', 'size:S') '' '2026-10-11T10:00:00Z')); prs = @(); merged = @() } }
Assert-Equal "$($snapshot.workers[0].areas -join ',')|$($snapshot.queued[0].areas -join ',')" 'api/search,ui|api/auth' 'areas of a worker and a queued ticket'
Assert-Equal "$($snapshot.workers[0].typical) $($snapshot.workers[0].typicalCost) $($snapshot.workers[0].next.number)" '5400 20 2' 'the run against a typical one, and its next ticket'
# A worker's ticket shows its size label; its next ticket its complexity, medium with no label.
Assert-Equal "$($snapshot.workers[0].size) $($snapshot.workers[0].next.complexity)" 'S medium' 'size of the ticket in work, complexity of the next'
Assert-Equal "$($snapshot.left.count) $($snapshot.left.seconds) $($snapshot.left.cost)" '2 6000 22' 'what is left: tickets, time, cost'
$json = New-Snapshot @{ now = 0; slug = 'o/r'; workers = @(); runs = @(); gh = @{ issues = @((Issue 2 @('P1'))); prs = @(); merged = @() } } | ConvertTo-Json -Depth 5 -Compress
Assert-Equal ($json -match '"areas":\[\]') $true 'no area is an empty list'

# A paused worker keeps its ticket in its slot; a run that waits for its limit shows the time worked so far.
$pausedWorker = @{ id = '1'; state = [pscustomobject]@{ state = 'stopped'; at = 0 } }
$control = Json @{ workers = @{ '1' = 'stop' } }
$view = (New-Snapshot @{ now = 0; slug = 'o/r'; workers = @($pausedWorker); runs = @(); control = $control; gh = @{ issues = @((Issue 5 @('P1', 'worker:1'))); prs = @(); merged = @() } }).workers[0]
Assert-Equal "$($view.status) $($view.ticket)" 'paused 5' 'a paused worker keeps its ticket'
$limited = @{ id = '1'; state = [pscustomobject]@{ state = 'paused'; at = 0; ticket = 5; resetsAt = 600; elapsed = 1200; kind = 'ticket'; size = 'L'; model = 'opus' } }
$view = (New-Snapshot @{ now = 10; slug = 'o/r'; workers = @($limited); runs = $runs }).workers[0]
Assert-Equal "$($view.status) $($view.activity) $($view.elapsed) $($view.typical)" 'active limit 1200 5400' 'at its usage limit: active, with its progress'
Assert-Equal (New-Snapshot @{ now = 700; awake = 700; slug = 'o/r'; workers = @($limited); runs = $runs }).workers[0].activity 'resuming' 'after the reset the run resumes: no reset time in the past'
# A run held for the owner's pause (worker.ps1, Suspend-Job): the worker is paused and keeps its run and progress.
$heldRun = @{ id = '1'; state = [pscustomobject]@{ state = 'stopped'; at = 0; ticket = 5; resetsAt = 5; stopped = $true; elapsed = 1200; kind = 'ticket'; size = 'L'; model = 'opus' } }
$view = (New-Snapshot @{ now = 10; slug = 'o/r'; workers = @($heldRun); runs = $runs; control = $control }).workers[0]
Assert-Equal "$($view.status) $($view.activity) $($view.run) $($view.elapsed)" 'paused held True 1200' 'held for a pause: paused, with its run'

# What waits on the owner: one list of questions (blocking or not); a stuck run and a hold are not questions.
$gh = @{
    issues = @(
        (Issue 8 @('follow-up', 'size:M') "**Summary:** Exports finish faster.`n**Questions:**`n1. Do this? Default: yes."),
        (Issue 9 @('open-question') "**Summary:** Search runs on each key.`n**Questions:**`n1. Wait for a pause? Default: yes."),
        (Issue 10 @('needs-owner', 'worker:1')), (Issue 11 @('needs-owner', 'worker:2')), (Issue 12 @('needs-owner', 'P2'))
    )
    prs = @((Pr 20 3 @('needs-owner', 'worker:1') $bold), (Pr 21 4 @('needs-owner', 'answered', 'worker:1')))
    merged = @()
    questions = [pscustomobject]@{ '10' = '**Worker 1:** Can a guest see the list? Options: yes, no.'; '11' = '**Worker 2:** stopped without a PR or a question. Log: `C:\none.jsonl`' }
}
$waiting = Get-Waiting $gh 'o/r'
Assert-Equal (($waiting.questions | ForEach-Object { "$($_.kind):$($_.number):$($_.blocking)" }) -join ' ') 'pr:20:True ticket:10:True followup:8:False question:9:False' 'the questions'
Assert-Equal "$($waiting.questions[0].question)|$($waiting.questions[0].details)" 'May a user delete a shared file? Default: no.|1. *(holds the PR)* Delete now?' 'a held PR asks its Decision line'
Assert-Equal $waiting.questions[1].question 'Can a guest see the list? Options: yes, no.' 'a ticket asks its worker''s last question'
Assert-Equal "$($waiting.questions[2].question)" "Exports finish faster.`n`n1. Do this? Default: yes." 'a follow-up asks its summary and questions'
Assert-Equal (($waiting.stuck | ForEach-Object { "$($_.kind):$($_.number)" }) -join ' ') 'pr:21 ticket:11' 'stuck: a PR its run could not finish, a run with no result'
Assert-Equal ($waiting.stuck[1].reason -match 'log is not on this PC') $true 'a stuck run without its log says so'
Assert-Equal (($waiting.held | ForEach-Object { $_.number }) -join ' ') '12' 'a ticket that waits with no question is on hold'
$rows = Get-QueueRows $gh.issues @($free)
Assert-Equal ($rows.queued.Count + $rows.parked.Count) 0 'questions, stuck and held tickets are not in the queue'

# The stuck reason comes from the run's log: its error, else its last words, else its last step.
$log = Join-Path $env:TEMP "queue-app-test-$PID.jsonl"
# Written without a byte order mark, as a run writes its log.
[System.IO.File]::WriteAllLines($log, [string[]]@('{"type":"assistant","message":{"content":[{"type":"text","text":"I stop here."}]}}', '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached the turn limit."}'))
Assert-Equal (Get-StuckReason $log) 'The run failed (error_max_turns): Reached the turn limit.' 'a failed run'
[System.IO.File]::WriteAllLines($log, [string[]]@('{"type":"result","subtype":"success","is_error":false,"result":"I stop #7 here."}'))
Assert-Equal (Get-StuckReason $log) 'The run ended by itself. Its last words: I stop #7 here.' 'a run that ended by itself'
[System.IO.File]::WriteAllLines($log, [string[]]@('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Run the suite"}}]}}'))
Assert-Equal (Get-StuckReason $log) 'The run''s process ended with no result (a crash or a kill). Its last step: Bash: Run the suite' 'a run that died'
Remove-Item $log
Assert-Equal (Get-StuckReason 'C:\none.jsonl') '' 'no log, no reason'

# The owner's word on a question, by script: an answer or the default.
function Route([string] $kind, [string] $text, [string] $asks = '') {
    return Get-AnswerRoute @{ kind = $kind; asks = $asks } $text
}
Assert-Equal "$(Route 'pr' 'Yes.') $(Route 'pr' '')" 'answered merge' 'a held PR'
Assert-Equal "$(Route 'ticket' 'Yes.') $(Route 'ticket' '')" 'back back' 'a ticket''s question'
Assert-Equal "$(Route 'question' 'Three.') $(Route 'question' ' ')" 'change keep' 'an open question'
Assert-Equal "$(Route 'followup' 'Yes, with oak.') $(Route 'followup' 'No.') $(Route 'followup' 'no, but make the wall 6 high')" 'queue drop queue' 'a follow-up: only a bare no drops it'
Assert-Equal "$(Route 'followup' '' '1. Do this? Default: yes.') $(Route 'followup' '' '1. Do this? **Default:** no. Size M.') $(Route 'followup' '')" 'queue drop queue' 'a follow-up''s default'

# Steps: a tool call names the tool and what it does; words are shown as said.
Assert-Equal (Get-StepText '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push","description":"Push the branch"}}]}}') 'Bash: Push the branch' 'tool step'
Assert-Equal (Get-StepText '{"type":"assistant","message":{"content":[{"type":"text","text":"Rungs  pass."}]}}') 'Rungs pass.' 'text step'
Assert-Equal (Get-StepText '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__UnityMCP__manage_scene","input":{"action":"save"}}]}}') 'UnityMCP manage_scene: save' 'an MCP tool step'
Assert-Equal (Get-StepText '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__my_db__run_query","input":{}}]}}') 'my_db run_query' 'a server name with an underscore'
Assert-Equal (Get-StepText '{"type":"user"}') '' 'not a step'
Assert-Equal (Get-StepText '{"type":"result","stop_reason":"end_turn"}') '' 'a turn end is not a step'

# A stale worker is down; not just after the PC wakes.
$idleState = @{ id = '2'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }
Assert-Equal (New-Snapshot @{ now = 10; slug = 'o/r'; workers = @($idleState); runs = @() }).workers[0].activity 'free' 'free'
Assert-Equal (New-Snapshot @{ now = 10000; slug = 'o/r'; workers = @($idleState); runs = @() }).workers[0].activity 'down' 'down when its script is silent'
Assert-Equal (New-Snapshot @{ now = 10000; awake = 9500; slug = 'o/r'; workers = @($idleState); runs = @() }).workers[0].activity 'free' 'not down just after the PC wakes'
$orphan = @{ id = '2'; state = [pscustomobject]@{ state = 'running'; at = 0; ticket = 368 } }
Assert-Equal (New-Snapshot @{ now = 10000; slug = 'o/r'; workers = @($orphan); runs = @() }).workers[0].activity 'down' 'down when the script is gone, though its run works'

# Notifications: none on the first snapshot; a new blocking question; no worker active means safe to switch off.
$old = @{ github = $true; questions = @(); stuck = @(); merged = @(); queued = @(@{ number = 9 })
    workers = @(@{ id = '1'; status = 'active'; activity = 'running' }, @{ id = '2'; status = 'paused'; activity = 'free' }) }
Assert-Equal @(Get-Events $null $old).Count 0 'first snapshot'
$new = @{ github = $true; questions = @(@{ key = 'r#7'; blocking = $true; worker = '1' }, @{ key = 'r#8'; blocking = $false }); stuck = @(); merged = @()
    queued = @(@{ number = 9 }); workers = @(@{ id = '1'; status = 'paused'; activity = 'free' }, @{ id = '2'; status = 'paused'; activity = 'free' }) }
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Question,Safe to switch off' 'events: only the blocking question pushes'
Assert-Equal @(Get-Events $new $new).Count 0 'no change, no events'
$new.stuck = @(@{ key = 'r#9' })
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Question,Stuck,Safe to switch off' 'a stuck run pushes'
# A disabled worker counts as not active, and doesn't keep the queue from being empty.
$old = @{ github = $true; questions = @(); stuck = @(); merged = @(); queued = @(@{ number = 9 })
    workers = @(@{ id = '1'; status = 'active'; activity = 'running' }, @{ id = '3'; status = 'disabled'; activity = 'free' }) }
$new = @{ github = $true; questions = @(); stuck = @(); merged = @(); queued = @()
    workers = @(@{ id = '1'; status = 'active'; activity = 'free' }, @{ id = '3'; status = 'disabled'; activity = 'free' }) }
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Queue empty' 'queue empty beside a disabled worker'
# The page's start: the first snapshot has no reading of GitHub yet, and the queue was empty before it.
$start = @{ github = $false; questions = @(); stuck = @(); merged = @(); queued = @(); workers = $new.workers }
Assert-Equal @(Get-Events $start $new).Count 0 'no queue-empty push at the page''s start'
# A worker at its usage limit stays active: its own push, and no "safe to switch off".
$new = @{ github = $true; questions = @(); stuck = @(); merged = @(); queued = @(@{ number = 9 })
    workers = @(@{ id = '1'; status = 'active'; activity = 'limit'; resetsAt = 600 }, @{ id = '3'; status = 'disabled'; activity = 'free' }) }
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Usage limit' 'usage limit event'
$new.workers[0].activity = 'signedout'
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Signed out' 'signed-out event'
# A run held for the owner's pause that resumes pushes nothing: the owner set the worker active.
$new.workers[0].activity = 'held'
$after = @{ github = $true; questions = @(); stuck = @(); merged = @(); queued = @(@{ number = 9 })
    workers = @(@{ id = '1'; status = 'active'; activity = 'running' }, @{ id = '3'; status = 'disabled'; activity = 'free' }) }
Assert-Equal @(Get-Events $new $after).Count 0 'no push for a resume after a pause'

# An account that is out (worker.ps1, Get-Out; `.queue/out.json`): the fact is the account's. Its card and the card
# of each worker that waits for it name the cause; a worker on another account is not touched.
$register = '{"accounts":{"main":{"uses":["worker:1","worker:3"]},"third":{"configDir":"C:/third","uses":["worker:2"]}}}' | ConvertFrom-Json
$logins = @{ 'default' = @{ signedIn = $true; email = 'm@x' }; 'C:/third' = @{ signedIn = $true; email = 't@x' } }
$out = '{"C:/third":{"kind":"subscription","text":"A payment is past due.","at":1000,"login":"1 t@x"}}' | ConvertFrom-Json
$snapshot = New-Snapshot @{ now = 1010; slug = 'o/r'; runs = @(); settings = $register; logins = $logins; out = $out
    workers = @(
        @{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 1005 } },
        # No run: its account is out.
        @{ id = '2'; state = [pscustomobject]@{ state = 'signedout'; at = 1005; account = 'C:/third' } },
        # Moved to main while its run is held for the account it began on.
        @{ id = '3'; state = [pscustomobject]@{ state = 'paused'; at = 1005; account = 'C:/third'; ticket = 7; resetsAt = 1000; loggedOut = $true } }
    ) }
$one, $two, $three = $snapshot.workers
Assert-Equal "$($one.activity) $([bool]$one.out)" 'free False' 'a worker on another account is free'
Assert-Equal "$($two.activity) $($two.out.kind) $($two.out.retryAt) $([bool]$two.run)" 'signedout subscription 1600 False' 'a worker with no run waits for its account'
Assert-Equal "$($three.activity) $($three.out.kind) $($three.heldOn) $($three.account)" 'signedout subscription third main' 'a held run names the account it waits for'
Assert-Equal (($snapshot.accounts | ForEach-Object { "$($_.name)=$($_.status)" }) -join ' ') 'main=ready third=refused' 'only the account that is out shows it'
Assert-Equal ($snapshot.accounts | Where-Object { $_.name -eq 'third' }).out.text 'A payment is past due.' 'the card gives the text of the refusal'
Assert-Equal (Get-NextTickets @(Issue 9 @('P1')) @() @($two))['2'].why 'its account takes no runs' 'the next ticket of a worker whose account is out'
# A free worker on an account that is out waits for it at once, before its script's next look.
$snapshot = New-Snapshot @{ now = 1010; slug = 'o/r'; runs = @(); settings = $register; logins = $logins; out = $out
    workers = @(@{ id = '2'; state = [pscustomobject]@{ state = 'idle'; at = 1005 } }) }
Assert-Equal "$($snapshot.workers[0].activity) $($snapshot.workers[0].out.kind)" 'signedout subscription' 'a free worker on an account that is out'
# A worker's own record: its runs do not start although its account answers. The account's card stays as it is.
$own = '{"worker:1":{"kind":"start","text":"No such model.","at":1000,"login":"5"}}' | ConvertFrom-Json
$snapshot = New-Snapshot @{ now = 1010; slug = 'o/r'; runs = @(); settings = $register; logins = $logins; out = $own
    workers = @(
        @{ id = '1'; state = [pscustomobject]@{ state = 'signedout'; at = 1005; account = 'default' } },
        @{ id = '3'; state = [pscustomobject]@{ state = 'idle'; at = 1005 } }
    ) }
$one, $three = $snapshot.workers
Assert-Equal "$($one.activity) $($one.out.kind) $($one.out.own) $($one.out.retryAt) $($one.out.text)" 'signedout start True 4600 No such model.' 'a worker whose runs do not start'
Assert-Equal "$($three.activity) $(($snapshot.accounts | Where-Object { $_.name -eq 'main' }).status)" 'free ready' 'its account and the other worker on it go on'
# A refused login reads as signed out, also while the folder still holds a login.
$out = '{"C:/third":{"kind":"login","text":"Not logged in","at":1000}}' | ConvertFrom-Json
$snapshot = New-Snapshot @{ now = 1010; slug = 'o/r'; runs = @(); settings = $register; logins = $logins; out = $out; workers = @() }
Assert-Equal ($snapshot.accounts | Where-Object { $_.name -eq 'third' }).status 'signedout' 'a refused login is signed out'
# A free worker on a folder with no login waits for the sign-in before its script finds out.
$logins['C:/third'] = @{ signedIn = $false }
$snapshot = New-Snapshot @{ now = 1010; slug = 'o/r'; runs = @(); settings = $register; logins = $logins
    workers = @(@{ id = '2'; state = [pscustomobject]@{ state = 'idle'; at = 1005 } }) }
Assert-Equal "$($snapshot.workers[0].activity) $($snapshot.workers[0].out.kind)" 'signedout login' 'a free worker on a folder with no login'
# The push names the cause.
$old = @{ github = $false; workers = @(@{ id = '2'; status = 'active'; activity = 'running' }) }
$new = @{ github = $false; workers = @(@{ id = '2'; status = 'active'; activity = 'signedout'; out = @{ kind = 'subscription' } }) }
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Subscription refused' 'the push of a refused subscription'
$new.workers[0].out.kind = 'start'
Assert-Equal (@(Get-Events $old $new | ForEach-Object { $_.title }) -join ',') 'Runs do not start' 'the push of runs that do not start'
# The same activity again pushes nothing: the workers test the account with a probe, so the card does not flicker.
Assert-Equal @(Get-Events $new $new).Count 0 'no second push while the account stays out'
# A refused request has the subtype 'success': the reason leaves it out.
$log = Join-Path $env:TEMP "queue-app-test-$PID.jsonl"
[System.IO.File]::WriteAllLines($log, [string[]]@('{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}'))
Assert-Equal (Get-StuckReason $log) 'The run failed: Not logged in' 'a refused request'
Remove-Item $log

Write-Output 'ok'
