# Checks budget.ps1's arithmetic: powershell -NoProfile -File budget.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'budget.ps1')

function Assert-Near([double] $actual, [double] $expected, [string] $what) {
    if ([math]::Abs($actual - $expected) -gt 1e-9) {
        throw "${what}: expected $expected, got $actual"
    }
}

$day = 86400
$week = $WindowSeconds.seven_day

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
Assert-Near (Get-Ceiling 0.0 'five_hour') 0.98 '5-hour ceiling with no human use'
Assert-Near (Get-Ceiling 0.0 'seven_day') 1.0 'weekly ceiling with no human use: the whole week'
Assert-Near (Get-Ceiling 0.0 'five_hour' 0.8) 0.8 'the stop line of the account'
Assert-Near (Get-Ceiling 0.3 'seven_day' 0.9) 0.6 'the reserve is an offset below the stop line'
Assert-Near (Get-Ceiling 0.3 'seven_day' 0.2) 0.0 'a reserve bigger than the stop line leaves the workers nothing'

# Pace: the same room is more urgent the sooner it resets.
if ((Get-Pace 0.2 $day) -le (Get-Pace 0.9 (5 * $day))) {
    throw 'a fifth of the week resetting tomorrow should outrank nine tenths resetting in five days'
}

Assert-Near (Get-PlanSize 'default_claude_ai') 1.0 'Pro'
Assert-Near (Get-PlanSize 'default_claude_max_5x') 5.0 'Max 5x'
Assert-Near (Get-PlanSize 'default_claude_max_20x') 20.0 'Max 20x'

# Fit: an M (30 % of 5 hours) with too little room starts and pauses at the workers' ceiling, on any account, unless
# less than the least start room is left; nothing pending and room enough runs it whole.
function Assert-Same($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}
# The pick-up limits: an account's own over the default, per window and size.
$set = '{"five_hour":{"L":0.4}}' | ConvertFrom-Json
Assert-Same (Get-PickUp $set 'five_hour').L 0.4 'the pick-up limit of the account'
Assert-Same (Get-PickUp $set 'five_hour').M $DefaultPickUp.five_hour.M 'the default pick-up limit of another size'
Assert-Same (Get-PickUp $set 'seven_day') $null 'the week has no pick-up limits'
# A ticket is taken while the 5-hour window is under its size's pick-up limit and both windows are under the ceiling.
$limits = @{ S = 0.9; M = 0.75; L = 0.5 }
$budget = { param($five, $week, $ceiling) @{ five_hour = @{ used = $five; ceiling = 0.98; pickUp = $limits }
    seven_day = @{ used = $week; ceiling = $ceiling; pickUp = $null } } }
Assert-Same (Get-Fit 'L' (& $budget 0.49 0.2 1.0)) $true 'an L under its limit'
Assert-Same (Get-Fit 'L' (& $budget 0.5 0.2 1.0)) $false 'an L at its limit'
Assert-Same (Get-Fit 'M' (& $budget 0.5 0.2 1.0)) $true 'an M where an L is not taken'
Assert-Same (Get-Fit 'L' (& $budget 0.2 0.99 1.0)) $true 'the week holds no size back under its ceiling'
Assert-Same (Get-Fit 'S' (& $budget 0.2 1.0 1.0)) $false 'the week at its ceiling'
Assert-Same (Get-Fit 'S' (& $budget 0.5 0.6 0.55)) $false 'the week over a ceiling that a guard lowered'
$low = & $budget 0.6 0.2 1.0
$low.five_hour.ceiling = 0.55
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

# A saved usage reading keeps each window from the stored reading where that one is further on.
function New-Reading([string] $email, [double] $five, [long] $fiveReset, [double] $week, [long] $weekReset) {
    return @{ email = $email; five_hour = @{ used = $five; resetsAt = $fiveReset }; seven_day = @{ used = $week; resetsAt = $weekReset } }
}
$stored = (New-Reading 'a@x' 0.15 1000 0.58 9000) | ConvertTo-Json | ConvertFrom-Json
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.04 1000 0.57 9000)
Assert-Near $merged.five_hour.used 0.15 'an older, lower reading of the same window does not replace the stored one'
Assert-Near $merged.seven_day.used 0.58 'the same for the week'
Assert-Near (Merge-Usage $stored (New-Reading 'a@x' 0.17 1000 0.58 9000)).five_hour.used 0.17 'a higher reading replaces the stored one'
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.01 2000 0.59 9000)
Assert-Near $merged.five_hour.used 0.01 'a reading of a later window replaces the stored one'
Assert-Near $merged.seven_day.used 0.59 'each window is judged alone'
Assert-Near (Merge-Usage $stored (New-Reading 'a@x' 0.9 500 0.58 9000)).five_hour.used 0.15 'a reading from before the reset does not replace the stored one'
Assert-Near (Merge-Usage $stored (New-Reading 'b@x' 0.04 1000 0.1 9000)).five_hour.used 0.04 'another login replaces the stored reading'
Assert-Near (Merge-Usage $null (New-Reading 'a@x' 0.04 1000 0.1 9000)).five_hour.used 0.04 'nothing stored: the new reading'

# The Fable limit: only Fable runs carry its window, so a reading without it (an Opus run, a probe) keeps the stored
# one. From the stop line the account has no Fable until the reset.
$reading = New-Reading 'a@x' 0.1 1000 0.5 9000
$reading[$FableWindow] = @{ used = 1.02; resetsAt = 9000 }
$stored = $reading | ConvertTo-Json | ConvertFrom-Json
$merged = Merge-Usage $stored (New-Reading 'a@x' 0.2 1000 0.5 9000)
Assert-Near $merged[$FableWindow].used 1.02 'a reading without the Fable window keeps the stored one'
Assert-Same (Test-FableOut $merged 500) $true 'a used-up Fable window before its reset'
Assert-Same (Test-FableOut $merged 9000) $false 'the same window after its reset'
Assert-Same (Test-FableOut (@{ $FableWindow = @{ used = 0.97; resetsAt = 9000 } }) 500) $false 'a Fable window under the stop line'
Assert-Same (Test-FableOut (New-Reading 'a@x' 0.2 1000 0.5 9000) 500) $false 'no Fable window: Fable runs'
Assert-Same (Test-FableOut $null 500) $false 'no reading: Fable runs'
# The account's own stop line, else the default.
$fable = @{ $FableWindow = @{ used = 0.9; resetsAt = 9000 } }
Assert-Same (Test-FableOut $fable 500 0.85) $true 'over the account''s own stop line'
Assert-Same (Test-FableOut $fable 500 0.95) $false 'under the account''s own stop line'
Assert-Same (Test-FableOut $fable 500 $null) $false 'no stop line of its own: the default'
# The two Fable lines: the defaults; the account's own; the design line never above the stop line.
$lines = Get-FableLines $null $null
Assert-Same "$($lines.stop) $($lines.design)" '0.98 0.9' 'the default stop and design lines'
$own = '{"stopAt":{"seven_day_overage_included":0.95},"pickUp":{"seven_day_overage_included":{"design":0.8}}}' | ConvertFrom-Json
$lines = Get-FableLines $own.stopAt $own.pickUp
Assert-Same "$($lines.stop) $($lines.design)" '0.95 0.8' 'the account''s own lines'
$own = '{"stopAt":{"seven_day_overage_included":0.85}}' | ConvertFrom-Json
Assert-Same "$((Get-FableLines $own.stopAt $null).design)" '0.85' 'a stop line under the design line takes it down'
Assert-Same ((@((Get-PickUp $null 'five_hour').Keys) | Sort-Object) -join ',') 'L,M,S' 'the 5-hour window keeps its three sizes'

# Each window has its own read time, which the queue app shows. A kept window takes the new reading's time: a reading
# of the same Fable window a little lower (whole per cent) read it all the same.
$reading = New-Reading 'a@x' 0.1 1000 0.5 9000
$reading.at = 100
$reading[$FableWindow] = @{ used = 0.5; resetsAt = 9000; at = 100 }
$stored = $reading | ConvertTo-Json | ConvertFrom-Json
$new = New-Reading 'a@x' 0.2 1000 0.5 9000
$new.at = 5000
$new[$FableWindow] = @{ used = 0.49; resetsAt = 9000; at = 5000 }
$merged = Merge-Usage $stored $new
Assert-Near $merged[$FableWindow].used 0.5 'a lower reading of the same Fable window keeps the share'
Assert-Same ([long]$merged[$FableWindow].at) 5000 'and takes the new read time'
$new = New-Reading 'a@x' 0.2 1000 0.5 9000
$new.at = 5000
Assert-Same ([long](Merge-Usage $stored $new)[$FableWindow].at) 100 'a reading without the Fable window keeps its old read time'

# Get-Advisor (docs/QUEUE.md, Models): the Fable advisor for medium, high and review runs (review: a project's own
# complexity) on another model, while the account has Fable; none for low, for design (Fable's own run) and at the Fable limit.
$advisor = '{"model":"claude-fable-5-2","complexities":["medium","high","review"]}' | ConvertFrom-Json
Assert-Same (Get-Advisor $advisor 'high' 'claude-opus-5-5' $true) 'claude-fable-5-2' 'a high run on Opus'
Assert-Same (Get-Advisor $advisor '' 'claude-opus-5-5' $true) 'claude-fable-5-2' 'no label counts as medium'
Assert-Same (Get-Advisor $advisor 'review' 'claude-opus-5-5' $true) 'claude-fable-5-2' 'a review run'
Assert-Same (Get-Advisor $advisor 'low' 'claude-opus-5-5' $true) '' 'a low run has none'
Assert-Same (Get-Advisor $advisor 'design' 'claude-fable-5-2' $true) '' 'a design run has none'
Assert-Same (Get-Advisor $advisor 'design' 'claude-opus-5-5' $true) '' 'nor its rest on Opus after the Fable limit'
Assert-Same (Get-Advisor $advisor 'high' 'claude-fable-5-2' $true) '' 'a run forced onto the advisor''s model has none'
Assert-Same (Get-Advisor $advisor 'high' 'claude-opus-5-5' $false) '' 'none while the account has no Fable'
Assert-Same (Get-Advisor $null 'high' 'claude-opus-5-5' $true) '' 'no advisor in models.json'

# Get-FallbackEffort: a higher effort only where the complexity has a fallback and the advisor is not there now.
$advisor = '{"model":"claude-fable-5-2","complexities":["medium","high","review"],"fallback":{"review":"xhigh"}}' | ConvertFrom-Json
Assert-Same (Get-FallbackEffort $advisor 'review' 'claude-opus-5-5' 'high' $false) 'xhigh' 'a review run without the advisor'
Assert-Same (Get-FallbackEffort $advisor 'review' 'claude-opus-5-5' 'high' $true) 'high' 'a review run with the advisor'
Assert-Same (Get-FallbackEffort $advisor 'medium' 'claude-opus-5-5' 'high' $false) 'high' 'no fallback for medium'
Assert-Same (Get-FallbackEffort $advisor 'low' 'claude-opus-5-5' 'medium' $false) 'medium' 'low has no advisor to make up for'
Assert-Same (Get-FallbackEffort $advisor 'design' 'claude-fable-5-2' 'high' $false) 'high' 'nor design'
Assert-Same (Get-FallbackEffort $null 'review' 'claude-opus-5-5' 'high' $false) 'high' 'no advisor in models.json'

# Get-Refusal: why a run that ended with an error is not its ticket's failure, from its result line. The first three
# lines are real, cut to the fields the function reads: a subscription that ended at a run's first turn, the same
# after hours of work, and a session to resume that is gone.
function Result([string] $json) {
    return $json | ConvertFrom-Json
}
$past = 'Claude Code can''t use your Claude subscription, usually because a payment is past due - Pay or renew at https://claude.ai/settings/billing (if you just paid, try again shortly), or use an Anthropic API key instead'
Assert-Same (Get-Refusal (Result ('{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"terminal_reason":"api_error","result":"' + $past + '"}'))) 'subscription' 'a refused subscription at the first turn'
Assert-Same (Get-Refusal (Result ('{"type":"result","subtype":"success","is_error":true,"total_cost_usd":25.587907799999993,"result":"' + $past + '"}'))) 'subscription' 'a refused subscription that cuts a run off'
Assert-Same (Get-Refusal (Result '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"total_cost_usd":0}')) '' 'a session to resume that is gone is the failure of the run'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"Not logged in - Please run /login"}')) 'login' 'a folder with no login'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"OAuth token has expired"}')) 'login' 'a login lost while the run works'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"Fable 5.1 requires usage credits"}')) 'model' 'a model the plan does not include'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"You have hit your limit"}')) 'limit' 'the usage limit of the plan'
# The Fable limit: the first line is real, with the same api_error as a plan without the model.
$fable = 'You''ve reached your Fable limit. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.'
Assert-Same (Get-Refusal (Result ('{"subtype":"success","is_error":true,"total_cost_usd":15.48,"api_error":"model_requires_usage_credits","result":"' + $fable + '"}'))) 'fable' 'the Fable limit cuts a run off'
Assert-Same (Get-Refusal (Result ('{"subtype":"success","is_error":true,"total_cost_usd":0,"api_error":"model_requires_usage_credits","result":"' + $fable + '"}'))) 'fable' 'the Fable limit at the first turn'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"You''ve hit your Fable limit - resets 7pm"}')) 'fable' 'the other wording of the Fable limit'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"Fable limit reached - continuing on Opus 5.5 uses usage credits"}')) 'fable' 'the wording that ends limit reached'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"API Error: 529 Overloaded"}')) 'start' 'a run that did no work, for a cause the list does not know'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"API Error: 529 Overloaded"}')) '' 'the same error after work is the failure of the run'
Assert-Same (Get-Refusal (Result '{"subtype":"error_max_turns","is_error":true,"total_cost_usd":3.1,"result":"Reached the turn limit."}')) '' 'a failure of the run itself'
Assert-Same (Get-Refusal (Result '{"subtype":"success","is_error":false,"total_cost_usd":0,"result":"ok"}')) '' 'a probe that the account answered'
Assert-Same (Get-Refusal $null) '' 'no result line'
Assert-Same (($OutKinds | Sort-Object) -join ',') 'login,start,subscription' 'the kinds that put an account out'

'ok'
