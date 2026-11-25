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

# The provider's windows (Set-Windows): the account's own shortest first, the one that keeps, the ones of some models.
Assert-Same "$(@($WindowSeconds.Keys) -join ',') $ShortWindow $LongWindow $KeepWindow $(@($ModelWindows.Keys) -join ',')" 'short,long short long long deep' 'the windows of the test provider'
Assert-Same "$(Get-ModelWindow 'deep-1')|$(Get-ModelWindow 'main-1')|$(Get-ModelWindow '')" 'deep||' 'the window that covers a model'
Assert-Same "$($ModelWindows.deep.after) $($WindowTitles.deep)" 'main-1@xhigh Deep week' 'a window''s model after it and its title'
# A provider with one window that neither keeps nor has pick-up limits: nothing is kept, a ticket of any size is taken
# under the ceiling, and no model has a window of its own.
Set-Provider (Import-Plugin (Join-Path $baseDir 'tests/bare') 'bare' $null)
Assert-Same "$(@($WindowSeconds.Keys) -join ',') $ShortWindow $LongWindow '$KeepWindow' $($ModelWindows.Count)" "month month month '' 0" 'one window'
Assert-Near (Get-Reserve 0.14 $day) 0.0 'no window keeps: no reserve'
Assert-Near (Get-Ceiling 0.0 'month') 1.0 'a window with no stop line of its own stops at the whole'
Assert-Same (Get-PickUp $null 'month') $null 'no pick-up limits'
Assert-Same "$(Get-Fit 'L' @{ month = @{ used = 0.99; ceiling = 1.0; pickUp = $null } }) $(Get-Fit 'S' @{ month = @{ used = 1.0; ceiling = 1.0; pickUp = $null } })" 'True False' 'only the ceiling holds a ticket back'
Assert-Same (Get-ReadingKey @{ month = @{ used = 0.5; resetsAt = 9 } }) '0.5@9||' 'a reading of one window'
# No provider: no window, so every ticket fits and nothing is kept.
Set-Provider $null
Assert-Same "$($WindowSeconds.Count) $(Get-Fit 'L' @{}) $(Get-Reserve 0.5 $day)" '0 True 0' 'no provider'

'ok'
