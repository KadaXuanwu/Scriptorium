# The limits the owner sets on the workers' use of an account (docs/QUEUE.md, The budget): the stop line of each
# window, the share kept under the stop line of one window for each human use of the account, and the pick-up limits
# of a window; and the ticket complexities the owner switched off. The windows are the provider's (docs/PLUGINS.md, A
# provider). Pure functions, dot-sourced by budget.ps1 (the workers) and app/state.ps1 (the queue app), so both reckon
# the same ceiling. Checked by budget.test.ps1.

# The provider's windows (its models.json, `windows`), as Set-Windows reads them. None before it, and none for a
# provider that has no usage reading: its workers run until the plan refuses.
# The windows of the whole account, shortest first: each one's length in seconds.
$WindowSeconds = [ordered]@{}
# The windows of some models only: each one's @{ models (a wildcard of model names); after (the pick a job goes on
# with when the window is used up, or '') }. One that is used up stops its models, not the account.
$ModelWindows = [ordered]@{}
# Every window's name on the page.
$WindowTitles = @{}
# The stop line: the share of a window where the workers stop, unless the account sets its own (`stopAt`, queue app,
# Accounts). In a window of some models: the share from which no run gets one of them as its advisor.
$DefaultStopAt = @{}
# The pick-up limits: the share of a window from which the workers take no new ticket of a size, unless the account
# sets its own (`pickUp`, queue app, Accounts). A bigger ticket stops being taken earlier, so a run seldom reaches the
# stop line, where it ends at its next checkpoint. A window of some models has one under a name of its own: from it no
# new run starts on its models. A window with none holds a new ticket back only at its ceiling.
$DefaultPickUp = @{}
# The pick-up limits of the account's shortest window when the provider gives that window none and the account has a
# longer one: an account with one window holds a new ticket back only at its ceiling. Placeholders: what a ticket takes
# of a window depends on the plan.
$BasePickUp = @{ S = 0.90; M = 0.75; L = 0.50 }
# The window that keeps room for the human uses of an account (Get-Reserve), '' for none.
$KeepWindow = ''
# The shortest and the longest window of the whole account, '' with none (budget.ps1 and worker.ps1, the dispatcher).
$ShortWindow = ''
$LongWindow = ''

# Reads the provider's windows into the tables above. Each window: `seconds`, and where it has them `title`, `stopAt`
# (else 1), `pickUp` (@{ S; M; L } for sizes; without it the shortest window of the whole account has $BasePickUp, when it is not the
# only one),
# `keep` (it holds the kept share), `models` and `after`.
function Set-Windows($windows) {
    $script:WindowSeconds = [ordered]@{}
    $script:ModelWindows = [ordered]@{}
    $script:WindowTitles = @{}
    $script:DefaultStopAt = @{}
    $script:DefaultPickUp = @{}
    $script:KeepWindow = ''
    $entries = @(if ($windows) { $windows.PSObject.Properties | Sort-Object { [long]$_.Value.seconds } })
    foreach ($entry in $entries) {
        $name = $entry.Name
        $window = $entry.Value
        $script:WindowTitles[$name] = if ($window.title) { [string]$window.title } else { $name }
        $script:DefaultStopAt[$name] = if ($null -ne $window.stopAt) { [double]$window.stopAt } else { 1.0 }
        if ($window.pickUp) {
            $limits = @{}
            foreach ($property in $window.pickUp.PSObject.Properties) {
                $limits[$property.Name] = [double]$property.Value
            }
            $script:DefaultPickUp[$name] = $limits
        }
        if ($window.models) {
            $script:ModelWindows[$name] = @{ models = [string]$window.models; after = [string]$window.after; seconds = [long]$window.seconds }
            continue
        }
        $script:WindowSeconds[$name] = [long]$window.seconds
        if ($window.keep -and -not $script:KeepWindow) {
            $script:KeepWindow = $name
        }
    }
    $names = @($script:WindowSeconds.Keys)
    $script:ShortWindow = if ($names.Count) { $names[0] } else { '' }
    $script:LongWindow = if ($names.Count) { $names[-1] } else { '' }
    if ($names.Count -gt 1 -and -not $script:DefaultPickUp.ContainsKey($script:ShortWindow)) {
        $script:DefaultPickUp[$script:ShortWindow] = $BasePickUp.Clone()
    }
}

# An account's pick-up limits in a window, @{ S; M; L } (a window of some models: its one limit): its own setting
# ($pickUp), else the default. $null for a window that has no pick-up limits.
function Get-PickUp($pickUp, [string] $window) {
    if (-not $DefaultPickUp.ContainsKey($window)) {
        return $null
    }
    $limits = @{}
    foreach ($size in @($DefaultPickUp[$window].Keys)) {
        $limits[$size] = if ($pickUp -and $pickUp.$window -and $null -ne $pickUp.$window.$size) {
            [double]$pickUp.$window.$size
        } else {
            $DefaultPickUp[$window][$size]
        }
    }
    return $limits
}

# The share of a whole window kept for each human use of an account, unless the settings say (`keep`, queue app,
# Accounts). Placeholders.
$DefaultKeep = @{ frontdesk = 0.10; personal = 0.15 }

# The share of the whole window that a human use's usage guard holds: the settings' value (0 keeps nothing), else the
# default.
# shortcut: a share of the account the use is on, not scaled by its plan; scale it when a human use moves to an
# account on another plan.
function Get-Keep([string] $use, $settings) {
    if ($settings -and $settings.keep -and $null -ne $settings.keep.$use) {
        return [double]$settings.keep.$use
    }
    return [double]$DefaultKeep[$use]
}

# What a usage guard keeps now: its share for the part of the window still to run (three days after the reset of a
# week it keeps 4/7 of the share). The part for the time gone is free for the workers. Nothing where no window keeps.
function Get-Reserve([double] $share, [long] $left) {
    if (-not $KeepWindow) {
        return 0.0
    }
    $whole = [long]$WindowSeconds[$KeepWindow]
    return $share * [math]::Min([math]::Max($left, 0), $whole) / $whole
}

# The share of a window the workers may reach: the stop line ($stopAt, else the default) less the reserve on an
# account a human use is on too. The reserve is an offset below the line, so a lower line
# never uses it up.
function Get-Ceiling([double] $reserve, [string] $window, $stopAt = $null) {
    $stop = if ($stopAt) { [double]$stopAt } else { [double]$DefaultStopAt[$window] }
    return [math]::Max(0.0, $stop - $reserve)
}

# The window of some models that covers $model ($ModelWindows), '' for a model that only the account's windows hold.
function Get-ModelWindow([string] $model) {
    if ($model) {
        foreach ($window in @($ModelWindows.Keys)) {
            if ($model -like $ModelWindows[$window].models) {
                return $window
            }
        }
    }
    return ''
}

# Whether a window of an account is used up at $now, from the account's stored usage reading and a line ($stopAt, else
# the window's stop line).
function Test-WindowOut($usage, [string] $window, [long] $now, $stopAt = $null) {
    $stop = if ($stopAt) { [double]$stopAt } else { [double]$DefaultStopAt[$window] }
    $reading = if ($usage -and $window) { $usage.$window } else { $null }
    return [bool]($reading -and [long]$reading.resetsAt -gt $now -and [double]$reading.used -ge $stop)
}

# An account's two lines in a window of some models (docs/QUEUE.md, A model's limit), from its settings entry's
# `stopAt` and `pickUp`, each its own, else the default: @{ stop; start }.
# - start (the window's pick-up limit): from it no new run starts on the window's models on the account. Lower than
#   the stop line, so the runs in flight end under it and the advisor goes on. The stop line where the window has none.
# - stop: from it no new session gets one of the window's models as its advisor.
# The start line is never above the stop line.
function Get-ModelLines([string] $window, $stopAt, $pickUp) {
    $stop = if ($stopAt -and $stopAt.$window) { [double]$stopAt.$window } else { [double]$DefaultStopAt[$window] }
    $start = $stop
    $limits = Get-PickUp $pickUp $window
    if ($limits) {
        $start = [math]::Min([double](@($limits.Values) | Measure-Object -Minimum).Minimum, $stop)
    }
    return @{ stop = $stop; start = $start }
}

# The advisor of a run (docs/QUEUE.md, Models): the rule's model (project.ps1, Get-AdvisorRule) for a run of one of
# `advisor.complexities` on another model, while the account has the advisor's model ($hasAdvisor: not refused, not at
# its window's stop line); '' for none, and with a provider that has no advisor.
function Get-Advisor($advisor, [string] $complexity, [string] $model, [bool] $hasAdvisor) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    if (-not $advisor -or -not $hasAdvisor -or $model -eq [string]$advisor.model -or @($advisor.complexities) -notcontains $complexity) {
        return ''
    }
    return [string]$advisor.model
}

# The effort of a run whose complexity has an advisor that the account cannot give now (docs/QUEUE.md, Models):
# the complexity's `advisorFallback` effort, where a higher effort makes up for the
# advisor, else $effort unchanged. $advisor: project.ps1's Get-AdvisorRule.
function Get-FallbackEffort($advisor, [string] $complexity, [string] $model, [string] $effort, [bool] $hasAdvisor) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    if (-not $advisor -or -not $advisor.model -or $hasAdvisor -or $model -eq [string]$advisor.model -or @($advisor.complexities) -notcontains $complexity) {
        return $effort
    }
    $raised = if ($advisor.fallback) { [string]$advisor.fallback.$complexity } else { '' }
    return $(if ($raised) { $raised } else { $effort })
}

# Whether the owner switched a ticket complexity off for a worker (`workers.<id>.complexity`, queue app, the
# worker's card): the worker then takes no new ticket of it and leaves the answers and rebases
# of its PRs of it. A ticket already started goes on. A ticket without the label ('') counts as medium.
# Never off for a passive worker (docs/QUEUE.md, A passive worker): the owner gave it every ticket it has.
function Test-ComplexityOff([string] $complexity, $settings, [string] $worker) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    $own = if ($settings -and $settings.workers) { $settings.workers.$worker } else { $null }
    return [bool]($own -and $own.passive -ne $true -and $own.complexity -and $own.complexity.$complexity -eq $false)
}

# How the worker script holds a run that ended with its job not done (worker.ps1, Suspend-Job): 'pause' (it ended at a
# checkpoint for the owner's pause), 'limit' (for the workers' limit) or none. Both keep the session, to resume it.
# A stop note that still stands goes first; then the limit note; then a stop note the owner withdrew (that run may
# have ended for it already). A stopped run of a disabled worker, and one that ended with an error or with no result
# (a hard stop), keeps nothing: its ticket starts fresh, here or on another worker.
function Get-Hold([bool] $limitNoted, [bool] $stopNoted, [bool] $stopStands, [bool] $clean, [bool] $enabled) {
    if ($stopStands) {
        return $(if ($clean -and $enabled) { 'pause' } else { $null })
    }
    if ($limitNoted) {
        return 'limit'
    }
    return $(if ($stopNoted -and $clean -and $enabled) { 'pause' } else { $null })
}

# Why a run that ended with an error is not its ticket's failure. The provider reads it from the run's log
# (docs/PLUGINS.md, A provider, ReadRun):
# - 'model': the plan does not include the model (only a start is refused for it).
# - 'subscription': the account's subscription is refused (a payment past due, a subscription that ended).
# - 'login': the account is signed out.
# - 'limit': the plan's usage limit.
# - 'window': the limit of a window of some models: only those stop, the account's other models go on.
# - 'start': the run did no work and its first request failed, for a cause the provider cannot name: the service is
#   down, a wrong model name. Before it, a refusal with a new wording marked a ticket stuck every 75 seconds.
# - '': the run's own failure, its cap, or no error.
# 'subscription' and 'login' put the account out for every worker on it; so does 'start' when the account refuses a
# probe too, else it stops only the worker (worker.ps1, Get-Out).
$OutKinds = @('subscription', 'login', 'start')

# What a run's end says (worker.ps1, Invoke-Worker), from what the provider read in its log ($read, docs/PLUGINS.md,
# ReadRun; @{} when it read nothing), its last usage reading ($usage, budget.ps1, ConvertTo-Reading; $null for none)
# and the held run it resumed ($paused, $null for a fresh one): @{ Session (to resume; a refused run that did no work
# keeps the held one's, but not at the plan's limit, which resumes the session the refusal named); Limited (the plan's
# limit); ModelRefused (the plan lacks the model); WindowOut (a window of some models whose limit the account reached,
# else ''); Refusal (a kind of $OutKinds, else ''); RefusalText; Capped (the run's cap); Clean (it ended with no
# error) }. A refusal under the plan's limit is the limit. The reading names a model window's limit too, for a run
# that ended with an error the provider could not name or with no result; a window that models.json does not name is
# the plan's limit.
function Get-RunEnd($read, $usage, $paused) {
    $end = @{
        Session = [string]$read.Session; Limited = [bool]($usage -and $usage.refused); ModelRefused = $false
        WindowOut = ''; Refusal = ''; RefusalText = [string]$read.Text; Capped = [bool]$read.Capped
        Clean = [bool]$read.Ended -and -not $read.Error
    }
    if ($read.Ended) {
        $kind = [string]$read.Kind
        if ($kind -and $kind -ne 'limit' -and -not $read.Worked) {
            $end.Session = if ($paused) { $paused.Session } else { '' }
        }
        if ($kind -eq 'model') {
            $end.ModelRefused = $true
        } elseif ($kind -eq 'limit') {
            $end.Limited = $true
        } elseif ($kind -eq 'window') {
            $end.WindowOut = [string]$read.Window
        } elseif ($kind -and -not $end.Limited) {
            $end.Refusal = $kind
        }
    }
    if ($usage -and $usage.modelRefused -and -not $end.Clean) {
        $end.WindowOut = [string]$usage.modelRefused
        $end.Refusal = ''
    }
    if ($end.WindowOut -and -not $ModelWindows.Contains($end.WindowOut)) {
        $end.WindowOut = ''
        $end.Limited = $true
    }
    return $end
}

# How the worker script keeps a run whose end ($end, Get-RunEnd) did not finish its job: 'freed' (it ended at the stop
# note of the owner's Now for another ticket: never held, its ticket is freed), 'limit' or 'pause' (Get-Hold), or $null.
# Read as if the job were not finished: the script drops the answer for a finished job (worker.ps1, Test-Finished),
# so it asks GitHub only when there is an answer. A refused, capped or limited run is never held here.
function Get-RunHold($end, [bool] $nowElsewhere, [bool] $limitNoted, [bool] $stopNoted, [bool] $stopStands, [bool] $enabled) {
    if ($stopNoted -and $nowElsewhere) {
        return 'freed'
    }
    if ($end.Limited -or $end.Refusal -or $end.ModelRefused -or $end.WindowOut -or $end.Capped) {
        return $null
    }
    return Get-Hold $limitNoted $stopNoted $stopStands $end.Clean $enabled
}

# What follows from a run's end ($end, Get-RunEnd) and its hold (Get-RunHold, $null for a finished job), for a job of
# $kind that resumed a held run or not ($resumed): @{ AtLimit (held at the workers' limit); Stopped (held for the
# owner's pause: only with a session); Freed; Partial (its history line is a part of a job); Compact (compact the
# session now: held at the limit, or for a pause whose stop note still stands, not one the owner withdrew, as that run
# resumes at once with its cache warm); Holds (a refused run is held for its account: one that did work, or a PR's
# job; a ticket that no run began goes back to the queue) }.
function Get-RunMarks($end, $hold, [bool] $resumed, [string] $kind, [bool] $stopStands) {
    $atLimit = $hold -eq 'limit'
    $stopped = $hold -eq 'pause' -and [bool]$end.Session
    $freed = $hold -eq 'freed'
    return @{
        AtLimit = $atLimit; Stopped = $stopped; Freed = $freed
        Partial = $end.Limited -or [bool]$end.WindowOut -or [bool]$end.Refusal -or $atLimit -or $stopped -or $freed -or $resumed -or $kind -ne 'ticket'
        Compact = [bool]$end.Session -and ($atLimit -or ($stopped -and $stopStands))
        Holds = [bool]$end.Session -or $kind -ne 'ticket'
    }
}

# What the worker script does with a job after its run (worker.ps1, the main loop), from the run's end ($end, what
# Invoke-Worker returns), the job's $kind, whether it resumed a held run ($resumed), the model the job's next run would
# start on ($next), whether the run handed the ticket on (`handoff.md`, $handedOff), the model after the window of
# $end.ModelOut ($after, '' for none), the probe's reply for a run that did not start ($reply, $null for none), the
# worker's count of such runs ($startFails), whether the owner stopped it (a stop note, a pause or a disable, $halted)
# and whether a stop note was written for the run ($stopNoted). @{ Action; Whose; Refusal; RefusalText; StartFails;
# LoggedOut; Judge }. Action, in this order:
# - 'next-model': the plan refused the model and the job has another candidate: it comes back on it at once.
# - 'handed-on': a ticket whose run found its decisions need the model it began on: back to the queue.
# - 'requeue-window': a ticket at a model window's limit that no run began, or with no model after: back to the queue.
# - 'go-on': at a model window's limit, a run that did work or a PR's job goes on with the model after.
# - 'retry-start': a run that did not start on an account that answers, the first time: the job comes back.
# - 'requeue-model': a ticket whose plan has none of its complexity's models: back to the queue.
# - 'suspend': held (Suspend-Job): the plan's limit, its account out, the workers' limit or the owner's pause.
# - 'not-started': a ticket no run began, on an account or worker that is out now.
# - 'freed': the owner's Now ended the run.
# - 'stopped': the owner stopped or disabled the worker, or the run ended by a hard stop: not a failure.
# - 'done': the run ended; Judge says whether its outcome is judged (Get-Outcome): not after a stop note the owner
#   withdrew, as that run may have ended for it.
# Whose is the record that a refusal writes (Get-Out): 'account' (it stops every worker on it), 'worker' (a start
# that failed twice on an account that answers: only this worker stops) or ''. Refusal and RefusalText are the
# probe's when it found the account out. LoggedOut: the run is held for that record.
function Get-RunAction($end, [string] $kind, [bool] $resumed, [string] $next, [bool] $handedOff, [string] $after, $reply,
    [int] $startFails, [bool] $halted, [bool] $stopNoted) {
    $act = @{ Action = ''; Whose = ''; Refusal = [string]$end.Refusal; RefusalText = [string]$end.RefusalText
        StartFails = $startFails; LoggedOut = $false; Judge = $false }
    if ($end.ModelRefused -and -not $resumed -and $next -ne $end.Model) {
        $act.Action = 'next-model'
        return $act
    }
    if ($kind -eq 'ticket' -and $handedOff) {
        $act.Action = 'handed-on'
        return $act
    }
    if ($end.ModelOut) {
        if ($kind -eq 'ticket' -and (-not $end.Session -or -not $after)) {
            $act.Action = 'requeue-window'
            return $act
        }
        if ($after) {
            $act.Action = 'go-on'
            return $act
        }
        # A PR's job, and no model to go on with: parked for the owner below.
    }
    if ($act.Refusal -in @('login', 'subscription')) {
        $act.Whose = 'account'
    } elseif ($act.Refusal -eq 'start') {
        if ($reply -and $reply.answered -and $OutKinds -contains $reply.kind) {
            $act.Whose = 'account'
            $act.Refusal = [string]$reply.kind
            $act.RefusalText = [string]$reply.text
        } elseif ($startFails -lt 1) {
            $act.StartFails = $startFails + 1
            $act.Action = 'retry-start'
            return $act
        } else {
            $act.Whose = 'worker'
        }
    } elseif ($end.ModelRefused -and $kind -eq 'ticket' -and -not $resumed) {
        $act.Action = 'requeue-model'
        return $act
    } elseif (-not $end.ModelRefused) {
        $act.StartFails = 0
    }
    if ($act.Whose) {
        $act.LoggedOut = [bool]$end.Holds
    }
    if ($end.Limited -or $act.LoggedOut -or $end.AtLimit -or $end.Stopped) {
        $act.Action = 'suspend'
    } elseif ($act.Whose) {
        $act.Action = 'not-started'
    } elseif ($end.Freed) {
        $act.Action = 'freed'
    } elseif ($halted) {
        $act.Action = 'stopped'
    } else {
        $act.Action = 'done'
        $act.Judge = -not $stopNoted
    }
    return $act
}

# A run must end its job: a job that did not ($finished false) is parked for the owner, so a failing ticket never
# loops (worker.ps1, Test-Outcome). $null for a finished job, else @{ Pr (the label goes on the job's PR, else on its
# ticket); Comment }. $cap: the cap that the run reached (project.ps1, Get-RunCap), else 0; the comment then names it.
function Get-Outcome([bool] $finished, [string] $kind, [double] $cap, [string] $log) {
    if ($finished) {
        return $null
    }
    $why = if ($cap) { "reached the cap of $cap for one run (runCap in scriptorium.json, else in the provider's models.json) and " } else { '' }
    if ($kind -ne 'ticket') {
        return @{ Pr = $true; Comment = "${why}stopped without finishing ($kind). Log: ``$log``" }
    }
    return @{ Pr = $false; Comment = "${why}stopped without a PR or a question. Log: ``$log``" }
}

# Whether the workers take a new ticket of this size on an account: in every window its usage is under the ceiling,
# and under the size's pick-up limit where the window has them. $budget: per window @{ used; ceiling; pickUp }, with
# pickUp = @{ S; M; L } or $null.
function Get-Fit([string] $size, $budget) {
    foreach ($window in @($WindowSeconds.Keys)) {
        if (-not $budget[$window]) {
            continue
        }
        $limit = $budget[$window].ceiling
        if ($budget[$window].pickUp) {
            $limit = [math]::Min($budget[$window].pickUp[$size], $limit)
        }
        if ($budget[$window].used -ge $limit) {
            return $false
        }
    }
    return $true
}

# The queue's order within a priority: a bigger ticket first, then the older one. A fresh window
# then goes to the big tickets, and the small ones fill what the pick-up limits leave. Lower sorts first.
function Get-SizeRank([string] $size) {
    switch ($size) {
        'L' { return 0 }
        'S' { return 2 }
    }
    return 1
}
