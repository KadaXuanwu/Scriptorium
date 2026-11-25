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
# The pick-up limits of the account's shortest window when the provider gives that window none, so every provider
# that reads its usage has them. Placeholders: what a ticket takes of a window depends on the plan.
$BasePickUp = @{ S = 0.90; M = 0.75; L = 0.50 }
# The window that keeps room for the human uses of an account (Get-Reserve), '' for none.
$KeepWindow = ''
# The shortest and the longest window of the whole account, '' with none (budget.ps1 and worker.ps1, the dispatcher).
$ShortWindow = ''
$LongWindow = ''

# Reads the provider's windows into the tables above. Each window: `seconds`, and where it has them `title`, `stopAt`
# (else 1), `pickUp` (@{ S; M; L } for sizes; the shortest window of the whole account has $BasePickUp without it),
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
    if ($script:ShortWindow -and -not $script:DefaultPickUp.ContainsKey($script:ShortWindow)) {
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
