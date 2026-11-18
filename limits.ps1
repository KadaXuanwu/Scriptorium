# The limits the owner sets on the workers' use of an account (docs/QUEUE.md, The budget): the stop line of each
# window, the share of the week kept under its stop line for each human use of the account, and the pick-up limit of
# each ticket size in the 5-hour window; and the ticket complexities the owner switched off. Pure functions,
# dot-sourced
# by budget.ps1 (the workers) and app/state.ps1 (the queue app), so both reckon the same ceiling. Checked by
# budget.test.ps1.

$WindowSeconds = @{ five_hour = 18000; seven_day = 604800 }
# The stop line: the share of a window where the workers stop, unless the account sets its own (`stopAt`, queue app,
# Accounts). The 5-hour window stays below 100 %: readings come in whole per cent and lag a run by up to 30 s. The week
# has no margin: a run that hits the weekly limit pauses until the reset, so none is lost.
$DefaultStopAt = @{ five_hour = 0.98; seven_day = 1.0 }
# The pick-up limits: the share of the 5-hour window from which the workers take no new ticket
# of a size, unless the account sets its own (`pickUp`, queue app, Accounts). A bigger ticket stops being taken
# earlier, so a run seldom reaches the stop line, where it ends at its next checkpoint. The week has none: there
# only the ceiling holds a new ticket back. Placeholders.
$DefaultPickUp = @{
    five_hour = @{ S = 0.90; M = 0.75; L = 0.50 }
}

# An account's pick-up limits in a window, @{ S; M; L } (the Fable week: @{ design }): its own setting ($pickUp), else
# the default. $null for a window that has no pick-up limits.
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

# The share of a whole week kept for each human use of an account, unless the settings say (`keep`, queue app,
# Accounts). Placeholders.
$DefaultKeep = @{ frontdesk = 0.10; personal = 0.15 }

# The share of a whole week that a human use's usage guard holds: the settings' value (0 keeps nothing), else the
# default.
# shortcut: a share of the account the use is on, not scaled by its plan; scale it when a human use moves to an
# account on another plan.
function Get-Keep([string] $use, $settings) {
    if ($settings -and $settings.keep -and $null -ne $settings.keep.$use) {
        return [double]$settings.keep.$use
    }
    return [double]$DefaultKeep[$use]
}

# What a usage guard keeps now: its share for the part of the week still to run (three days after a
# reset it keeps 4/7 of the share). The part for the days gone is free for the workers.
function Get-Reserve([double] $share, [long] $left) {
    $week = $WindowSeconds.seven_day
    return $share * [math]::Min([math]::Max($left, 0), $week) / $week
}

# The share of a window the workers may reach: the stop line ($stopAt, else the default) less the reserve on an
# account a human use is on too. The reserve is an offset below the line, so a lower line
# never uses it up.
function Get-Ceiling([double] $reserve, [string] $window, $stopAt = $null) {
    $stop = if ($stopAt) { [double]$stopAt } else { $DefaultStopAt[$window] }
    return [math]::Max(0.0, $stop - $reserve)
}

# The Fable limit (docs/QUEUE.md): the plan's weekly window of Fable alone, which the CLI's rate
# limit events name `seven_day_overage_included`. Only Fable runs carry it. It is not in $WindowSeconds: a full Fable
# window stops Fable, not the account. It has two lines, each the account's own (queue app,
# Accounts), else the default here, until the reset:
# - the design line (`pickUp.seven_day_overage_included.design`): from it no new Fable run (a `design` ticket) starts on
#   the account. Lower than the stop line, so the Fable runs in flight end under it and the advisor goes on all week.
#   Placeholder: two `design` runs moved the window about 2 %.
# - the stop line (`stopAt.seven_day_overage_included`): from it no new session gets the Fable advisor. Placeholder:
#   readings come in whole per cent, and one went from 0.99 to a refusal at 1.02.
$FableWindow = 'seven_day_overage_included'
$FableStopAt = 0.98
$DefaultPickUp[$FableWindow] = @{ design = 0.90 }

# Whether an account's Fable window is used up at $now, from its stored usage reading and a line ($stopAt).
function Test-FableOut($usage, [long] $now, $stopAt = $null) {
    $stop = if ($stopAt) { [double]$stopAt } else { $FableStopAt }
    $fable = if ($usage) { $usage.$FableWindow } else { $null }
    return [bool]($fable -and [long]$fable.resetsAt -gt $now -and [double]$fable.used -ge $stop)
}

# An account's two Fable lines from its settings entry's `stopAt` and `pickUp`: @{ stop; design }. The design line is
# never above the stop line.
function Get-FableLines($stopAt, $pickUp) {
    $stop = if ($stopAt -and $stopAt.$FableWindow) { [double]$stopAt.$FableWindow } else { $FableStopAt }
    return @{ stop = $stop; design = [math]::Min((Get-PickUp $pickUp $FableWindow).design, $stop) }
}

# The advisor of a run (docs/QUEUE.md, Models): models.json's `advisor.model` for a run of one of
# `advisor.complexities` on another model, while the account has the advisor's model ($hasAdvisor: not refused, not at
# the Fable limit); '' for none. Each advisor call reads the whole session again, uncached.
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
# models.json's `advisor.fallback` effort for that complexity, where a higher effort makes up for the
# advisor, else $effort unchanged. $advisor: project.ps1's Get-AdvisorRule.
function Get-FallbackEffort($advisor, [string] $complexity, [string] $model, [string] $effort, [bool] $hasAdvisor) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    if (-not $advisor -or $hasAdvisor -or $model -eq [string]$advisor.model -or @($advisor.complexities) -notcontains $complexity) {
        return $effort
    }
    $raised = if ($advisor.fallback) { [string]$advisor.fallback.$complexity } else { '' }
    return $(if ($raised) { $raised } else { $effort })
}

# Whether the owner switched a ticket complexity off for a worker (`workers.<id>.complexity`, queue app, the
# worker's card): the worker then takes no new ticket of it and leaves the answers and rebases
# of its PRs of it. A ticket already started goes on. A ticket without the label ('') counts as medium.
function Test-ComplexityOff([string] $complexity, $settings, [string] $worker) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    $own = if ($settings -and $settings.workers) { $settings.workers.$worker } else { $null }
    return [bool]($own -and $own.complexity -and $own.complexity.$complexity -eq $false)
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

# Why a run that ended with an error is not its ticket's failure, from its result line ($result: `is_error`, the
# error's text in `result`, `total_cost_usd` and `subtype`):
# - 'model': the plan does not include the model (only a start is refused for it).
# - 'subscription': the account's subscription is refused (a payment past due, a subscription that ended).
# - 'login': the account is signed out.
# - 'limit': the plan's usage limit.
# - 'fable': the account's Fable limit (The Fable limit): only Fable stops, the account's other models go on.
# - 'start': the run did no work (no cost) and its first request failed, for a cause the text does not name: the
#   service is down, a wrong model name. It catches a wording this list does not know. Before it, a refusal with a new
#   wording marked a ticket stuck every 75 seconds.
# - '': the run's own failure, or no error.
# 'subscription' and 'login' put the account out for every worker on it; so does 'start' when the account refuses a
# probe too, else it stops only the worker (worker.ps1, Get-Out). The texts are the CLI's own.
$OutKinds = @('subscription', 'login', 'start')
function Get-Refusal($result) {
    if (-not $result -or -not $result.is_error) {
        return ''
    }
    $text = [string]$result.result
    $noWork = [double]$result.total_cost_usd -eq 0
    # First: one wording ends "limit reached", and its api_error is the same as a plan without the model's.
    if ($text -match 'Fable limit') {
        return 'fable'
    }
    if ($noWork -and $text -match 'requires usage credits|not available|no access|access to') {
        return 'model'
    }
    if ($text -match 'Claude subscription|past due|settings/billing|subscription access') {
        return 'subscription'
    }
    if ($text -match 'authenticat|OAuth|not logged in|/login') {
        return 'login'
    }
    if ($text -match 'usage limit|rate limit|limit reached|hit your limit') {
        return 'limit'
    }
    # A run that ended before its first request (a session to resume that is gone, a wrong argument) is its own
    # failure: its `subtype` is not 'success'.
    return $(if ($noWork -and $result.subtype -eq 'success') { 'start' } else { '' })
}

# Whether the workers take a new ticket of this size on an account: in both windows its usage is under the ceiling,
# and under the size's pick-up limit where the window has them. $budget: per window @{ used; ceiling; pickUp }, with
# pickUp = @{ S; M; L } or $null.
function Get-Fit([string] $size, $budget) {
    foreach ($window in $WindowSeconds.Keys) {
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
