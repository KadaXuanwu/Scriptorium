# Checks state.ps1, the queue app's snapshot and notifications: powershell -NoProfile -File app\app.test.ps1
# (prints ok or throws).
$ErrorActionPreference = 'Stop'
# The PC's files of a test are in a folder of its own (pc.ps1): set before anything loads.
$PcDir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-test-$PID"
. (Join-Path $PSScriptRoot 'state.ps1')
$baseDir = Split-Path $PSScriptRoot
# The models, the windows and the logs are the test provider's (tests/provider).
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/provider') 'test' $null)
$deep = 'deep'

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
$settings = '{"accounts":{"main":{"provider":"test","uses":["worker:1","frontdesk"]},"temp":{"provider":"test","configDir":"C:/t","uses":["worker:3"]}}}' | ConvertFrom-Json
$settings = (Set-WorkerAccount $settings '1' 'temp' | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal ($settings.accounts.main.uses -join ',') 'frontdesk' 'worker 1 left main'
Assert-Equal ($settings.accounts.temp.uses -join ',') 'worker:3,worker:1' 'worker 1 on temp'
$settings = (Set-WorkerAccount $settings '3' '' | ConvertTo-Json -Depth 8) | ConvertFrom-Json
Assert-Equal (@($settings.accounts.temp.uses).Count) 1 'worker 3 on the command-line login'
Assert-Equal ($settings | ConvertTo-Json -Depth 8 -Compress) '{"accounts":{"main":{"provider":"test","uses":["frontdesk"]},"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1"]}}}' 'lists stay lists'
$threw = $false
try { Set-WorkerAccount $settings '1' 'nope' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'unknown account'

# An account is one provider's, and a worker runs on its account's coding tool, in any project (docs/QUEUE.md,
# Accounts). So one page serves the accounts and the workers of every tool it has a provider for: here the test
# provider, the project's default, and the bare one. An account that names no provider is the default's. One of a
# tool with no plugin here is not served.
$testProvider = $script:Provider
$bareProvider = Import-Plugin (Join-Path $baseDir 'tests/bare') 'bare' $null
Set-Providers @($testProvider, $bareProvider)
$two = '{"accounts":{"main":{"provider":"bare","uses":["worker:1","personal"]},"mine":{"provider":"test","configDir":"C:/m","uses":["worker:2"]},"old":{"configDir":"C:/o","uses":[]},"far":{"provider":"other","configDir":"C:/f","uses":[]}}}'
function Fails([scriptblock] $block) {
    try { & $block | Out-Null } catch { return [string]$_ }
    return ''
}
$register = $two | ConvertFrom-Json
Assert-Equal "$(Test-KnownAccount $register.accounts.main) $(Test-KnownAccount $register.accounts.mine) $(Test-KnownAccount $register.accounts.old) $(Test-KnownAccount $register.accounts.far)" 'True True True False' 'the page serves the accounts of every tool it has a provider for'
Assert-Equal (Fails { Set-WorkerAccount ($two | ConvertFrom-Json) '2' 'far' }) 'account far is of a coding tool with no plugin here (other): add its plugin to scriptorium.json and run setup' 'no worker on an account of a tool with no plugin here'
Assert-Equal (Fails { Get-KnownAccount ($two | ConvertFrom-Json) 'nope' }) 'no account nope' 'an account the register does not have'
# A worker that goes to another tool's account runs on that tool: not while it has a run in flight.
$moved = Set-WorkerAccount ($two | ConvertFrom-Json) '2' 'main'
Assert-Equal "$((Get-WorkerProvider $register '2' (Get-KnownProviders)).Name) $((Get-WorkerProvider $moved '2' (Get-KnownProviders)).Name)" 'test bare' 'a worker on another tool''s account runs on that tool'
Assert-Equal (Get-ToolRefusal $testProvider $bareProvider $true) "it has a run in flight on The test provider: it can go to another coding tool's account when that run is done" 'not to another tool with a run in flight'
Assert-Equal "'$(Get-ToolRefusal $testProvider $bareProvider $false)' '$(Get-ToolRefusal $testProvider $testProvider $true)' '$(Get-ToolRefusal $null $bareProvider $false)'" "'' '' ''" 'with no run, and to an account of the same tool, it goes'
# A worker that goes away leaves its account; a new one on the command-line login runs on that login's tool.
$gone = Set-WorkerEntry ($two | ConvertFrom-Json) '2' $false
Assert-Equal "$(@($gone.accounts.mine.uses).Count) $($gone.accounts.main.uses -join ',')" '0 worker:1,personal' 'a removed worker leaves its account'
Assert-Equal (Fails { Set-WorkerEntry ($two | ConvertFrom-Json) '3' $true '' }) '' 'a new worker on the command-line login'
$idle = [pscustomobject]@{ state = 'idle'; at = 0 }
$shown = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $register
    workers = @(@{ id = '1'; state = $idle }, @{ id = '2'; state = $idle }, @{ id = '3'; state = $idle })
    usage = ('{"default":{"at":9,"month":{"used":1,"resetsAt":99999999999}},"C:/m":{"at":9,"short":{"used":0.2,"resetsAt":99999999999}}}' | ConvertFrom-Json) }
Assert-Equal (($shown.accounts | ForEach-Object { "$($_.name)=$($_.provider)" }) -join ' ') 'main=bare mine=test old=test' 'the page lists the accounts of every tool it serves, each with its tool'
$bareAccount = $shown.accounts[0]
$testAccount = $shown.accounts[1]
Assert-Equal "$($bareAccount.month.used) $($bareAccount.ContainsKey('short')) $($testAccount.short.used) $($testAccount.ContainsKey('month'))" '1 False 0.2 False' 'each account with the windows of its own tool'
Assert-Equal (($shown.workers | ForEach-Object { "$($_.id)=$($_.provider)/$($_.takes[0].model)" }) -join ' ') '1=bare/only 2=test/main-1 3=bare/only' 'each worker with its tool and that tool''s models; worker 3, in no entry, is on the command-line login''s tool'
Assert-Equal "$($shown.provider) | $($shown.tools.bare.title) $($shown.tools.bare.hooks.Count) $(($shown.tools.bare.windows | ForEach-Object { $_.name }) -join ',') | $($shown.tools.test.hooks.Count) $($shown.tools.test.windows.Count)" 'The test provider | The bare provider 0 month | 9 3' 'the default tool, and each tool with its features and windows'
# What a worker's mapping offers is its own tool's: the bare one has no efforts, no compact size and no advisor.
$bareTake = $shown.workers[0].takes[0]
Assert-Equal "$($shown.tools.bare.models -join ',') $($shown.tools.bare.efforts.Count) $($shown.tools.bare.compactRange.Count) '$($shown.tools.bare.advisor)' | '$($bareTake.effort)' $($bareTake.compactAt) '$($bareTake.advisor)' '$($shown.workers[0].mapping.advisor)'" "only 0 0 '' | '' 0 '' ''" 'a tool with no efforts, no compact size and no advisor'
Assert-Equal "$($shown.tools.test.models.Count) $($shown.tools.test.efforts.Count) $($shown.tools.test.compactRange -join '-') $($shown.tools.test.advisor) $($shown.modelTitles.'deep-1')" '4 5 67000-967000 deep-1 Deep 1' 'a tool with all of them'
# A model with efforts of its own (tests/provider: mid-1) has them in the snapshot, as a list through the JSON too,
# with the effort its pick gets when it names none; a model without them has no entry.
$perModel = (Json $shown).tools.test.perModel
Assert-Equal "$(@($perModel.'mid-1'.efforts).Count) $($perModel.'mid-1'.efforts -join ',') $($perModel.'mid-1'.effort) $($null -eq $perModel.'main-1')" '2 low,high high True' 'each model''s own efforts'
Assert-Equal "$($script:Provider.Name) $($shown.ContainsKey('loginTaken'))" 'test False' 'the default provider is set again after the snapshot'
# Queue next: each worker's account is read with the windows of the worker's own tool. Worker 1's month is used up, so
# the ticket goes to worker 2, which has more room, though the default tool's windows show nothing used on worker 1's
# account.
$large = Issue 50 @('P1', 'size:L')
Assert-Equal "$((Select-NextWorker $large @($large) @($shown.workers | Where-Object { $_.id -ne '3' }) $register $shown.accounts).worker) $($script:Provider.Name)" '2 test' 'Queue next reads an account with its own tool''s windows'
$next = Get-NextTickets @($large) @() @($shown.workers | Where-Object { $_.id -ne '3' }) $null $register $shown.accounts
Assert-Equal "$($next.'1'.available) $($next.'2'.available) $($script:Provider.Name)" 'False True test' 'so does each worker''s next ticket'
# A new account's sign-in is its own tool's: the server sets that tool's provider first, by its name.
Assert-Equal "$((Get-AccountProvider ([pscustomobject]@{ provider = 'bare' }) (Get-KnownProviders)).Title) $($null -eq (Get-AccountProvider ([pscustomobject]@{ provider = 'nope' }) (Get-KnownProviders)))" 'The bare provider True' 'a provider by its name'
# A script with one provider again.
$script:Providers = @()
Set-Provider $testProvider

# Rename: an account keeps its place, its folder and its uses; a taken or bad name changes nothing; a new account
# may not take a renamed account's folder.
$register = '{"accounts":{"main":{"provider":"test","uses":["frontdesk"]},"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1"]}}}'
$renamed = (Rename-Account ($register | ConvertFrom-Json) 'main' 'first' | ConvertTo-Json -Depth 8 -Compress)
Assert-Equal $renamed '{"accounts":{"first":{"provider":"test","uses":["frontdesk"]},"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1"]}}}' 'renamed in its place'
foreach ($bad in @('temp', 'Bad', '-x', '')) {
    $threw = $false
    try { Rename-Account ($register | ConvertFrom-Json) 'main' $bad | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "bad name '$bad'"
}
$threw = $false
try { Rename-Account ($register | ConvertFrom-Json) 'nope' 'x' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'no such account'
$folders = '{"accounts":{"other":{"configDir":"C:/Users/me/.test-temp1","uses":[]}}}' | ConvertFrom-Json
$threw = $false
try { Get-NewAccountDir $folders 'temp1' 'C:\Users\Me' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'a new account may not take a renamed account''s folder'
Assert-Equal (Get-NewAccountDir $folders 'temp2' 'C:\Users\me') 'C:/Users/me/.test-temp2' 'a free folder'
# A worker's name: trimmed, and '' takes it away.
$named = Set-WorkerName ('{"workers":{"2":{"enabled":true}}}' | ConvertFrom-Json) '2' '  Night box '
Assert-Equal ($named.workers.'2' | ConvertTo-Json -Compress) '{"enabled":true,"name":"Night box"}' 'a worker named'
Assert-Equal ((Set-WorkerName $named '2' '').workers.'2' | ConvertTo-Json -Compress) '{"enabled":true}' 'a name taken away'
$threw = $false
try { Set-WorkerName $named '2' ('x' * 31) | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'a name too long'
# The cards' order: saved per kind as a list, kept through an account's rename; another kind or a long list throws.
$ordered = Set-CardOrder ('{"accounts":{"a":{},"b":{}}}' | ConvertFrom-Json) 'accounts' @('b', 'a')
$ordered = Set-CardOrder $ordered 'workers' @('P|2')
$ordered = Rename-Account $ordered 'a' 'c'
Assert-Equal ($ordered.order | ConvertTo-Json -Compress) '{"accounts":["b","c"],"workers":["P|2"]}' 'the order of both kinds, a renamed account in its place'
foreach ($bad in @(@('cards', @('x')), @('workers', @(1..101)))) {
    $threw = $false
    try { Set-CardOrder $ordered $bad[0] $bad[1] | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true "no order of $($bad[0]) with $(@($bad[1]).Count) cards"
}
$shown = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = $ordered }).order
Assert-Equal "$($shown.accounts -join ',') $($shown.workers -join ',')" 'b,c P|2' 'the snapshot gives the page the order'
# Counted, not compared as JSON text: PowerShell 7 gives a hashtable's keys in no fixed order.
$none = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).order
Assert-Equal "$(@($none.Keys | Sort-Object) -join ',') $(@($none.workers).Count) $(@($none.accounts).Count)" 'accounts,workers 0 0' 'no order: empty lists'

# Add a worker and Remove: the lowest free number; a fresh entry on its account; removal takes it off every account.
Assert-Equal (Get-FreeWorkerId @('1', '3')) '2' 'a removed worker''s number comes back'
Assert-Equal (Get-FreeWorkerId @()) '1' 'the first worker'
Assert-Equal (Get-FreeWorkerId @('1', '2', '2')) '3' 'a number with a state file and a task is taken once'
$roster = '{"accounts":{"main":{"provider":"test","uses":["frontdesk"]},"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1"]}},"workers":{"2":{"enabled":false,"ghConfigDir":"C:/g"}}}' | ConvertFrom-Json
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
$own = '{"workers":{"1":{"model":"small-1@low"}}}' | ConvertFrom-Json
$take = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $own; workers = $idle }).workers[0].takes[0]
Assert-Equal "$($take.model) $($take.effort)" 'main-1 medium' 'a worker''s own model is no model'
# Details: the project's colour (a valid one only) and the settings' `model`. A worker's mapping: the advisor's model
# with its default, and each complexity's advisor switch as the owner set it, apart from the advisor that its run gets.
$owner = '{"color":"#A0B1C2","workers":{"1":{"mapping":{"test":{"advisor":{"model":"main-1"},
    "complexities":{"design":{"advisor":true},"low":{"advisor":true,"advisorFallback":"max"}}}}}}}' | ConvertFrom-Json
$details = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = $idle; settings = $owner }
$mapping = $details.workers[0].mapping
Assert-Equal "$($details.color) '$($mapping.follows)' $($mapping.end) $($mapping.advisor) $($mapping.baseAdvisor)" "#a0b1c2 '' 1 main-1 deep-1" 'the colour, and the advisor''s model of the worker''s mapping'
Assert-Equal (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = @{ model = 'mid-1@high' } }).settingsModel 'mid-1@high' 'the settings'' model'
$low = $details.workers[0].takes | Where-Object { $_.name -eq 'low' }
Assert-Equal "$($low.advisorOn) $($low.advisorFallback) $($low.baseAdvisor) '$($low.baseFallback)' '$($low.advisor)' $($low.linked) $($low.own)" "True max False '' '' False False" 'on, and no advisor for a run on the advisor''s own model'
$design = $details.workers[0].takes | Where-Object { $_.name -eq 'design' }
Assert-Equal "$($design.advisorOn) $($design.baseAdvisor) $($design.advisor) $($design.compactAt) $($design.description -ne '')" 'True False main-1 250000 True' 'a complexity that the owner gave the advisor'
# A worker that follows another shows that worker's picks, marked as linked.
Set-JsonProperty $owner.workers '2' ('{"mapping":{"test":{"follows":"1"}}}' | ConvertFrom-Json)
$pair = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $owner
    workers = @($idle[0], @{ id = '2'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
$low = $pair.workers[1].takes | Where-Object { $_.name -eq 'low' }
Assert-Equal "$($pair.workers[1].mapping.follows) $($pair.workers[1].mapping.end) $($pair.workers[1].mapping.advisor) $($low.advisorFallback) $($low.linked)" '1 1 main-1 max True' 'a worker that follows another'
foreach ($bad in 'red', '#abc', "#a0b1c2`nx", '') {
    $color = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = @{ color = $bad } }).color
    Assert-Equal "'$color'" "''" "no colour on the page: '$bad'"
}
$plain = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }
Assert-Equal "'$($plain.color)' '$($plain.settingsModel)' $($plain.advisor.model)" "'' '' deep-1" 'no settings'
# The PC's No blocking switch (docs/QUEUE.md, No blocking).
$gone = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(); settings = ('{"away":true}' | ConvertFrom-Json) }
Assert-Equal "$($plain.away) $($gone.away)" 'False True' 'the No blocking switch'
# The plugins and the complexities, for the Details tab: none for a plain git repo; models.json's four without a config.
$info = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @()
    plugins = @(@{ Name = 'unity'; Title = 'Scriptorium for Unity'; Version = '1.0.0'; Description = 'One editor each.'; Hooks = @{} }) }
Assert-Equal (($info.plugins | ForEach-Object { "$($_.name) $($_.title) $($_.version) $($_.description)" }) -join '|') 'unity Scriptorium for Unity 1.0.0 One editor each.' 'the plugins'
Assert-Equal @((New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).plugins).Count 0 'no plugin'
Assert-Equal (($info.complexities | ForEach-Object { "$($_.name)=$($_.effort)/$($_.advisor -ne '')" }) -join ' ') 'low=medium/False medium=high/True high=xhigh/True design=high/False' 'each complexity with its effort and advisor'
# The advisor rule from models.json, for the Details tab.
$advisor = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }).advisor
Assert-Equal "$($advisor.model) $(@($advisor.complexities) -join ',')" 'deep-1 medium,high' 'the advisor rule'
$temp = $snapshot.accounts | Where-Object { $_.name -eq 'temp' }
Assert-Equal "$($temp.own) $($temp.signedIn) $($temp.email) $($temp.plan) $($temp.status)" 'True True t@x Pro ready' 'account login'
Assert-Equal (($snapshot.accounts | Where-Object { $_.name -eq 'main' }).status) 'signedout' 'an account with no login is signed out'
Assert-Equal $snapshot.login.state 'waiting' 'sign-in passed through'
$future = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1000
foreach ($case in @(@('t@x', 0.5), @('old@x', $null))) {
    $usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = $case[0]; short = [pscustomobject]@{ used = 0.5; resetsAt = $future } } }
    $temp = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $settings; workers = @(); usage = $usage
        logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts | Where-Object { $_.name -eq 'temp' }
    Assert-Equal $temp.short.used $case[1] "reading of $($case[0]) on t@x's login"
}
# The stop line: the default and the account's own; under the week's, what each human use's share keeps for the time
# left (here half a week); at the ceiling, the account is at its limit.
$stops = '{"keep":{"personal":0.3},"accounts":{"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1","frontdesk","personal"],"stopAt":{"short":0.5,"long":0.9},"pickUp":{"short":{"L":0.4}}}}}' | ConvertFrom-Json
$usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = 't@x'; short = [pscustomobject]@{ used = 0.5; resetsAt = $future }
    long = [pscustomobject]@{ used = 0.2; resetsAt = $future - 1000 + 302400 } } }
$temp = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $stops; usage = $usage; workers = @()
    logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts[0]
$round = { param($share) [math]::Round($share, 2) }
Assert-Equal "$($temp.short.stopAt) $($temp.short.ceiling) $($temp.short.kept) $($temp.status)" '0.5 0.5 0 limit' 'the 5-hour stop line keeps no room'
$week = $temp.long
Assert-Equal "$($week.stopAt) $(& $round $week.left) $(& $round $week.kept) $(& $round $week.ceiling)" '0.9 0.5 0.2 0.7' 'the room kept under the week''s stop line'
Assert-Equal "$($temp.short.pickUp.S) $($temp.short.pickUp.L) $($week.ContainsKey('pickUp'))" '0.9 0.4 False' 'pick-up limits: the default and the account''s own, none for the week'
Assert-Equal (($week.guards | ForEach-Object { "$($_.use) $($_.share) $(& $round $_.kept)" }) -join ', ') 'frontdesk 0.1 0.05, personal 0.3 0.15' 'each guard: its share of a week and what it keeps now'
Assert-Equal $temp.ContainsKey($deep) $false 'no the deep model reading: no deep week'
# The deep week: its share, reset, read time, stop line and design line (each the default, else the account's own);
# nothing used once it has reset.
$own = '{"accounts":{"temp":{"provider":"test","configDir":"C:/t","uses":["worker:1"],"stopAt":{"deep":0.9},"pickUp":{"deep":{"design":0.7}}}}}' | ConvertFrom-Json
foreach ($case in @(@($future, $stops, '0.99 0.98 0.98 50 0.9'), @(5, $stops, '0 0.98 0.98 50 0.9'), @($future, $own, '0.99 0.9 0.9 50 0.7'))) {
    $usage = [pscustomobject]@{ 'C:/t' = [pscustomobject]@{ email = 't@x'
        $deep = [pscustomobject]@{ used = 0.99; resetsAt = $case[0]; at = 50 } } }
    $deepWeek = (New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = $case[1]; usage = $usage; workers = @()
        logins = @{ 'C:/t' = @{ signedIn = $true; email = 't@x'; plan = 'Pro' } } }).accounts[0].$deep
    Assert-Equal "$($deepWeek.used) $($deepWeek.stopAt) $($deepWeek.ceiling) $($deepWeek.at) $($deepWeek.pickUp.design)" $case[2] "the deep week, reset at $($case[0])"
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
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'big'; duration = 3600; cost = 10 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'big'; duration = 7200; cost = 30 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'L'; model = 'big'; duration = 5400; cost = 20 },
    @{ wall = $true; kind = 'ticket'; partial = $true; size = 'L'; model = 'big'; duration = 100; cost = 1 },
    @{ wall = $true; kind = 'answered'; partial = $true; size = 'L'; model = 'big'; duration = 100; cost = 1 },
    @{ kind = 'ticket'; partial = $false; size = 'L'; model = 'big'; duration = 3; cost = 1 },
    @{ wall = $true; kind = 'ticket'; partial = $false; size = 'S'; model = 'mid'; duration = 600; cost = 2 }
) | ForEach-Object { [pscustomobject]$_ }
Assert-Equal (Get-Typical $runs 'L' 'big') 5400 'typical L on one model'
Assert-Equal (Get-Typical $runs 'L' 'big' 'cost') 20 'typical cost of an L on one model'
Assert-Equal (Get-Typical $runs 'S' 'big') 600 'typical S falls back to any model'
Assert-Equal (Get-Typical $runs 'M' 'big') '' 'no history'

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
Assert-Equal (Next $next '4') '2 False api busy' 'the working one gets the next in the queue: its area is held by another worker'
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
    $account = @{ name = 'a'; short = @{ used = $used; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; long = @{ used = 0.1; ceiling = 0.9 } }
    return Next (Get-NextTickets $sized @() @($onAccount) $null $null @($account)) '1'
}
Assert-Equal (NextAt 0.2) '13 True' 'room for every size: the biggest ticket first'
Assert-Equal (NextAt 0.6) '12 True' 'over the L limit: an M (no size label counts as M)'
Assert-Equal (NextAt 0.8) '11 True' 'over the M limit: an S'
Assert-Equal (NextAt 0.92) '13 False over the pick-up limit for size L' 'over every limit: the first, locked'
Assert-Equal (Next (Get-NextTickets $sized @() @($onAccount)) '1') '13 True' 'no account known: every size'
# A ticket shown locked for the pick-up limit is not given: a worker on an account with room still gets it.
$full = @{ name = 'a'; short = @{ used = 0.92; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; long = @{ used = 0.1; ceiling = 0.9 } }
$room = @{ name = 'b'; short = @{ used = 0.1; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; long = @{ used = 0.1; ceiling = 0.9 } }
$two = Get-NextTickets $sized @() @($onAccount, @{ id = '2'; status = 'active'; activity = 'free'; account = 'b' }) $null $null @($full, $room)
Assert-Equal "$(Next $two '1') | $(Next $two '2')" '13 False over the pick-up limit for size L | 13 True' 'a locked ticket still goes to the worker with room'
Assert-Equal ((Get-QueueRows (@($sized) + @((Issue 14 @('P0', 'size:S')))) @($free)).queued.number -join ',') '14,13,12,11' 'queue order: priority, then the bigger ticket'
# Force takes the ticket shown, also one whose area is busy; a ticket that left the queue falls back to the first free.
$queue = @((Issue 2 @('P1', 'area:api')), (Issue 4 @('P2', 'area:docs')), (Issue 6 @('P2', 'area:api/auth')))
Assert-Equal (Select-Forced $queue 6 @('area:api')).number 6 'force takes the ticket the page showed'
Assert-Equal (Select-Forced $queue 99 @('area:api')).number 4 'else the first whose area is free'
Assert-Equal (Select-Forced $queue 0 @('area:api', 'area:docs')).number 2 'else the first'
# Now: a force file with `now` names the one ticket its worker takes, and only while that ticket is in the queue.
$file = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-now-$PID.json"
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
# A Now frees only a run held at a checkpoint: one that a limit cut off would lose its work.
Assert-Equal "$(Test-HeldAtCheckpoint @{ AtLimit = $true }) $(Test-HeldAtCheckpoint @{ Stopped = $true }) $(Test-HeldAtCheckpoint @{ ModelOut = 'deep'; ResetsAt = 5 }) $(Test-HeldAtCheckpoint @{ LoggedOut = $true })" 'True True False False' 'the held runs that a Now may free'
# The worker for a Queue next: a free one before one in a run; of those in a run the account with the most room, then
# the run that started last; before all, the worker whose ticket in work holds an area of this one.
function Working([string] $id, [int] $ticket, [string] $account, [long] $started) {
    return @{ id = $id; status = 'active'; activity = 'running'; ticket = $ticket; title = "Ticket $ticket"; account = $account; startedAt = $started }
}
function Account([string] $name, [double] $used) {
    return @{ name = $name; short = @{ used = $used; ceiling = 0.95; pickUp = @{ S = 0.9; M = 0.75; L = 0.5 } }; long = @{ used = 0.1; ceiling = 0.9 } }
}
function Now($pick) {
    return $(if ($pick.worker) { "$($pick.worker) stops $($pick.stops) busy '$($pick.busy -join ',')'" } else { $pick.why })
}
$urgent = Issue 20 @('P1', 'area:api')
$flight = @($urgent, (Issue 21 @('P1', 'area:ui', 'worker:1')), (Issue 22 @('P1', 'area:api/auth', 'worker:2')), (Issue 23 @('P1', 'area:db', 'worker:3')))
$accounts = @((Account 'a' 0.2), (Account 'b' 0.6))
$idle = @{ id = '4'; status = 'active'; activity = 'free'; account = 'b' }
Assert-Equal (Now (Select-NextWorker $urgent $flight @((Working '1' 21 'a' 100), (Working '3' 23 'a' 200), $idle) $null $accounts)) "4 stops 0 busy 'api'" 'a free worker first; another ticket in flight still holds the area'
# Every worker that can take it, the pick first: the owner may choose another.
$choice = (Select-NextWorker $urgent $flight @((Working '1' 21 'a' 100), (Working '3' 23 'a' 200), $idle) $null $accounts).able
Assert-Equal (($choice | ForEach-Object { "$($_.worker):$($_.stops)" }) -join ' ') '4:0 3:23 1:21' 'the workers the owner can choose from, in the order of the pick'
Assert-Equal (Now (Select-NextWorker $urgent $flight @((Working '1' 21 'a' 100), (Working '3' 23 'a' 200)) $null $accounts)) "3 stops 23 busy 'api'" 'one account: the run that started last'
Assert-Equal (Now (Select-NextWorker $urgent $flight @((Working '1' 21 'b' 100), (Working '3' 23 'a' 50)) $null $accounts)) "3 stops 23 busy 'api'" 'the account with the most room'
Assert-Equal (Now (Select-NextWorker $urgent $flight @((Working '2' 22 'b' 50), (Working '3' 23 'a' 200), $idle) $null $accounts)) "2 stops 22 busy ''" 'before all, the worker whose ticket holds the area: its end frees it'
$answers = Working '2' 22 'b' 50
$answers.kind = 'answered'
Assert-Equal (Now (Select-NextWorker $urgent $flight @($answers, (Working '3' 23 'a' 200)) $null $accounts)) "3 stops 23 busy 'api'" 'a PR''s job keeps its ticket and its area'
Assert-Equal (Now (Select-NextWorker $urgent $flight @((Working '1' 21 'b' 100)) $null @((Account 'b' 0.8)))) "1 stops 21 busy 'api'" 'room is no condition: the ticket waits with its worker'
$limit = @{ id = '2'; status = 'active'; activity = 'room'; account = 'b' }
Assert-Equal (Now (Select-NextWorker $urgent $flight @($limit) $null $accounts)) "2 stops 0 busy 'api'" 'nor is a worker at its limit left out: the arrow on its card forces the ticket'
$not = @(@{ id = '1'; status = 'paused'; activity = 'free' }, @{ id = '2'; status = 'active'; activity = 'signedout' }, @{ id = '3'; status = 'active'; activity = 'down' },
    @{ id = '5'; status = 'active'; activity = 'running'; pending = @{ to = 'paused' } }, @{ id = '6'; status = 'active'; activity = 'free' })
$off = '{"workers":{"6":{"complexity":{"medium":false}}}}' | ConvertFrom-Json
Assert-Equal (Now (Select-NextWorker $urgent $flight $not $off)) 'no worker can take it: each is paused, out or has its complexity off' 'no worker that looks for a job'
# The queue and the cards with a Now: the ticket is its worker's next, no other worker's, and has no Next button.
$taking = Working '3' 23 'a' 200
$taking.forced = $true
$taking.now = 20
$rows = Get-QueueRows $flight @($taking, $idle) $null $null $accounts
Assert-Equal "$($rows.queued[0].taken) $($rows.queued[0].reason) $([bool]$rows.queued[0].next)$([bool]$rows.queued[0].pinned)" '3 worker 3 does it now FalseFalse' 'a ticket that a Now names waits for its worker'
$rows = Get-QueueRows $flight @((Working '3' 23 'a' 200), $idle) $null $null $accounts
Assert-Equal "$($rows.queued[0].next.worker) $([bool]$rows.queued[0].taken)" '4 False' 'a queued ticket names the worker of its Queue next'
$blocked = (Get-QueueRows @((Issue 30 @('P1') 'Blocked by #31'), (Issue 31 @('P1', 'worker:1'))) @($idle)).queued[0]
Assert-Equal "$($blocked.reason) $($blocked.next.worker)" 'blocked by #31 4' 'a blocked ticket waits, and its Queue next names a worker'
$next = Get-NextTickets $flight @() @($taking, $idle)
Assert-Equal "$($next['3'].number) $($next['3'].kind) $($next['4'].number)" '20 now ' 'the Now is its worker''s next, and no other worker''s'
$doing = @{ id = '3'; status = 'active'; activity = 'running'; ticket = 20; forced = $true; now = 20 }
Assert-Equal "$((Get-NextTickets @((Issue 20 @('P1', 'worker:3'))) @() @($doing))['3'].number)" '' 'the ticket of the Now run in work is not its next'
# Queue next: the ticket of its worker's next file is that worker's next new ticket, and no other worker's.
Set-Content $file '{"ticket":6}' -Encoding utf8
Assert-Equal "$(Read-Next $file) $(Read-Next $file -Forced)" '6 0' 'the ticket queued as a worker''s next, not forced'
Set-Content $file '{"ticket":6,"force":true}' -Encoding utf8
Assert-Equal "$(Read-Next $file) $(Read-Next $file -Forced)" '6 6' 'and one the owner forced with the arrow'
Remove-Item $file
Assert-Equal (Read-Next $file) 0 'no next file'
$later = Working '3' 23 'a' 200
$later.queued = 20
$rows = Get-QueueRows $flight @($later, $idle) $null $null $accounts
Assert-Equal "$($rows.queued[0].taken) $($rows.queued[0].reason) $([bool]$rows.queued[0].next)$([bool]$rows.queued[0].pinned)" '3 worker 3 does it next FalseTrue' 'a ticket queued as a worker''s next waits for it'
$next = Get-NextTickets $flight @() @($later, $idle)
Assert-Equal "$($next['3'].number) $($next['3'].kind) $($next['4'].number)" '20 queued ' 'it is its worker''s next, and no other worker''s'
# It forces nothing: it waits for a blocker and for a busy area (the area of its worker's own run counts as free), and
# for the pick-up limit of its size.
Assert-Equal "$($next['3'].available) $($next['3'].why) $($next['3'].forced)" 'False api busy False' 'a queued next waits while its area is busy'
$open = @(20, 21, 22, 23)
Assert-Equal (Get-NextWait $urgent $open @('area:db')) '' 'a queued next with no blocker and a free area does not wait'
Assert-Equal (Get-NextWait (Issue 26 @('P1', 'area:api') 'Blocked by #21') $open @('area:api')) 'blocked by #21' 'a blocker holds it before an area does'
$own = Working '2' 22 'b' 50
$own.queued = 20
Assert-Equal "$((Get-NextTickets $flight @() @($own) $null $null $accounts)['2'].available)" 'True' 'free areas and room: it is available'
Assert-Equal (Get-NextTickets $flight @() @($own) $null $null @((Account 'b' 0.8)))['2'].why 'over the pick-up limit for size M' 'over the pick-up limit of its size it waits'
# The worker's own PRs and tickets go before it; forced with the arrow, it goes before them and past what holds it.
$answer = @((Pr 72 22 @('worker:3', 'answered')))
Assert-Equal (Get-NextTickets $flight $answer @($later))['3'].kind 'answered' 'a PR to answer goes before a queued next'
$later.queuedForced = $true
$next = Get-NextTickets $flight $answer @($later)
Assert-Equal "$($next['3'].number) $($next['3'].kind) $($next['3'].forced) $($next['3'].available)" '20 queued True True' 'a forced one goes first and waits for no area'
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
$busyWorker = @{ id = '1'; state = [pscustomobject]@{ state = 'running'; at = 0; ticket = 1; size = 'L'; model = 'big'; startedAt = 0 } }
$snapshot = New-Snapshot @{ now = 0; slug = 'o/r'; workers = @($busyWorker); runs = $runs; gh = @{ issues = @((Issue 1 @('area:ui', 'area:api/search', 'worker:1', 'size:S')), (Issue 2 @('P1', 'area:api/auth', 'size:L')), (Issue 3 @('P1', 'size:S') '' '2026-10-11T10:00:00Z')); prs = @(); merged = @() } }
Assert-Equal "$($snapshot.workers[0].areas -join ',')|$($snapshot.queued[0].areas -join ',')" 'api/search,ui|api/auth' 'areas of a worker and a queued ticket'
Assert-Equal "$($snapshot.workers[0].typical) $($snapshot.workers[0].typicalCost) $($snapshot.workers[0].next.number)" '5400 20 2' 'the run against a typical one, and its next ticket'
# A worker's ticket shows its size label; its next ticket its complexity, medium with no label.
Assert-Equal "$($snapshot.workers[0].size) $($snapshot.workers[0].next.complexity)" 'S medium' 'size of the ticket in work, complexity of the next'
Assert-Equal "$($snapshot.left.count) $($snapshot.left.seconds) $($snapshot.left.cost)" '2 6000 22' 'what is left: tickets, time, cost'
# A ticket that a worker took since GitHub's last reading has no worker label there yet: it is not queued or next.
$fresh = New-Snapshot @{ now = 0; slug = 'o/r'; workers = @($busyWorker); runs = $runs; gh = @{ issues = @((Issue 1 @('P1', 'area:ui')), (Issue 2 @('P1', 'area:ui'))); prs = @(); merged = @() } }
Assert-Equal "$($fresh.queued.number -join ',') $($fresh.workers[0].next.number) $($fresh.queued[0].reason)" '2 2 ui busy' 'a ticket in work leaves the queue before GitHub shows its label'
# A GitHub reading wakes the idle workers when it offers work that the reading before it did not (Test-NewWork).
$before = @{ issues = @((Issue 1 @('P1', 'area:ui', 'worker:1')), (Issue 2 @('P1', 'area:ui')), (Issue 3 @())) }
Assert-Equal (Test-NewWork $null $before) $false 'the first reading wakes nobody'
Assert-Equal (Test-NewWork $before $before) $false 'the same reading wakes nobody'
Assert-Equal (Test-NewWork $before @{ issues = @($before.issues) + (Issue 4 @('P2')) }) $true 'a ticket that the front desk filed wakes the workers'
Assert-Equal (Test-NewWork $before @{ issues = @($before.issues[0], $before.issues[1], (Issue 3 @('P1'))) }) $true 'a parked ticket that got a priority wakes them'
Assert-Equal (Test-NewWork $before @{ issues = @((Issue 1 @('P1', 'area:ui', 'worker:1', 'needs-owner')), $before.issues[1], $before.issues[2]) }) $true 'a held PR frees its area: it wakes them'
Assert-Equal (Test-NewWork $before @{ issues = @($before.issues[0], (Issue 2 @('P1', 'area:ui', 'worker:2')), $before.issues[2]) }) $false 'a ticket that a worker took wakes nobody'
$json = New-Snapshot @{ now = 0; slug = 'o/r'; workers = @(); runs = @(); gh = @{ issues = @((Issue 2 @('P1'))); prs = @(); merged = @() } } | ConvertTo-Json -Depth 5 -Compress
Assert-Equal ($json -match '"areas":\[\]') $true 'no area is an empty list'

# A paused worker keeps its ticket in its slot; a run that waits for its limit shows the time worked so far.
$pausedWorker = @{ id = '1'; state = [pscustomobject]@{ state = 'stopped'; at = 0 } }
$control = Json @{ workers = @{ '1' = 'stop' } }
$view = (New-Snapshot @{ now = 0; slug = 'o/r'; workers = @($pausedWorker); runs = @(); control = $control; gh = @{ issues = @((Issue 5 @('P1', 'worker:1'))); prs = @(); merged = @() } }).workers[0]
Assert-Equal "$($view.status) $($view.ticket)" 'paused 5' 'a paused worker keeps its ticket'
$limited = @{ id = '1'; state = [pscustomobject]@{ state = 'paused'; at = 0; ticket = 5; resetsAt = 600; elapsed = 1200; kind = 'ticket'; size = 'L'; model = 'big' } }
$view = (New-Snapshot @{ now = 10; slug = 'o/r'; workers = @($limited); runs = $runs }).workers[0]
Assert-Equal "$($view.status) $($view.activity) $($view.elapsed) $($view.typical)" 'active limit 1200 5400' 'at its usage limit: active, with its progress'
Assert-Equal (New-Snapshot @{ now = 700; awake = 700; slug = 'o/r'; workers = @($limited); runs = $runs }).workers[0].activity 'resuming' 'after the reset the run resumes: no reset time in the past'
# A run held for the owner's pause (worker.ps1, Suspend-Job): the worker is paused and keeps its run and progress.
$heldRun = @{ id = '1'; state = [pscustomobject]@{ state = 'stopped'; at = 0; ticket = 5; resetsAt = 5; stopped = $true; elapsed = 1200; kind = 'ticket'; size = 'L'; model = 'big' } }
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
$log = Join-Path ([IO.Path]::GetTempPath()) "queue-app-test-$PID.jsonl"
# Written without a byte order mark, as a run writes its log.
[System.IO.File]::WriteAllLines($log, [string[]]@('step I stop here.', 'end error(max_turns) Reached the turn limit.'))
Assert-Equal (Get-StuckReason $log) 'The run failed (max_turns): Reached the turn limit.' 'a failed run'
[System.IO.File]::WriteAllLines($log, [string[]]@('end ok I stop #7 here.'))
Assert-Equal (Get-StuckReason $log) 'The run ended by itself. Its last words: I stop #7 here.' 'a run that ended by itself'
[System.IO.File]::WriteAllLines($log, [string[]]@('step Bash: Run the suite'))
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

# Steps: what the provider reads from a line, in one line of at most 160 characters; '' for a line that is no step.
Assert-Equal (Get-StepText 'step Rungs  pass.') 'Rungs pass.' 'a step in one line'
Assert-Equal (Get-StepText ('step ' + ('x' * 200))).Length 160 'a long step is cut'
Assert-Equal (Get-StepText 'end ok done') '' 'not a step'
Assert-Equal (@(Get-Steps 'C:\none.jsonl' 3)).Count 0 'no log, no steps'
# A worker's last run may be another coding tool's: the log goes to the provider that reads a step from it.
$log = Join-Path ([IO.Path]::GetTempPath()) "queue-app-test-$PID.jsonl"
$both = @($testProvider, $bareProvider)
[System.IO.File]::WriteAllLines($log, [string[]]@('step one', 'end ok done'))
Assert-Equal "$((Get-LogProvider $log $bareProvider $both).Name) $((Get-LogProvider $log $testProvider $both).Name) $((Get-LogProvider $log $null $both).Name)" 'test test test' 'the provider that reads a step, also for a worker of another tool or of none'
[System.IO.File]::WriteAllLines($log, [string[]]@('end ok done'))
Assert-Equal "$((Get-LogProvider $log $bareProvider $both).Name) $($script:Provider.Name)" 'bare test' 'a log with no step stays the worker''s own, and the provider from before is set again'
Remove-Item $log

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
$register = '{"accounts":{"main":{"provider":"test","uses":["worker:1","worker:3"]},"third":{"provider":"test","configDir":"C:/third","uses":["worker:2"]}}}' | ConvertFrom-Json
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
# A refused request has no detail: the reason leaves it out.
$log = Join-Path ([IO.Path]::GetTempPath()) "queue-app-test-$PID.jsonl"
[System.IO.File]::WriteAllLines($log, [string[]]@('end error Not logged in'))
Assert-Equal (Get-StuckReason $log) 'The run failed: Not logged in' 'a refused request'
Remove-Item $log

# The provider and its windows for the Accounts tab, and each model's name on the page.
$shown = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @() }
Assert-Equal "$($shown.provider): $(($shown.windows | ForEach-Object { "$($_.name)=$($_.title)/$($_.models)/$($_.keep)" }) -join ' ')" 'The test provider: short=5 hours/False/False long=Week/False/True deep=Deep week/True/False' 'the windows'
Assert-Equal "$($shown.modelTitles.'main-1') $($shown.modelTitles.ContainsKey('mid-1'))" 'Main 1 False' 'the models'' names'
# The features the provider has, by their hooks: the page offers only these.
Assert-Equal "$($shown.hooks.Count) $($shown.hooks -contains 'Probe') $($shown.hooks -contains 'GetCommand') $($shown.compactRange.Count)" '9 True False 2' 'every feature of the test provider, no needed hook among them, and the compact sizes'
# With a provider that has only the hooks it must have: no step and no end from a log, one window, no advisor, no
# effort, and a sign-in folder with its name.
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/bare') 'bare' $null)
$log = Join-Path ([IO.Path]::GetTempPath()) "queue-app-test-$PID.jsonl"
[System.IO.File]::WriteAllLines($log, [string[]]@('step one', 'end ok done'))
Assert-Equal "$(@(Get-Steps $log 3).Count) $(Get-StuckReason $log)" '0 The run''s process ended with no result (a crash or a kill).' 'a log that the provider does not read'
Remove-Item $log
$bare = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); settings = ('{"accounts":{"a":{"provider":"bare","configDir":"C:/a","uses":["worker:1","personal"]}}}' | ConvertFrom-Json)
    workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }); logins = @{ 'C:/a' = @{ signedIn = $true } } }
Assert-Equal "$(($bare.windows | ForEach-Object { $_.name }) -join ',') $($bare.accounts[0].month.ceiling) $($bare.accounts[0].month.ContainsKey('guards')) $($bare.accounts[0].status)" 'month 1 False ready' 'one window, nothing kept'
Assert-Equal $bare.accounts[0].month.ContainsKey('pickUp') $false 'its only window has no pick-up limits for the page''s meter'
Assert-Equal "'$($bare.advisor.model)' $($bare.efforts.Count) $($bare.workers[0].takes[0].model) '$($bare.workers[0].takes[0].effort)' $($bare.complexities[0].compactAt)" "'' 0 only '' 0" 'no advisor, no effort, no compact size'
Assert-Equal "$($bare.hooks.Count) $($bare.compactRange.Count)" '0 0' 'no feature and no compact size'
# The picture behind a tool's account cards: an SVG in the plugin's folder as a data URL, none for another name.
$artDir = Join-Path ([IO.Path]::GetTempPath()) "queue-app-art-$PID"
New-Item -ItemType Directory -Force $artDir | Out-Null
[IO.File]::WriteAllText((Join-Path $artDir 'card.svg'), '<svg/>')
Assert-Equal "$(Get-CardArt @{ Dir = $artDir; Card = 'card.svg' })|$(Get-CardArt @{ Dir = $artDir; Card = '../card.svg' })|$(Get-CardArt @{ Dir = $artDir; Card = '' })" 'data:image/svg+xml;base64,PHN2Zy8+||' 'a plugin''s card picture'
# A new picture shows without a restart of the server: a pull of the plugin changes no .ps1 when only its picture is new.
[IO.File]::WriteAllText((Join-Path $artDir 'card.svg'), '<svg />')
Assert-Equal (Get-CardArt @{ Dir = $artDir; Card = 'card.svg' }) 'data:image/svg+xml;base64,PHN2ZyAvPg==' 'a plugin''s new card picture'
Remove-Item -Recurse $artDir
Assert-Equal (Get-NewAccountDir ('{"accounts":{}}' | ConvertFrom-Json) 'x' 'C:\Users\me') 'C:/Users/me/.bare-x' 'the folder of a new account'
# With no provider the page still shows the queue: no model and no window.
Set-Provider $null
$none = New-Snapshot @{ now = 10; slug = 'o/r'; runs = @(); workers = @(@{ id = '1'; state = [pscustomobject]@{ state = 'idle'; at = 0 } }) }
Assert-Equal "'$($none.provider)' $($none.windows.Count) $($none.models.Count) $(($none.complexities | ForEach-Object { $_.name }) -join ',')" "'' 0 0 low,medium,high,design" 'no provider'
Assert-Equal $none.hooks.Count 0 'no provider: no feature'

# The sign-in's email goes into a shell command line: only what an address has, for the shell of every system.
Assert-Equal "$(Test-EmailAddress 'me@example.com') $(Test-EmailAddress 'first.last+queue_1@mail-1.example.org')" 'True True' 'a plain address'
foreach ($bad in @('$', '`', '(', ';', '&', '"', ' ', '|', '%', '<')) {
    Assert-Equal (Test-EmailAddress "me${bad}x@example.com") 'False' "an address with $bad before the @"
    Assert-Equal (Test-EmailAddress "me@exa${bad}mple.com") 'False' "an address with $bad after the @"
}
Assert-Equal "$(Test-EmailAddress "me@example.com`n") $(Test-EmailAddress 'me@x@example.com') $(Test-EmailAddress '@example.com')" 'False False False' 'a last newline, two @ and no name'

Write-Output 'ok'
