# Checks budget.ps1's arithmetic: powershell -NoProfile -File tests/budget.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'budget.ps1')
. (Join-Path $baseDir 'project.ps1')
. (Join-Path $baseDir 'plugins.ps1')
# The windows are the test provider's (tests/provider/models.json): short, long (it keeps) and deep (some models).
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/provider') 'test' $null)
$deep = 'deep'

function Assert-Near([double] $actual, [double] $expected, [string] $what) {
    if ([math]::Abs($actual - $expected) -gt 1e-9) {
        throw "${what}: expected $expected, got $actual"
    }
}

$day = 86400
$week = $WindowSeconds.long

# The share of the week kept for a human use: the settings' over the default; 0 keeps nothing; a use nobody set
# keeps nothing.
$set = '{"keep":{"frontdesk":0.2,"personal":0}}' | ConvertFrom-Json
Assert-Near (Get-Keep 'frontdesk' $set) 0.2 'kept share from the settings'
Assert-Near (Get-Keep 'personal' $set) 0.0 'a kept share of nothing'
Assert-Near (Get-Keep 'personal' $null) $DefaultKeep.personal 'the default kept share'
Assert-Near (Get-Keep 'guest' $null) 0.0 'a use with no kept share'
# A guard keeps its share for the time left: 4/7 of it three days after a reset, all of it in a week not started,
# nothing after the reset.
Assert-Near (Get-Reserve 0.14 (4 * $day)) 0.08 'reserve three days after the reset'
Assert-Near (Get-Reserve 0.14 (2 * $week)) 0.14 'reserve of a week not started'
Assert-Near (Get-Reserve 0.14 -5) 0.0 'reserve after the reset'
Assert-Near (Get-Ceiling 0.0 'short') 0.98 '5-hour ceiling with no human use'
Assert-Near (Get-Ceiling 0.0 'long') 1.0 'weekly ceiling with no human use: the whole week'
Assert-Near (Get-Ceiling 0.0 'short' 0.8) 0.8 'the stop line of the account'
Assert-Near (Get-Ceiling 0.3 'long' 0.9) 0.6 'the reserve is an offset below the stop line'
Assert-Near (Get-Ceiling 0.3 'long' 0.2) 0.0 'a reserve bigger than the stop line leaves the workers nothing'

# Pace: the same room is more urgent the sooner it resets.
if ((Get-Pace 0.2 $day) -le (Get-Pace 0.9 (5 * $day))) {
    throw 'a fifth of the week resetting tomorrow should outrank nine tenths resetting in five days'
}

# Fit: an M (30 % of 5 hours) with too little room starts and pauses at the workers' ceiling, on any account, unless
# less than the least start room is left; nothing pending and room enough runs it whole.
function Assert-Same($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}
# The pick-up limits: an account's own over the default, per window and size.
$set = '{"short":{"L":0.4}}' | ConvertFrom-Json
Assert-Same (Get-PickUp $set 'short').L 0.4 'the pick-up limit of the account'
Assert-Same (Get-PickUp $set 'short').M $DefaultPickUp.short.M 'the default pick-up limit of another size'
Assert-Same (Get-PickUp $set 'long') $null 'the week has no pick-up limits'
# A ticket is taken while the 5-hour window is under its size's pick-up limit and both windows are under the ceiling.
$limits = @{ S = 0.9; M = 0.75; L = 0.5 }
$budget = { param($five, $week, $ceiling) @{ short = @{ used = $five; ceiling = 0.98; pickUp = $limits }
    long = @{ used = $week; ceiling = $ceiling; pickUp = $null } } }
Assert-Same (Get-Fit 'L' (& $budget 0.49 0.2 1.0)) $true 'an L under its limit'
Assert-Same (Get-Fit 'L' (& $budget 0.5 0.2 1.0)) $false 'an L at its limit'
Assert-Same (Get-Fit 'M' (& $budget 0.5 0.2 1.0)) $true 'an M where an L is not taken'
Assert-Same (Get-Fit 'L' (& $budget 0.2 0.99 1.0)) $true 'the week holds no size back under its ceiling'
Assert-Same (Get-Fit 'S' (& $budget 0.2 1.0 1.0)) $false 'the week at its ceiling'
Assert-Same (Get-Fit 'S' (& $budget 0.5 0.6 0.55)) $false 'the week over a ceiling that a guard lowered'
$low = & $budget 0.6 0.2 1.0
$low.short.ceiling = 0.55
Assert-Same (Get-Fit 'S' $low) $false 'a ceiling below the pick-up limit wins'

# Priority: the whole label, so queue order puts a newer P0 before an older P1.
Assert-Same (Get-Priority @('size:L', 'P0', 'area:docs')) 'P0' 'one priority label'
Assert-Same (Get-Priority @('P2', 'P1')) 'P1' 'the highest of two'
Assert-Same (Get-Priority @('size:L')) '' 'no priority label'
$order = @(@{ n = 20; p = 'P1'; c = '2026-01-01' }, @{ n = 21; p = 'P0'; c = '2026-01-02' }) |
    Sort-Object @{ Expression = { Get-Priority @($_.p, 'size:L') } }, @{ Expression = { $_.c } }
Assert-Same $order[0].n 21 'a newer P0 goes before an older P1'

# A worker takes a complexity unless its settings switch it off; a ticket without the label counts as medium.
$switches = '{"workers":{"2":{"complexity":{"design":false,"medium":false,"high":true}}}}' | ConvertFrom-Json
Assert-Same (Test-ComplexityOff 'design' $switches '2') $true 'a complexity switched off'
Assert-Same (Test-ComplexityOff 'design' $switches '1') $false 'another worker still takes it'
Assert-Same (Test-ComplexityOff 'high' $switches '2') $false 'a complexity switched on'
Assert-Same (Test-ComplexityOff 'low' $switches '2') $false 'a complexity the settings do not name'
Assert-Same (Test-ComplexityOff '' $switches '2') $true 'no label counts as medium'
Assert-Same (Test-ComplexityOff 'design' $null '2') $false 'no settings: every complexity is on'

# How a run that ended unfinished is held: the owner's pause keeps the session after a clean end on an enabled
# worker; a hard stop, an error and a disable keep nothing; the workers' limit holds a run without a stop note.
Assert-Same ((@('S', 'M', '', 'L') | ForEach-Object { Get-SizeRank $_ }) -join ',') '2,1,1,0' 'bigger first; no size counts as M'
# Get-Hold: limit note, stop note, the stop note still stands, a clean end, the worker is enabled.
Assert-Same (Get-Hold $false $true $true $true $true) 'pause' 'ended at a checkpoint for a pause'
Assert-Same (Get-Hold $true $true $true $true $true) 'pause' 'a standing pause goes before the limit'
Assert-Same (Get-Hold $false $true $true $false $true) '' 'a hard stop keeps nothing'
Assert-Same (Get-Hold $true $true $true $true $false) '' 'a disable keeps nothing'
Assert-Same (Get-Hold $true $false $false $false $true) 'limit' 'ended for the limit of the workers'
Assert-Same (Get-Hold $true $true $false $true $true) 'limit' 'a withdrawn stop note does not hide the limit'
Assert-Same (Get-Hold $true $true $false $false $true) 'limit' 'the limit holds also after an unclean end'
Assert-Same (Get-Hold $false $true $false $true $true) 'pause' 'ended for a stop note the owner withdrew'
Assert-Same (Get-Hold $false $false $false $true $true) '' 'no note: nothing to hold'

# How a run ends (docs/QUEUE.md: The usage limit, A model's limit, An account that is out, The owner's pause, Now; the
# cap of a run, Models). One row for each branch, with the whole answer.
# Get-RunEnd: Session|Limited|ModelRefused|WindowOut|Refusal|Capped|Clean. $held is a held run as paused.json reads.
function Show-RunEnd($end) { "$($end.Session)|$($end.Limited)|$($end.ModelRefused)|$($end.WindowOut)|$($end.Refusal)|$($end.Capped)|$($end.Clean)" }
$held = '{ "Session": "s0" }' | ConvertFrom-Json
$refusedUsage = @{ refused = $true; modelRefused = '' }
$deepUsage = @{ refused = $false; modelRefused = $deep }
foreach ($row in @(
        @(@{ Session = 's1'; Ended = $true; Worked = $true }, $null, $null, 's1|False|False|||False|True', 'a clean end'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Worked = $true }, $null, $null, 's1|False|False|||False|False', 'the run''s own error'),
        @(@{ Session = 's1' }, $null, $null, 's1|False|False|||False|False', 'no result: a hard stop'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'limit' }, $null, $null, 's1|True|False|||False|False', 'the plan''s limit keeps the session the refusal named'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'login'; Worked = $true }, $refusedUsage, $null, 's1|True|False|||False|False', 'a refusal under the plan''s limit is the limit'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'window'; Window = $deep; Worked = $true }, $null, $null, "s1|False|False|$deep||False|False", 'a window of some models'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'window'; Window = 'other'; Worked = $true }, $null, $null, 's1|True|False|||False|False', 'a window models.json does not name is the plan''s limit'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'start' }, $deepUsage, $null, "|False|False|$deep||False|False", 'the reading names the window of a run that ended with an error'),
        @(@{ Session = 's1'; Ended = $true; Worked = $true }, $deepUsage, $null, 's1|False|False|||False|True', 'not after a clean end'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'model' }, $null, $null, '|False|True|||False|False', 'a model the plan lacks'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'login' }, $null, $null, '|False|False||login|False|False', 'a login refusal that did no work starts fresh'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'subscription' }, $null, $held, 's0|False|False||subscription|False|False', 'a resumed one keeps the held session'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Kind = 'login'; Worked = $true }, $null, $null, 's1|False|False||login|False|False', 'one that did work keeps its own'),
        @(@{ Session = 's1'; Ended = $true; Error = $true; Capped = $true; Worked = $true }, $null, $null, 's1|False|False|||True|False', 'the cap')
    )) {
    Assert-Same (Show-RunEnd (Get-RunEnd $row[0] $row[1] $row[2])) $row[3] "Get-RunEnd: $($row[4])"
}
# Get-RunHold: an end, Now elsewhere, limit note, stop note, stop note stands, enabled.
$clean = Get-RunEnd @{ Session = 's1'; Ended = $true; Worked = $true } $null $null
$limitEnd = Get-RunEnd @{ Session = 's1'; Ended = $true; Error = $true; Kind = 'limit' } $null $null
$cappedEnd = Get-RunEnd @{ Session = 's1'; Ended = $true; Error = $true; Capped = $true; Worked = $true } $null $null
Assert-Same (Get-RunHold $clean $true $false $true $true $true) 'freed' 'Get-RunHold: the stop note of a Now for another ticket frees the run'
Assert-Same (Get-RunHold $clean $true $false $false $false $true) '' 'Get-RunHold: a Now with no stop note holds nothing'
Assert-Same (Get-RunHold $limitEnd $false $true $false $false $true) '' 'Get-RunHold: the plan''s limit is held by the main loop, not here'
Assert-Same (Get-RunHold $cappedEnd $false $true $false $false $true) '' 'Get-RunHold: a capped run is never held, not at the workers'' limit either'
Assert-Same (Get-RunHold $clean $false $true $false $false $true) 'limit' 'Get-RunHold: the workers'' limit'
Assert-Same (Get-RunHold $clean $false $false $true $true $true) 'pause' 'Get-RunHold: the owner''s pause'
Assert-Same (Get-RunHold $clean $false $false $true $true $false) '' 'Get-RunHold: a disabled worker keeps nothing'
# Get-RunMarks: AtLimit|Stopped|Freed|Partial|Compact|Holds, for an end, a hold, resumed, the job's kind, the stop
# note stands.
function Show-Marks($marks) { "$($marks.AtLimit)|$($marks.Stopped)|$($marks.Freed)|$($marks.Partial)|$($marks.Compact)|$($marks.Holds)" }
$fresh = Get-RunEnd @{ Ended = $true; Error = $true; Kind = 'login' } $null $null
foreach ($row in @(
        @($clean, $null, $false, 'ticket', $false, 'False|False|False|False|False|True', 'a clean end of a ticket'),
        @($clean, $null, $true, 'ticket', $false, 'False|False|False|True|False|True', 'a resumed run is a part'),
        @($clean, $null, $false, 'answered', $false, 'False|False|False|True|False|True', 'a PR''s job is a part'),
        @($clean, 'limit', $false, 'ticket', $false, 'True|False|False|True|True|True', 'held at the workers'' limit: compacted'),
        @($clean, 'pause', $false, 'ticket', $true, 'False|True|False|True|True|True', 'held for a pause: compacted'),
        @($clean, 'pause', $false, 'ticket', $false, 'False|True|False|True|False|True', 'a stop note the owner withdrew: not compacted'),
        @($fresh, 'pause', $false, 'ticket', $true, 'False|False|False|True|False|False', 'no session: not held for a pause'),
        @($clean, 'freed', $false, 'ticket', $true, 'False|False|True|True|False|True', 'freed by a Now'),
        @($limitEnd, $null, $false, 'ticket', $false, 'False|False|False|True|False|True', 'the plan''s limit is a part'),
        @($fresh, $null, $false, 'rebase', $false, 'False|False|False|True|False|True', 'a PR''s job that did no work is held for its account')
    )) {
    Assert-Same (Show-Marks (Get-RunMarks $row[0] $row[1] $row[2] $row[3] $row[4])) $row[5] "Get-RunMarks: $($row[6])"
}
# Get-RunAction: Action|Whose|Refusal|StartFails|LoggedOut|Judge. An end as Invoke-Worker returns it: New-End's with
# the row's fields over it. The row: the end's fields, the job's kind, resumed, the next model, handed on, the model
# after, the probe's reply, start fails, halted, stop noted.
function New-End([hashtable] $over) {
    $end = @{ ModelRefused = $false; Model = 'main-1'; ModelOut = ''; Session = 's1'; Refusal = ''; RefusalText = 'text'
        Holds = $true; Limited = $false; AtLimit = $false; Stopped = $false; Freed = $false }
    foreach ($key in $over.Keys) {
        $end[$key] = $over[$key]
    }
    return $end
}
function Show-Action($act) { "$($act.Action)|$($act.Whose)|$($act.Refusal)|$($act.StartFails)|$($act.LoggedOut)|$($act.Judge)" }
$outReply = @{ answered = $true; kind = 'subscription'; text = 'pay' }
$okReply = @{ answered = $true; kind = ''; text = 'ok' }
foreach ($row in @(
        @(@{}, 'ticket', $false, 'main-1', $false, '', $null, 1, $false, $false, 'done|||0|False|True', 'a clean end: judged, and the start fails reset'),
        @(@{}, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $true, 'done|||0|False|False', 'after a stop note the owner withdrew: not judged'),
        @(@{ ModelRefused = $true }, 'ticket', $false, 'small-1', $false, '', $null, 1, $false, $false, 'next-model|||1|False|False', 'a model the plan lacks: the next candidate'),
        @(@{ ModelRefused = $true }, 'ticket', $false, 'main-1', $false, '', $null, 1, $false, $false, 'requeue-model|||1|False|False', 'no candidate left: the ticket goes back'),
        @(@{ ModelRefused = $true }, 'ticket', $true, 'small-1', $false, '', $null, 1, $false, $false, 'done|||1|False|True', 'a resumed run is parked'),
        @(@{ ModelRefused = $true }, 'answered', $false, 'main-1', $false, '', $null, 1, $false, $false, 'done|||1|False|True', 'a PR''s job is parked'),
        @(@{ ModelOut = $deep }, 'ticket', $false, 'main-1', $true, 'main-1', $null, 0, $false, $false, 'handed-on|||0|False|False', 'a ticket handed on for its first model'),
        @(@{ ModelOut = $deep; Session = '' }, 'ticket', $false, 'main-1', $false, 'main-1', $null, 0, $false, $false, 'requeue-window|||0|False|False', 'a model window''s limit, no run began'),
        @(@{ ModelOut = $deep }, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $false, 'requeue-window|||0|False|False', 'a model window with no model after'),
        @(@{ ModelOut = $deep }, 'ticket', $false, 'main-1', $false, 'main-1', $null, 0, $false, $false, 'go-on|||0|False|False', 'a run that did work goes on with the model after'),
        @(@{ ModelOut = $deep; Session = '' }, 'answered', $false, 'main-1', $true, 'main-1', $null, 0, $false, $false, 'go-on|||0|False|False', 'a PR''s job goes on with the model after, and hands nothing on'),
        @(@{ ModelOut = $deep }, 'rebase', $false, 'main-1', $false, '', $null, 0, $false, $false, 'done|||0|False|True', 'a PR''s job with no model after is parked'),
        @(@{ Refusal = 'login' }, 'ticket', $false, 'main-1', $false, '', $null, 1, $false, $false, 'suspend|account|login|1|True|False', 'signed out: held for its account'),
        @(@{ Refusal = 'subscription'; Session = ''; Holds = $false }, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $false, 'not-started|account|subscription|0|False|False', 'a ticket no run began is not held'),
        @(@{ Refusal = 'start' }, 'ticket', $false, 'main-1', $false, '', $outReply, 0, $false, $false, 'suspend|account|subscription|0|True|False', 'a start the probe finds out'),
        @(@{ Refusal = 'start'; Holds = $false }, 'ticket', $false, 'main-1', $false, '', $okReply, 0, $false, $false, 'retry-start||start|1|False|False', 'a start that failed once tries again'),
        @(@{ Refusal = 'start'; Holds = $false }, 'ticket', $false, 'main-1', $false, '', $null, 1, $false, $false, 'not-started|worker|start|1|False|False', 'a start that failed twice stops the worker'),
        @(@{ Limited = $true }, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $false, 'suspend|||0|False|False', 'the plan''s limit: held'),
        @(@{ AtLimit = $true }, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $false, 'suspend|||0|False|False', 'the workers'' limit: held'),
        @(@{ Stopped = $true }, 'ticket', $false, 'main-1', $false, '', $null, 0, $true, $true, 'suspend|||0|False|False', 'the owner''s pause: held'),
        @(@{ Freed = $true }, 'ticket', $false, 'main-1', $false, '', $null, 0, $true, $true, 'freed|||0|False|False', 'the owner''s Now'),
        @(@{}, 'ticket', $false, 'main-1', $false, '', $null, 0, $true, $true, 'stopped|||0|False|False', 'a hard stop or a disabled worker'),
        @(@{ Session = '' }, 'ticket', $false, 'main-1', $false, '', $null, 0, $false, $false, 'done|||0|False|True', 'the cap, or a run with no result: judged')
    )) {
    $act = Get-RunAction (New-End $row[0]) $row[1] $row[2] $row[3] $row[4] $row[5] $row[6] $row[7] $row[8] $row[9]
    Assert-Same (Show-Action $act) $row[10] "Get-RunAction: $($row[11])"
}
# Get-Outcome: a finished job is not parked; one that is not gets needs-owner on its ticket or its PR, and the cap is
# named.
Assert-Same "$($null -eq (Get-Outcome $true 'ticket' 60 'x.log'))" 'True' 'Get-Outcome: a ticket with a PR or a question'
Assert-Same "$((Get-Outcome $false 'ticket' 0 'x.log').Pr) $((Get-Outcome $false 'ticket' 0 'x.log').Comment)" 'False stopped without a PR or a question. Log: `x.log`' 'Get-Outcome: a ticket without a PR'
Assert-Same "$((Get-Outcome $false 'rebase' 0 'x.log').Pr) $((Get-Outcome $false 'rebase' 0 'x.log').Comment)" 'True stopped without finishing (rebase). Log: `x.log`' 'Get-Outcome: a PR''s job that did not finish'
Assert-Same (Get-Outcome $false 'ticket' 60 'x.log').Comment 'reached the cap of 60 for one run (runCap in scriptorium.json, else in the provider''s models.json) and stopped without a PR or a question. Log: `x.log`' 'Get-Outcome: the cap'

# A saved usage reading keeps each window from the stored reading where that one is further on.
function New-Reading([string] $email, [double] $five, [long] $fiveReset, [double] $week, [long] $weekReset) {
    return @{ email = $email; short = @{ used = $five; resetsAt = $fiveReset }; long = @{ used = $week; resetsAt = $weekReset } }
}
$stored = (New-Reading 'a@x' 0.15 1000 0.58 9000) | ConvertTo-Json | ConvertFrom-Json
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.04 1000 0.05 9000)
Assert-Near $merged.short.used 0.04 'a lower reading of the same window replaces the stored one: the limit was reset early'
Assert-Near $merged.long.used 0.05 'the same for the week'
# The same event read again has the same key; a new event, or the same after a refusal, has another.
$event = New-Reading 'a@x' 0.04 1000 0.05 9000
$again = New-Reading 'a@x' 0.04 1000 0.05 9000
$again.at = 77
Assert-Same (Get-ReadingKey $event) (Get-ReadingKey $again) 'the same event read later has the same key'
Assert-Same ((Get-ReadingKey $event) -eq (Get-ReadingKey (New-Reading 'a@x' 0.05 1000 0.05 9000))) $false 'a new event has another key'
$again.refused = $true
Assert-Same ((Get-ReadingKey $event) -eq (Get-ReadingKey $again)) $false 'a refusal has another key'
Assert-Near (Merge-Usage $stored (New-Reading 'a@x' 0.17 1000 0.58 9000)).short.used 0.17 'a higher reading replaces the stored one'
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.01 2000 0.59 9000)
Assert-Near $merged.short.used 0.01 'a reading of a later window replaces the stored one'
Assert-Near $merged.long.used 0.59 'each window is judged alone'
Assert-Near (Merge-Usage $stored (New-Reading 'a@x' 0.9 500 0.58 9000)).short.used 0.15 'a reading from before the reset does not replace the stored one'
Assert-Near (Merge-Usage $stored (New-Reading 'b@x' 0.04 1000 0.1 9000)).short.used 0.04 'another login replaces the stored reading'
Assert-Near (Merge-Usage $null (New-Reading 'a@x' 0.04 1000 0.1 9000)).short.used 0.04 'nothing stored: the new reading'

# The limit of the deep model: only runs on the deep model carry its window, so a reading without it (an the main model run, a probe) keeps the stored
# one. From the stop line the account has no the deep model until the reset.
$reading = New-Reading 'a@x' 0.1 1000 0.5 9000
$reading[$deep] = @{ used = 1.02; resetsAt = 9000 }
$stored = $reading | ConvertTo-Json | ConvertFrom-Json
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.2 1000 0.5 9000)
Assert-Near $merged[$deep].used 1.02 'a reading without the deep window keeps the stored one'
Assert-Same (Test-WindowOut $merged $deep 500) $true 'a used-up deep window before its reset'
Assert-Same (Test-WindowOut $merged $deep 9000) $false 'the same window after its reset'
Assert-Same (Test-WindowOut (@{ $deep = @{ used = 0.97; resetsAt = 9000 } }) $deep 500) $false 'a deep window under the stop line'
Assert-Same (Test-WindowOut (New-Reading 'a@x' 0.2 1000 0.5 9000) $deep 500) $false 'no deep window: runs on the deep model'
Assert-Same (Test-WindowOut $null $deep 500) $false 'no reading: runs on the deep model'
# The account's own stop line, else the default.
$deepWeek = @{ $deep = @{ used = 0.9; resetsAt = 9000 } }
Assert-Same (Test-WindowOut $deepWeek $deep 500 0.85) $true 'over the account''s own stop line'
Assert-Same (Test-WindowOut $deepWeek $deep 500 0.95) $false 'under the account''s own stop line'
Assert-Same (Test-WindowOut $deepWeek $deep 500 $null) $false 'no stop line of its own: the default'
# The two lines of a window of some models: the defaults; the account's own; the start line never above the stop line.
$lines = Get-ModelLines $deep $null $null
Assert-Same "$($lines.stop) $($lines.start)" '0.98 0.9' 'the default stop and start lines'
$own = '{"stopAt":{"deep":0.95},"pickUp":{"deep":{"design":0.8}}}' | ConvertFrom-Json
$lines = Get-ModelLines $deep $own.stopAt $own.pickUp
Assert-Same "$($lines.stop) $($lines.start)" '0.95 0.8' 'the account''s own lines'
$own = '{"stopAt":{"deep":0.85}}' | ConvertFrom-Json
Assert-Same "$((Get-ModelLines $deep $own.stopAt $null).start)" '0.85' 'a stop line under the start line takes it down'
Assert-Same ((@((Get-PickUp $null 'short').Keys) | Sort-Object) -join ',') 'L,M,S' 'the 5-hour window keeps its three sizes'

# Each window has its own read time, which the queue app shows. A deep window that is used up stays until its reset
# and takes the new reading's time: it was read again. One that is not used up takes a lower reading, as the others do.
$reading = New-Reading 'a@x' 0.1 1000 0.5 9000
$reading.at = 100
$reading[$deep] = @{ used = 1.0; resetsAt = 9000; at = 100 }
$stored = $reading | ConvertTo-Json | ConvertFrom-Json
$new = New-Reading 'a@x' 0.2 1000 0.5 9000
$new.at = 5000
$new[$deep] = @{ used = 0.97; resetsAt = 9000; at = 5000 }
$merged = Merge-Usage $stored $new
Assert-Near $merged[$deep].used 1.0 'a used-up deep window keeps its share before its reset'
Assert-Same ([long]$merged[$deep].at) 5000 'and takes the new read time'
$stored.$deep.used = 0.71
$new[$deep] = @{ used = 0.05; resetsAt = 9000; at = 5000 }
Assert-Near (Merge-Usage $stored $new)[$deep].used 0.05 'a deep window that was reset early takes the lower reading'
$new = New-Reading 'a@x' 0.2 1000 0.5 9000
$new.at = 5000
Assert-Same ([long](Merge-Usage $stored $new)[$deep].at) 100 'a reading without the deep window keeps its old read time'

# Get-Advisor (docs/QUEUE.md, Models): the advisor for medium, high and review runs (review: a project's own
# complexity) on another model, while the account has the deep model; none for low, for design (the deep model's own run) and at the limit of the deep model.
$advisor = '{"model":"deep-1","complexities":["medium","high","review"]}' | ConvertFrom-Json
Assert-Same (Get-Advisor $advisor 'high' 'main-1' $true) 'deep-1' 'a high run on the main model'
Assert-Same (Get-Advisor $advisor '' 'main-1' $true) 'deep-1' 'no label counts as medium'
Assert-Same (Get-Advisor $advisor 'review' 'main-1' $true) 'deep-1' 'a review run'
Assert-Same (Get-Advisor $advisor 'low' 'main-1' $true) '' 'a low run has none'
Assert-Same (Get-Advisor $advisor 'design' 'deep-1' $true) '' 'a design run has none'
Assert-Same (Get-Advisor $advisor 'design' 'main-1' $true) '' 'nor its rest on the main model after the limit of the deep model'
Assert-Same (Get-Advisor $advisor 'high' 'deep-1' $true) '' 'a run forced onto the advisor''s model has none'
Assert-Same (Get-Advisor $advisor 'high' 'main-1' $false) '' 'none while the account has no the deep model'
Assert-Same (Get-Advisor $null 'high' 'main-1' $true) '' 'no advisor in models.json'

# Get-FallbackEffort: a higher effort only where the complexity has a fallback and the advisor is not there now.
$advisor = '{"model":"deep-1","complexities":["medium","high","review"],"fallback":{"review":"xhigh"}}' | ConvertFrom-Json
Assert-Same (Get-FallbackEffort $advisor 'review' 'main-1' 'high' $false) 'xhigh' 'a review run without the advisor'
Assert-Same (Get-FallbackEffort $advisor 'review' 'main-1' 'high' $true) 'high' 'a review run with the advisor'
Assert-Same (Get-FallbackEffort $advisor 'medium' 'main-1' 'high' $false) 'high' 'no fallback for medium'
Assert-Same (Get-FallbackEffort $advisor 'low' 'main-1' 'medium' $false) 'medium' 'low has no advisor to make up for'
Assert-Same (Get-FallbackEffort $advisor 'design' 'deep-1' 'high' $false) 'high' 'nor design'
Assert-Same (Get-FallbackEffort $null 'review' 'main-1' 'high' $false) 'high' 'no advisor in models.json'

Assert-Same (($OutKinds | Sort-Object) -join ',') 'login,start,subscription' 'the kinds that put an account out'

# A provider's reading as the PC keeps it (ConvertTo-Reading): the provider's windows only, each with the read time; a
# refusal of the account, and one of a window of some models under that window's name.
$given = @{ Windows = @{ short = @{ Used = 0.4; ResetsAt = 900 }; nope = @{ Used = 1; ResetsAt = 900 } }; Refused = ''; RefusedResetsAt = 0 }
$kept = ConvertTo-Reading $given 50
Assert-Same "$($kept.at) $($kept.short.used) $($kept.short.resetsAt) $($kept.short.at) $($kept.ContainsKey('nope')) $($kept.ContainsKey('long')) $($kept.refused) '$($kept.modelRefused)'" "50 0.4 900 50 False False False ''" 'a reading of one window'
Assert-Same "$((ConvertTo-Reading @{ Refused = 'short'; RefusedResetsAt = 70 } 50).refused) $((ConvertTo-Reading @{ Refused = $deep } 50).modelRefused) $((ConvertTo-Reading @{ Refused = $deep } 50).refused) $($null -eq (ConvertTo-Reading $null 50))" "True $deep False True" 'the refusals of a reading, and no reading'
# The PC's usage file (Save-Reading), which the workers and the page's Ping write: another account's record stays; under
# the same login a window that the new reading does not have stays; under another login the record is replaced.
$file = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-usage-test-$PID.json"
Remove-Item $file -ErrorAction SilentlyContinue
$far = 99999999999
Save-Reading $file 'C:/a' @{ at = 10; email = 'a@x'; short = @{ used = 0.2; resetsAt = $far; at = 10 }; $deep = @{ used = 0.3; resetsAt = $far; at = 10 } }
Save-Reading $file 'C:/b' @{ at = 11; email = 'b@x'; short = @{ used = 0.7; resetsAt = $far; at = 11 } }
Save-Reading $file 'C:/a' @{ at = 20; email = 'a@x'; short = @{ used = 0.5; resetsAt = $far; at = 20 } }
$all = Read-RecordFile $file
Assert-Same "$($all.Count) $($all.'C:/a'.short.used) $($all.'C:/a'.$deep.used) $($all.'C:/a'.at) $($all.'C:/b'.short.used)" '2 0.5 0.3 20 0.7' 'a save keeps the other account and a window the new reading has not'
Save-Reading $file 'C:/a' @{ at = 30; email = 'other@x'; short = @{ used = 0.1; resetsAt = $far; at = 30 } }
$all = Read-RecordFile $file
Assert-Same "$($all.'C:/a'.short.used) $($null -eq $all.'C:/a'.$deep) $($all.'C:/a'.email)" '0.1 True other@x' 'another login in the folder: its reading replaces the record'
Remove-Item $file
Assert-Same (Read-RecordFile $file).Count 0 'no file: no reading'
Set-Content $file 'not json' -Encoding utf8
Assert-Same (Read-RecordFile $file).Count 0 'a file that does not parse: no reading'
# The PC's access file (Save-ModelRefused): a refusal keeps the account's other models and the other accounts, and a
# second one moves the time. A file that does not parse is written whole again.
Save-ModelRefused $file 'C:/a' 'deep-1' 100
Save-ModelRefused $file 'C:/a' 'main-1' 110
Save-ModelRefused $file 'C:/b' 'deep-1' 120
Save-ModelRefused $file 'C:/a' 'deep-1' 130
$all = Read-RecordFile $file
Assert-Same "$($all.Count) $($all.'C:/a'.'deep-1') $($all.'C:/a'.'main-1') $($all.'C:/b'.'deep-1') $(Test-Path "$file.tmp")" '2 130 110 120 False' 'the models each account was refused'
Remove-Item $file

# A probe when a run ends: only with a provider that has a probe and reads no usage from a run's log.
Assert-Same "$(Test-ProbeAfterRun $false $true) $(Test-ProbeAfterRun $true $true) $(Test-ProbeAfterRun $false $false) $(Test-ProbeAfterRun $true $false)" 'True False False False' 'the usage is read again after a run whose log holds none'

# When an account has room again: the latest reset of its windows at their ceiling; 0 with none, so a run that the
# service's own shortage ended waits its 30 minutes, not for a reset.
$full = @{ short = @{ used = 1.0; ceiling = 0.95; resetsAt = 500 }; long = @{ used = 0.3; ceiling = 1.0; resetsAt = 900 } }
$room = @{ short = @{ used = 0.5; ceiling = 0.95; resetsAt = 500 }; long = @{ used = 0.3; ceiling = 1.0; resetsAt = 900 } }
$both = @{ short = @{ used = 0.95; ceiling = 0.95; resetsAt = 500 }; long = @{ used = 1.0; ceiling = 1.0; resetsAt = 900 } }
Assert-Same "$(Get-RoomAt $full) $(Get-RoomAt $room) $(Get-RoomAt $both)" '500 0 900' 'the reset that gives an account room again'

# The provider's windows (Set-Windows): the account's own shortest first, the one that keeps, the ones of some models.
Assert-Same "$(@($WindowSeconds.Keys) -join ',') $ShortWindow $LongWindow $KeepWindow $(@($ModelWindows.Keys) -join ',')" 'short,long short long long deep' 'the windows of the test provider'
Assert-Same "$(Get-ModelWindow 'deep-1')|$(Get-ModelWindow 'main-1')|$(Get-ModelWindow '')" 'deep||' 'the window that covers a model'
Assert-Same "$($ModelWindows.deep.after) $($WindowTitles.deep)" 'main-1@xhigh Deep week' 'a window''s model after it and its title'
# A provider with one window that neither keeps nor names pick-up limits: nothing is kept, the window has no pick-up
# limits (only its ceiling holds a ticket back), and no model has a window of its own.
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/bare') 'bare' $null)
Assert-Same "$(@($WindowSeconds.Keys) -join ',') $ShortWindow $LongWindow '$KeepWindow' $($ModelWindows.Count)" "month month month '' 0" 'one window'
Assert-Near (Get-Reserve 0.14 $day) 0.0 'no window keeps: no reserve'
Assert-Near (Get-Ceiling 0.0 'month') 1.0 'a window with no stop line of its own stops at the whole'
Assert-Same (Get-PickUp ('{"month":{"L":0.3}}' | ConvertFrom-Json) 'month') $null 'the only window has no pick-up limits, an account''s own neither'
$at = { param($used) @{ month = @{ used = $used; ceiling = 0.95; pickUp = (Get-PickUp $null 'month') } } }
Assert-Same "$(Get-Fit 'L' (& $at 0.94)) $(Get-Fit 'L' (& $at 0.95))" 'True False' 'a big ticket is held back only at the ceiling'
# Which window has the base's limits: the shortest of the whole account, and only where the provider gave it none.
Set-Windows ('{"day":{"seconds":86400},"week":{"seconds":604800,"keep":true},"deep":{"seconds":3600,"models":"deep-*"}}' | ConvertFrom-Json)
Assert-Same "$((@((Get-PickUp $null 'day').Keys) | Sort-Object) -join ',') $($null -eq (Get-PickUp $null 'week')) $($null -eq (Get-PickUp $null 'deep'))" 'L,M,S True True' 'the shortest window of the account, not a longer one and not one of some models'
$before = "$($BasePickUp.S) $($BasePickUp.M) $($BasePickUp.L)"
$DefaultPickUp.day.L = 0.02
Set-Windows ('{"day":{"seconds":86400,"pickUp":{"S":0.6,"M":0.4,"L":0.2}},"week":{"seconds":604800}}' | ConvertFrom-Json)
Assert-Same "$((Get-PickUp $null 'day').L) $($null -eq (Get-PickUp $null 'week'))" '0.2 True' 'the provider''s own limits stay'
Assert-Same "$($BasePickUp.S) $($BasePickUp.M) $($BasePickUp.L)" $before 'a window''s limits are a copy: the base''s table is not changed'
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/bare') 'bare' $null)
Assert-Same (Get-ReadingKey @{ month = @{ used = 0.5; resetsAt = 9 } }) '0.5@9||' 'a reading of one window'
# No provider: no window, so every ticket fits and nothing is kept.
Set-Provider $null
Assert-Same "$($WindowSeconds.Count) $(Get-Fit 'L' @{}) $(Get-Reserve 0.5 $day)" '0 True 0' 'no provider'

'ok'
