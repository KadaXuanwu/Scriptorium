# The queue app's snapshot (docs/APP.md): what the page shows, built from the queue files and the GitHub data the
# server fetched, the owner's choices turned into queue changes, and the notifications a change between two
# snapshots sends. Functions over their inputs (two read a run's log), dot-sourced by server.ps1, checked by
# app.test.ps1.

. (Join-Path $PSScriptRoot '../followup.ps1')
. (Join-Path $PSScriptRoot '../areas.ps1')
. (Join-Path $PSScriptRoot '../limits.ps1')
. (Join-Path $PSScriptRoot '../project.ps1')
. (Join-Path $PSScriptRoot '../plugins.ps1')

# A worker state older than this is a stopped script: idle ones refresh every poll (5 min), running ones every 30 s.
$StaleSeconds = 900

function Read-Json([string] $path) {
    if (-not $path -or -not (Test-Path $path)) {
        return $null
    }
    try {
        return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

# The helpers below loop with foreach, not a pipeline: the page's snapshot calls them thousands of times every few
# seconds, and a pipeline costs ten times as much in Windows PowerShell.
function Get-Names($item) {
    return @(foreach ($label in $item.labels) { $label.name })
}

# Whether this page serves an account's entry: its coding tool's provider is one of the script's (docs/QUEUE.md,
# Accounts; plugins.ps1, Get-AccountProvider). A project with no provider runs nothing, and its page shows every
# account.
function Test-KnownAccount($entry) {
    $known = Get-KnownProviders
    return [bool]($entry -and (-not $known.Count -or (Get-AccountProvider $entry $known)))
}

# The entry of account $name. Throws for a name the register doesn't have, and for an account of a coding tool with no
# plugin here: no provider of this page can read, sign in or sign out that login.
function Get-KnownAccount($settings, [string] $name) {
    $entry = if ($settings.accounts) { $settings.accounts.$name }
    if (-not $entry) {
        throw "no account $name"
    }
    if (-not (Test-KnownAccount $entry)) {
        throw "account $name is of a coding tool with no plugin here ($($entry.provider)): add its plugin to scriptorium.json and run setup"
    }
    return $entry
}

# The provider of a worker's view (its `provider`, the plugin's name) among the script's; $default for a view that
# names none, and while the script serves one provider. A loop: the snapshot asks for every worker of every ticket.
function Get-ViewProvider($view, $default) {
    if ($view.provider -and $script:Providers.Count -gt 1) {
        foreach ($plugin in $script:Providers) {
            if ($plugin.Name -eq $view.provider) {
                return $plugin
            }
        }
    }
    return $default
}

# Why a worker cannot go to an account of another coding tool now, '' when it can (the worker's card, its account):
# a run in flight, working or held, is a session of the tool it began on. $from, $to: its provider before and after
# the move.
function Get-ToolRefusal($from, $to, [bool] $inFlight) {
    if (-not $inFlight -or [string]$from.Name -eq [string]$to.Name) {
        return ''
    }
    return "it has a run in flight on $($from.Title -replace '^Scriptorium for ', ''): it can go to another coding tool's account when that run is done"
}

# The register after moving a worker to an account ('' for the command-line login: in no entry). The worker runs on
# that account's coding tool from its next job (plugins.ps1, Get-WorkerProvider). Throws for an account the register
# doesn't have, and for one of a coding tool with no plugin here. -Off: the worker goes away, so it only leaves every
# entry, which nothing refuses.
function Set-WorkerAccount($settings, [string] $worker, [string] $account, [switch] $Off) {
    $use = "worker:$worker"
    if ($Off) {
        $account = ''
    } elseif ($account) {
        [void](Get-KnownAccount $settings $account)
    }
    foreach ($property in $settings.accounts.PSObject.Properties) {
        $uses = @($property.Value.uses | Where-Object { $_ -and $_ -ne $use })
        if ($property.Name -eq $account) {
            $uses += $use
        }
        $property.Value | Add-Member -NotePropertyName uses -NotePropertyValue ([object[]]$uses) -Force
    }
    return $settings
}

# The register with worker $id added (a fresh entry, active, on $account: '' for the command-line login) or removed
# (no entry, in no account's uses). Throws for an account the register doesn't have, before it changes anything.
function Set-WorkerEntry($settings, [string] $id, [bool] $present, [string] $account = '') {
    $settings = Set-WorkerAccount $settings $id $account -Off:(-not $present)
    if ($settings.workers) {
        $settings.workers.PSObject.Properties.Remove($id)
    }
    if ($present) {
        (Get-WorkerSettings $settings $id) | Add-Member -NotePropertyName enabled -NotePropertyValue $true
    }
    return $settings
}

# Worker $id's entry in the settings (`workers.<id>`), made empty when it has none. Not Add-Member: it reads a name of
# digits as a member type and refuses it.
function Get-WorkerSettings($settings, [string] $id) {
    if (-not $settings.workers) {
        $settings | Add-Member -NotePropertyName workers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $settings.workers.$id) {
        $settings.workers.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty($id, [pscustomobject]@{})))
    }
    return $settings.workers.$id
}

# The register with worker $id's name on the page (`workers.<id>.name`), trimmed; '' takes it away (the page then
# shows "Worker <id>"). Only the page shows it: comments and pushes keep the number.
function Set-WorkerName($settings, [string] $id, [string] $name) {
    $name = $name.Trim()
    if ($name.Length -gt 30 -or $name -match '[\x00-\x1f]') {
        throw 'a name has at most 30 characters'
    }
    $entry = Get-WorkerSettings $settings $id
    $entry.PSObject.Properties.Remove('name')
    if ($name) {
        Set-JsonProperty $entry 'name' $name
    }
    return $settings
}

# The register with account $old named $new, in the same place in the list. Only the name changes: the queue's
# files and a held run know an account by its login folder (`configDir`), which stays.
function Rename-Account($settings, [string] $old, [string] $new) {
    if ($new -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
        throw 'the name takes lower-case letters, digits and dashes'
    }
    if (-not ($settings.accounts -and $settings.accounts.PSObject.Properties[$old])) {
        throw "no account $old"
    }
    if ($new -ne $old -and $settings.accounts.PSObject.Properties[$new]) {
        throw "an account named $new exists"
    }
    $accounts = [pscustomobject]@{}
    foreach ($property in $settings.accounts.PSObject.Properties) {
        Set-JsonProperty $accounts $(if ($property.Name -eq $old) { $new } else { $property.Name }) $property.Value
    }
    $settings.accounts = $accounts
    # Its card keeps its place (Set-CardOrder).
    if ($settings.order -and $settings.order.accounts) {
        $settings.order.accounts = [object[]]@($settings.order.accounts | ForEach-Object { if ($_ -eq $old) { $new } else { $_ } })
    }
    return $settings
}

# The register with the owner's order of the worker or account cards (`order.workers`, `order.accounts`): the PC's,
# so every device shows the same. A worker is "<project>|<id>", an account its name.
function Set-CardOrder($settings, [string] $kind, $list) {
    if (@('workers', 'accounts') -notcontains $kind) {
        throw "no cards of kind $kind"
    }
    $list = @($list | ForEach-Object { [string]$_ })
    if ($list.Count -gt 100 -or @($list | Where-Object { $_.Length -gt 100 -or $_ -match '[\x00-\x1f]' }).Count) {
        throw 'an order holds at most 100 cards'
    }
    if (-not $settings.order) {
        Set-JsonProperty $settings 'order' ([pscustomobject]@{})
    }
    Set-JsonProperty $settings.order $kind ([object[]]$list)
    return $settings
}

# The login folder of a new account named $name: ~/.<provider>-<name>, with the provider plugin's name. Throws when an
# account has that folder: a renamed account keeps the folder of its old name, and a second sign-in there would replace
# its login.
function Get-NewAccountDir($settings, [string] $name, [string] $homeDir) {
    # The provider that is set: the server sets the new account's coding tool first.
    $prefix = if ($script:Provider) { $script:Provider.Name } else { 'account' }
    $dir = "$($homeDir.Replace('\', '/'))/.$prefix-$name"
    $holder = $settings.accounts.PSObject.Properties | Where-Object { $_.Value.configDir -and (Get-FolderKey ([string]$_.Value.configDir)) -eq (Get-FolderKey $dir) } |
        Select-Object -First 1
    if ($holder) {
        throw "the folder .$prefix-$name is the folder of account $($holder.Name): pick another name"
    }
    return $dir
}

# The settings' entry of a complexity (`complexities.<name>`), made empty when it has none.
function Get-ComplexitySettings($settings, [string] $name) {
    if (-not $settings.complexities) {
        $settings | Add-Member -NotePropertyName complexities -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $settings.complexities.$name) {
        $settings.complexities | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $settings.complexities.$name
}

# The owner's pick of a complexity's model and effort on this PC (docs/QUEUE.md, Settings,
# `complexities.<name>.model`), as `model@effort`. Only an effort of models.json's list, and a model of its list or
# the base's own (a project may name another in scriptorium.json): a coding tool may take an effort it does not know
# without a word. The base's own pick is not saved, so the PC follows models.json and scriptorium.json again. $complexities:
# the list with these settings (project.ps1, Get-Complexities).
function Set-ComplexityModel($settings, $models, $complexities, [string] $name, [string] $model, [string] $effort) {
    $entry = $complexities | Where-Object { $_.name -ceq $name } | Select-Object -First 1
    if (-not $entry) {
        throw "no complexity $name"
    }
    $base = Split-Pick $models $entry.base
    if (@($models.models.PSObject.Properties | ForEach-Object { $_.Name }) + $base.model -cnotcontains $model -or @($models.efforts) -cnotcontains $effort) {
        throw "models.json lists no model '$model' or no effort '$effort'"
    }
    if ($base.model -ne $model -or $base.effort -ne $effort) {
        Get-ComplexitySettings $settings $name | Add-Member -NotePropertyName model -NotePropertyValue "$model@$effort" -Force
    } elseif ($settings.complexities -and $settings.complexities.$name) {
        $settings.complexities.$name.PSObject.Properties.Remove('model')
    }
    return $settings
}

# The owner's advisor switch of a complexity and its effort without the advisor (docs/QUEUE.md, Settings,
# `complexities.<name>.advisor`, `.advisorFallback`): $fallback is an effort of models.json's list, or '' for the
# same effort. Each value equal to the files' (`baseAdvisor`, `baseFallback`) is not saved. $complexities: the list
# with these settings (project.ps1, Get-Complexities).
function Set-ComplexityAdvisor($settings, $models, $complexities, [string] $name, [bool] $on, [string] $fallback) {
    $entry = $complexities | Where-Object { $_.name -ceq $name } | Select-Object -First 1
    if (-not $entry) {
        throw "no complexity $name"
    }
    if ($fallback -and @($models.efforts) -cnotcontains $fallback) {
        throw "models.json lists no effort '$fallback'"
    }
    $picks = @{ advisor = $on; advisorFallback = $fallback }
    $bases = @{ advisor = [bool]$entry.baseAdvisor; advisorFallback = [string]$entry.baseFallback }
    foreach ($key in @('advisor', 'advisorFallback')) {
        if ($picks[$key] -ne $bases[$key]) {
            $own = Get-ComplexitySettings $settings $name
            $own | Add-Member -NotePropertyName $key -NotePropertyValue $picks[$key] -Force
        } elseif ($settings.complexities -and $settings.complexities.$name) {
            $settings.complexities.$name.PSObject.Properties.Remove($key)
        }
    }
    return $settings
}

# The owner's pick of the advisor's model for this project (docs/QUEUE.md, Settings, `advisor.model`): a model of
# models.json's list. models.json's own `advisor.model` is not saved.
function Set-AdvisorModel($settings, $models, [string] $model) {
    if (@($models.models.PSObject.Properties | ForEach-Object { $_.Name }) -cnotcontains $model) {
        throw "models.json lists no model '$model'"
    }
    if ($model -ne [string]$models.advisor.model) {
        if (-not $settings.advisor) {
            Set-JsonProperty $settings 'advisor' ([pscustomobject]@{})
        }
        Set-JsonProperty $settings.advisor 'model' $model
    } elseif ($settings.advisor) {
        $settings.advisor.PSObject.Properties.Remove('model')
    }
    return $settings
}

# The project's colour on the page (docs/QUEUE.md, Settings, `color`): `#rrggbb`, saved in lower case; '' removes it,
# and the page gives the project a colour from its name again.
function Set-ProjectColor($settings, [string] $value) {
    if (-not $value) {
        $settings.PSObject.Properties.Remove('color')
        return $settings
    }
    if ($value -notmatch '^#[0-9a-fA-F]{6}\z') {
        throw "'$value' is no colour: write #rrggbb"
    }
    Set-JsonProperty $settings 'color' $value.ToLowerInvariant()
    return $settings
}

# Why worker $id cannot be removed now, '' when it can (the queue app's Remove). Only a disabled worker with no run in
# flight: its ticket is free already. Never while its setup runs. $state: what its script wrote; $alive: its script
# still refreshes it. A dead script's run waits for nothing: the server ends what is left of it.
function Get-RemoveRefusal($state, [bool] $enabled, [bool] $settingUp, [bool] $alive = $true) {
    if ($settingUp) {
        return 'its setup still runs'
    }
    if ($enabled) {
        return 'disable it first'
    }
    if ($alive -and ($state.state -eq 'running' -or ($state.ticket -and $state.resetsAt))) {
        return 'its run has not ended yet'
    }
    return ''
}

# Why worker $id cannot move to another project now, '' when it can (the queue app's project choice). $state: what its
# script wrote in its old project; $fresh: its script refreshed it within $StaleSeconds; $held: its copy holds a run
# held for a limit or a pause (`.queue/paused.json`); $disableMarked: the old control disables it after its ticket.
# A held run and its ticket stay with the old project: Disabled drops the run and gives the ticket back to the queue.
function Get-MoveRefusal($state, [bool] $fresh, [bool] $held, [bool] $disableMarked) {
    if ($state.state -eq 'setup') {
        return 'its setup still runs'
    }
    if ($fresh -and $state.state -eq 'running') {
        return 'it works on a ticket: pause or disable it, and move it when its run has ended'
    }
    if ($held -or ($state.ticket -and $state.resetsAt) -or $disableMarked) {
        return 'it holds a ticket: disable it first, then move it'
    }
    return ''
}

# The status that worker $id keeps when it moves to another project: 'disabled' while the PC's settings disable it,
# else 'paused' while its old project's control has a mode for it (Get-Mode), else 'active'.
function Get-CarriedStatus($settings, $control, [string] $id) {
    if ($settings -and $settings.workers -and $settings.workers.$id -and $settings.workers.$id.enabled -eq $false) {
        return 'disabled'
    }
    if (Get-Mode $control $id) {
        return 'paused'
    }
    return 'active'
}

# The control's entry for one worker: 'drain' (no new job, its run finishes), 'stop' (no new job, its run wraps up at
# its next checkpoint) or $null.
function Get-Mode($control, [string] $worker) {
    $mode = if ($control -and $control.workers) { $control.workers.$worker } else { $null }
    if ($mode -eq 'drain' -or $mode -eq 'stop') {
        return $mode
    }
    return $null
}

# The owner picks a status for a worker (docs/APP.md, Worker status): 'active', 'paused' or 'disabled', and for
# the last two how its run ends: 'now', 'checkpoint' or 'finish' (it finishes its ticket). $inFlight: the worker has a
# run, working or waiting for a limit reset. Returns the new control, the worker's `enabled` and whether to end the
# run's process now. A disable after the ticket is a drain with a mark; Get-DueDisables finds it when the run ended.
function Set-WorkerStatus($control, [string] $worker, [string] $to, [string] $how, [bool] $inFlight) {
    $modes = @{}
    $disable = @{}
    if ($control -and $control.workers) {
        $control.workers.PSObject.Properties | Where-Object { $_.Value -in @('drain', 'stop') } | ForEach-Object { $modes[$_.Name] = $_.Value }
    }
    if ($control -and $control.disable) {
        $control.disable.PSObject.Properties | ForEach-Object { $disable[$_.Name] = $true }
    }
    $modes.Remove($worker)
    $disable.Remove($worker)
    $enabled = $true
    $kill = $false
    $finish = $how -eq 'finish' -and $inFlight
    switch ($to) {
        'active' { }
        'paused' {
            $modes[$worker] = if ($finish) { 'drain' } else { 'stop' }
            $kill = $how -eq 'now' -and $inFlight
        }
        'disabled' {
            if ($finish) {
                $modes[$worker] = 'drain'
                $disable[$worker] = $true
            } else {
                # Also a stop entry. The worker script reads `enabled` and the control at two moments of its loop: with
                # `enabled` alone, a switch from paused to disabled between the two showed it neither, and it took a
                # ticket.
                $modes[$worker] = 'stop'
                $enabled = $false
                $kill = $how -eq 'now' -and $inFlight
            }
        }
        default { throw "unknown status $to" }
    }
    return @{ control = @{ workers = $modes; disable = $disable }; enabled = $enabled; kill = $kill }
}

# The workers marked to disable after their ticket whose run has ended: the server disables them now.
# $states: worker id -> the state its script wrote.
function Get-DueDisables($control, $states) {
    if (-not $control -or -not $control.disable) {
        return @()
    }
    return @($control.disable.PSObject.Properties | ForEach-Object { $_.Name } |
        Where-Object { $states[$_] -notin @('running', 'paused') })
}

# A worker's status as the page shows it: 'active' (takes tickets when it can), 'paused' (takes none, keeps its
# ticket) or 'disabled' (takes none, its ticket is free). While a run still works toward a pause or a disable, the
# status stays active and `pending` names the target and how the run ends. $raw: the state its script wrote; a script
# sees a change at its next poll, so the control and `enabled` decide wherever no run is in flight.
function Get-WorkerStatus([string] $raw, $mode, [bool] $enabled, [bool] $disableMarked) {
    if (-not $enabled) {
        if ($raw -eq 'running') {
            return @{ status = 'active'; pending = @{ to = 'disabled'; how = 'checkpoint' } }
        }
        return @{ status = 'disabled'; pending = $null }
    }
    if ($mode) {
        # A drain lets a run that waits for its limit reset resume and finish; a stop holds it.
        if ($raw -eq 'running' -or ($raw -eq 'paused' -and $mode -eq 'drain')) {
            return @{ status = 'active'; pending = @{ to = $(if ($disableMarked) { 'disabled' } else { 'paused' })
                how = $(if ($mode -eq 'drain') { 'finish' } else { 'checkpoint' }) } }
        }
        return @{ status = 'paused'; pending = $null }
    }
    return @{ status = 'active'; pending = $null }
}

# What a run did at one line of its log, as the provider reads it (docs/PLUGINS.md, ReadStep): its words or the tool
# it called, in one line of at most 160 characters. $null for a line that is no step, and with a provider that reads
# none.
function Get-StepText([string] $line) {
    try {
        $text = [string](Invoke-Provider 'ReadStep' @{ Line = $line })
    } catch {
        return $null
    }
    $text = ($text -replace '\s+', ' ').Trim()
    if (-not $text) {
        return $null
    }
    if ($text.Length -gt 160) {
        $text = $text.Substring(0, 157) + '...'
    }
    return $text
}

# The last lines of a log, read from its tail without disturbing the run writing it; none when there is no file.
function Read-LogTail([string] $log) {
    if (-not $log -or -not (Test-Path $log)) {
        return @()
    }
    $stream = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {
        $take = [math]::Min($stream.Length, 262144)
        [void]$stream.Seek(-$take, 'End')
        $bytes = New-Object byte[] $take
        [void]$stream.Read($bytes, 0, $take)
    } finally {
        $stream.Dispose()
    }
    return @([System.Text.Encoding]::UTF8.GetString($bytes) -split "`n")
}

# The last $count steps of a log, newest last.
function Get-Steps([string] $log, [int] $count = 1) {
    $lines = @(Read-LogTail $log)
    $steps = New-Object System.Collections.ArrayList
    for ($i = $lines.Count - 1; $i -ge 0 -and $steps.Count -lt $count; $i--) {
        $text = Get-StepText $lines[$i]
        if ($text) {
            [void]$steps.Insert(0, $text)
        }
    }
    return @($steps)
}

function Limit-Text([string] $text, [int] $length) {
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $length) {
        return $text.Substring(0, $length - 3) + '...'
    }
    return $text
}

# Why a run ended with no PR and no question, in one line from its log, no model: the error its end names, else its
# last words, else (no end: the process died) its last step. '' without a log. The provider reads the end
# (docs/PLUGINS.md, ReadEnd).
function Get-StuckReason([string] $log) {
    $lines = @(Read-LogTail $log)
    if ($lines.Count -eq 0) {
        return ''
    }
    $end = $null
    try {
        $end = Invoke-Provider 'ReadEnd' @{ Text = ($lines -join "`n") }
    } catch {
    }
    if ($end) {
        if ($end.Error) {
            return Limit-Text "The run failed$(if ($end.Detail) { " ($($end.Detail))" }): $($end.Text)" 300
        }
        return Limit-Text "The run ended by itself. Its last words: $($end.Text)" 300
    }
    $step = @(Get-Steps $log 1)[0]
    return Limit-Text "The run's process ended with no result (a crash or a kill).$(if ($step) { " Its last step: $step" })" 300
}

# The typical length in seconds (or, with $field 'cost', the typical cost in dollars) of a whole-ticket run of this
# size on this model: the median of finished ones, else of this size on any model; $null without history. Lines
# without the wall flag hold the last turn only: left out.
function Get-Typical($runs, [string] $size, [string] $model, [string] $field = 'duration') {
    foreach ($sameModel in @($true, $false)) {
        $values = @(foreach ($run in $runs) {
            if ($run.wall -and $run.kind -eq 'ticket' -and -not $run.partial -and [double]$run.$field -gt 0 -and $run.size -eq $size -and
                (-not $sameModel -or $run.model -eq $model)) {
                [double]$run.$field
            }
        })
        if ($values.Count -gt 0) {
            [array]::Sort($values)
            return $values[[int][math]::Floor(($values.Count - 1) / 2)]
        }
    }
    return $null
}

# A label's value, $null without one (the page reads null).
function Get-Label($item, [string] $prefix) {
    $found = @(foreach ($name in Get-Names $item) { if ($name -like "$prefix*") { $name } })
    if ($found.Count -eq 0) {
        return $null
    }
    return [string](@($found | Sort-Object)[0]).Substring($prefix.Length)
}

# A ticket's size; M without the label, as for the workers.
function Get-Size($item) {
    $size = Get-Label $item 'size:'
    return $(if ($size) { $size } else { 'M' })
}

# A ticket's areas without the prefix (api/search), as an array even when empty.
function Get-Areas($item) {
    $found = @(foreach ($name in Get-Names $item) { if ($name -like 'area:*') { $name } })
    if ($found.Count -gt 1) {
        $found = @($found | Sort-Object)
    }
    return ,@(foreach ($name in $found) { $name.Substring(5) })
}

function Get-Priority($item) {
    $found = @(foreach ($name in Get-Names $item) { if ($name -match '^P[0-2]$') { $name } })
    if ($found.Count -eq 0) {
        return $null
    }
    return [string]@($found | Sort-Object)[0]
}

# The areas and repos that tickets in flight hold: claimed by a worker and not waiting on the owner.
function Get-BusyAreas($issues, [int] $except = 0) {
    return @(foreach ($issue in $issues) {
        # Get-Names inline: this runs for every ticket, once per queued row.
        $n = @(foreach ($label in $issue.labels) { $label.name })
        if ($issue.number -ne $except -and ($n -like 'worker:*') -and $n -notcontains 'needs-owner') {
            foreach ($name in $n) { if ($name -like 'area:*' -or $name -like 'repo:*') { $name } }
        }
    })
}

# Whether a GitHub reading offers the workers work that the reading before it did not: a ticket that entered the queue
# (filed, given a priority, handed back), or an area that no ticket in flight holds any more (a PR held for the
# owner). The server then wakes the idle workers (docs/QUEUE.md, Wakes). The first reading offers nothing new.
function Test-NewWork($old, $new) {
    if (-not $old -or -not $new) {
        return $false
    }
    $queued = {
        param($issues)
        @($issues | Where-Object {
            $n = Get-Names $_
            ($n | Where-Object { $_ -match '^P[0-2]$' }) -and -not ($n | Where-Object { $_ -like 'worker:*' -or $_ -eq 'needs-owner' })
        } | ForEach-Object { [int]$_.number })
    }
    $was = @(& $queued $old.issues)
    if (@(& $queued $new.issues | Where-Object { $was -notcontains $_ }).Count -gt 0) {
        return $true
    }
    $busy = @(Get-BusyAreas $new.issues)
    return @(Get-BusyAreas $old.issues | Where-Object { $busy -notcontains $_ }).Count -gt 0
}

# The complexity of a PR's ticket; medium without the label, as for the workers.
function Get-QueueComplexity($pr, $issues) {
    $ticket = $issues | Where-Object { "t$($_.number)" -eq $pr.headRefName } | Select-Object -First 1
    $complexity = Get-Label $ticket 'complexity:'
    return $(if ($complexity) { $complexity } else { 'medium' })
}

# Whether the owner switched off the complexity of a PR's ticket for its worker (limits.ps1): its answers and its
# rebase wait.
function Test-PrOff($pr, $issues, $settings, [string] $worker) {
    return Test-ComplexityOff (Get-QueueComplexity $pr $issues) $settings $worker
}

# Now (docs/QUEUE.md, Now): the worker that does a queued ticket at once, for the page's Now button. Only a worker that
# looks for its next job on its own: active with no change of status to come, free or in a run, with no force on it and
# with the ticket's complexity on. Its account must take the ticket's size now (Get-Fit, as for a worker's next ticket),
# and for a ticket whose model has a window of its own it must be under that window's start line.
# Of those: first a worker whose ticket in work holds an area of this one (the two would change the same files), then a
# free one, then the most room in the shortest window, then in the longest, then the run that started last (it loses the least
# work). Returns @{ worker; stops; title; busy }: `stops` and `title` are the ticket of the run that ends at its next
# checkpoint (0 for a free worker); `busy` are this ticket's areas that other tickets in flight still hold. With no
# such worker: @{ why }.
function Select-NowWorker($ticket, $issues, $workerViews, $settings = $null, $accounts = @()) {
    $complexity = Get-Label $ticket 'complexity:'
    if (-not $complexity) {
        $complexity = 'medium'
    }
    $size = Get-Size $ticket
    $areas = @(Get-Names $ticket | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })
    $able = @($workerViews | Where-Object {
        $_.status -eq 'active' -and -not $_.pending -and $_.activity -in @('free', 'running') -and -not $_.forced -and
            -not (Test-ComplexityOff $complexity $settings ([string]$_.id))
    })
    if ($able.Count -eq 0) {
        return @{ why = 'no worker can take it: each is paused, held, forced or has its complexity off' }
    }
    $noModel = 0
    # Each worker's account is read with the windows of the worker's own coding tool.
    $default = $script:Provider
    $ranked = @(foreach ($view in $able) {
        Select-Provider (Get-ViewProvider $view $default)
        $account = $accounts | Where-Object { $_.name -eq $view.account } | Select-Object -First 1
        # Not an account at the start line of the model's own window (docs/QUEUE.md, A model's limit): a run would end
        # for a ticket that cannot start.
        # shortcut: a model that the plan refused (the PC's access.json) is not read here; the worker script puts such a
        # ticket back in the queue. Read it here when a Now is lost to it in use.
        $model = [string]($view.takes | Where-Object { $_.name -eq $complexity } | Select-Object -First 1).model
        $window = Get-ModelWindow $model
        $reading = if ($account -and $window) { $account[$window] } else { $null }
        if ($reading) {
            $start = [double]$reading.stopAt
            if ($reading.pickUp) {
                $start = [math]::Min([double](@($reading.pickUp.Values) | Measure-Object -Minimum).Minimum, $start)
            }
            if ([double]$reading.used -ge $start) {
                $noModel++
                continue
            }
        }
        if ($account -and -not (Get-Fit $size $account)) {
            continue
        }
        # Only a ticket's own run frees its areas when it ends: a PR's job keeps its ticket.
        $works = $view.activity -eq 'running' -and (-not $view.kind -or $view.kind -eq 'ticket')
        $held = if ($works) {
            @(Get-Names ($issues | Where-Object { $_.number -eq [int]$view.ticket } | Select-Object -First 1) |
                Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })
        } else {
            @()
        }
        $room = @{ short = 1.0; long = 1.0 }
        foreach ($end in @('short', 'long')) {
            $window = if ($end -eq 'short') { $ShortWindow } else { $LongWindow }
            if ($window -and $account -and $account[$window]) {
                $room[$end] = [double]$account[$window].ceiling - [double]$account[$window].used
            }
        }
        @{
            view = $view; works = $works; clash = [int](@(Get-Clashes $areas $held).Count -gt 0); free = [int]($view.activity -eq 'free')
            short = $room.short; long = $room.long; started = [long]$view.startedAt
        }
    })
    Select-Provider $default
    if ($ranked.Count -eq 0) {
        return @{ why = $(if ($noModel -eq $able.Count) { "no account has the model of a $complexity ticket left" } else { "no account has room for a size $size ticket now" }) }
    }
    $best = @($ranked | Sort-Object @{ Expression = { $_.clash }; Descending = $true }, @{ Expression = { $_.free }; Descending = $true },
        @{ Expression = { $_.short }; Descending = $true }, @{ Expression = { $_.long }; Descending = $true },
        @{ Expression = { $_.started }; Descending = $true }, @{ Expression = { [int]$_.view.id } })[0]
    $view = $best.view
    $stops = if ($view.activity -eq 'running') { [int]$view.ticket } else { 0 }
    $busy = @(Get-Clashes $areas (Get-BusyAreas $issues $(if ($best.works) { $stops } else { 0 })) | ForEach-Object { $_ -replace '^area:', '' })
    return @{ worker = [string]$view.id; stops = $stops; title = $(if ($stops) { [string]$view.title } else { '' }); busy = $busy }
}

# Tickets not yet claimed, in the dispatcher's order (docs/QUEUE.md, Dispatching), each with why it waits; and the parked
# ones (no priority). A ticket that waits on the owner is a question, a stuck run or on hold: not here. `taken`: the
# worker whose force file names the ticket for Now. `now`: for each other ticket that can run, the worker that would do
# it at once or why none can (Select-NowWorker).
function Get-QueueRows($issues, $workerViews, $dispatch = $null, $settings = $null, $accounts = @()) {
    $open = @($issues | ForEach-Object { $_.number })
    # Each ticket's open blockers, read once: the parked rows ask every ticket whether it waits on them.
    $blockedBy = @{}
    foreach ($issue in $issues) {
        $blockedBy[[int]$issue.number] = @(Get-Blockers $issue $open)
    }
    $nows = @{}
    foreach ($view in $workerViews | Where-Object { $_.now }) {
        $nows[[int]$view.now] = [string]$view.id
    }
    $busy = Get-BusyAreas $issues
    $enabled = @($workerViews | Where-Object { $_.status -ne 'disabled' })
    $queued = @()
    $parked = @()
    $sorted = @($issues | Where-Object {
        -not (Get-Names $_ | Where-Object { $_ -like 'worker:*' -or $_ -in @('follow-up', 'open-question', 'needs-owner') })
    } | Sort-Object @{ Expression = { $p = Get-Priority $_; if ($p) { $p } else { 'P9' } } }, @{ Expression = { Get-SizeRank (Get-Size $_) } }, createdAt)
    foreach ($issue in $sorted) {
        $names = Get-Names $issue
        $row = @{
            number = $issue.number; title = $issue.title; url = $issue.url; priority = Get-Priority $issue
            size = Get-Label $issue 'size:'; repo = Get-Label $issue 'repo:'; areas = Get-Areas $issue
            complexity = Get-Label $issue 'complexity:'
        }
        if (-not $row.complexity) {
            $row.complexity = 'medium'
        }
        if (-not $row.priority) {
            # The open tickets that a Blocked by line holds on it: a drop frees them (docs/APP.md, Queue).
            $row.blocks = @(foreach ($other in $issues) { if ($blockedBy[[int]$other.number] -contains $issue.number) { $other.number } })
            $parked += $row
            continue
        }
        $blockers = @($blockedBy[[int]$issue.number])
        # The workers that have the ticket's complexity on (limits.ps1).
        $takers = @($enabled | Where-Object { -not (Test-ComplexityOff $row.complexity $settings ([string]$_.id)) })
        $areas = Get-Clashes @($names | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' }) $busy
        if ($nows[[int]$issue.number]) {
            $row.taken = $nows[[int]$issue.number]
            $row.reason = "worker $($row.taken) does it now"
        } elseif ($blockers.Count -gt 0) {
            $row.reason = "blocked by #$($blockers -join ', #')"
        } elseif ($enabled.Count -gt 0 -and $takers.Count -eq 0) {
            $row.reason = "no worker takes $($row.complexity) tickets"
        } elseif ($areas.Count -gt 0) {
            $row.reason = "$(($areas | ForEach-Object { $_ -replace '^area:', '' }) -join ', ') busy"
        } elseif (-not ($takers | Where-Object { $_.status -eq 'active' -and $_.activity -eq 'free' })) {
            $row.reason = 'no free worker'
        } elseif ($dispatch -and $dispatch.waiting -and $dispatch.waiting."$($issue.number)") {
            # The dispatcher's own word on fit (worker.ps1 writes it each pass it skips a ticket).
            $row.reason = [string]$dispatch.waiting."$($issue.number)"
        } else {
            $row.reason = 'next up'
        }
        # Also a blocked ticket: the owner accepts a merge conflict with its blocker (docs/QUEUE.md, Now).
        if (-not $row.taken) {
            $row.now = Select-NowWorker $issue $issues $workerViews $settings $accounts
        }
        $queued += $row
    }
    return @{ queued = $queued; parked = $parked }
}

# Each worker's next ticket, as the dispatcher would choose once its slot is free (worker.ps1, Get-NextJob): the
# ticket its force file names for Now (kind 'now'; no other worker gets that one), its own
# PR to answer or rebase, its own ticket, then the first queued ticket whose area is free and whose size its account
# takes now (the pick-up limits, Get-Fit; $accounts: the snapshot's accounts), one ticket per worker. With
# no such ticket, the first unblocked one, marked not available with the reason: only Force takes it. A paused
# worker's next is not available; a disabled worker has none. Worker id -> @{ number; title; url; areas; size;
# complexity (medium without the label); kind; available; why }.
# shortcut: one ticket per worker in the workers' order, not the dispatcher's best fit by account; worker.ps1's
# dispatcher decides. Upgrade when the two disagree in play.
function Get-NextTickets($issues, $prs, $workerViews, $dispatch = $null, $settings = $null, $accounts = @()) {
    $next = @{}
    $open = @($issues | ForEach-Object { $_.number })
    $branches = @($prs | ForEach-Object { $_.headRefName })
    $queue = @($issues | Where-Object {
        $n = Get-Names $_
        ($n | Where-Object { $_ -match '^P[0-2]$' }) -and
            -not ($n | Where-Object { $_ -like 'worker:*' -or $_ -in @('follow-up', 'open-question', 'needs-owner') }) -and
            @(Get-Blockers $_ $open).Count -eq 0
    } | Sort-Object @{ Expression = { Get-Priority $_ } }, @{ Expression = { Get-SizeRank (Get-Size $_) } }, createdAt)
    $given = @($workerViews | ForEach-Object { [int]$_.now } | Where-Object { $_ })
    # A free worker takes a ticket before a working one. Each worker's account is read with the windows of the
    # worker's own coding tool.
    $default = $script:Provider
    foreach ($view in @($workerViews | Sort-Object @{ Expression = { [int][bool]$_.ticket } }, @{ Expression = { [int]$_.id } })) {
        if ($view.status -eq 'disabled') {
            continue
        }
        Select-Provider (Get-ViewProvider $view $default)
        $me = "worker:$($view.id)"
        $current = [int]$view.ticket
        $why = if ($view.status -eq 'paused') {
            'the worker is paused'
        } elseif ($view.activity -eq 'signedout') {
            $(if (-not $view.out -or $view.out.kind -eq 'login') { 'its account is signed out' } else { 'its account takes no runs' })
        } elseif ($view.activity -in @('room', 'limit')) {
            'its account is at its stop line'
        } else {
            ''
        }
        $pick = $null
        $shown = $false
        $kind = 'ticket'
        if ($view.now) {
            $pick = $queue | Where-Object { $_.number -eq [int]$view.now } | Select-Object -First 1
            if ($pick) {
                $kind = 'now'
            }
        }
        $pr = $(if ($pick) { @() } else { $prs }) | Where-Object {
            $n = Get-Names $_
            $n -contains $me -and $n -notcontains 'needs-owner' -and ($n -contains 'answered' -or $n -contains 'needs-rebase') -and
                $_.headRefName -ne "t$current" -and -not (Test-PrOff $_ $issues $settings ([string]$view.id))
        } | Select-Object -First 1
        if ($pr) {
            $number = [int]$pr.headRefName.Substring(1)
            $pick = $issues | Where-Object { $_.number -eq $number } | Select-Object -First 1
            if (-not $pick) {
                $pick = [pscustomobject]@{ number = $number; title = $pr.title; url = $pr.url; labels = @() }
            }
            $kind = if ((Get-Names $pr) -contains 'answered') { 'answered' } else { 'needs-rebase' }
        }
        if (-not $pick) {
            $pick = $issues | Where-Object {
                $n = Get-Names $_
                $n -contains $me -and $n -notcontains 'needs-owner' -and $branches -notcontains "t$($_.number)" -and $_.number -ne $current
            } | Sort-Object createdAt | Select-Object -First 1
        }
        if (-not $pick) {
            # Not a ticket of a complexity the owner switched off for this worker (limits.ps1).
            $rest = @($queue | Where-Object {
                $given -notcontains $_.number -and -not (Test-ComplexityOff (Get-Label $_ 'complexity:') $settings ([string]$view.id))
            })
            $busy = @(Get-BusyAreas $issues $current) + @($issues | Where-Object { $given -contains $_.number } |
                ForEach-Object { Get-Names $_ } | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })
            $free = @($rest | Where-Object {
                (Get-Clashes @(Get-Names $_ | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' }) $busy).Count -eq 0
            })
            # Not a ticket of a size its account does not take now: over the size's pick-up limit, a worker takes the
            # next smaller ticket, and a bigger one again after the window's reset.
            $account = $accounts | Where-Object { $_.name -eq $view.account } | Select-Object -First 1
            $pick = $free | Where-Object { -not $account -or (Get-Fit (Get-Size $_) $account) } | Select-Object -First 1
            if ($pick) {
                if (-not $why -and $dispatch -and $dispatch.waiting -and $dispatch.waiting."$($pick.number)") {
                    $why = [string]$dispatch.waiting."$($pick.number)"
                }
            } elseif ($free.Count -gt 0) {
                # Shown, not given: a worker on an account with room still gets this ticket.
                $pick = $free[0]
                $shown = $true
                if (-not $why) {
                    $why = "over the pick-up limit for size $(Get-Size $pick)"
                }
            } elseif ($rest.Count -gt 0) {
                $pick = $rest[0]
                $clash = Get-Clashes @(Get-Names $pick | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' }) $busy
                if (-not $why) {
                    $why = "$(($clash | ForEach-Object { $_ -replace '^area:', '' }) -join ', ') is busy"
                }
            }
            if ($pick -and -not $shown) {
                $given += $pick.number
            }
        }
        if ($pick) {
            $complexity = Get-Label $pick 'complexity:'
            $next[[string]$view.id] = @{
                number = $pick.number; title = $pick.title; url = $pick.url; areas = Get-Areas $pick; size = Get-Label $pick 'size:'
                complexity = $(if ($complexity) { $complexity } else { 'medium' }); kind = $kind; available = -not $why; why = $why
            }
        }
    }
    Select-Provider $default
    return $next
}

# What waits on the owner (PLAYBOOK.md, What to ask), in three kinds:
# - questions: one list, each a question about the product with its default. Blocking: a held PR and a ticket's question.
#   Not blocking: an open question (its default is built already) and a follow-up that asks.
# - stuck: a run that ended with no PR and no question, with the reason from its log. Not a question.
# - held: a ticket that waits on the owner with no question on it. Not a question.
# $settings: the register, for the coding tool of a stuck run's worker: its provider reads the run's log.
function Get-Waiting($gh, [string] $slug, $settings = $null) {
    $questions = @()
    $stuck = @()
    $held = @()
    foreach ($pr in @($gh.prs | Where-Object { (Get-Names $_) -contains 'needs-owner' })) {
        $names = Get-Names $pr
        $base = @{ kind = 'pr'; repo = $pr.repo; number = $pr.number; title = $pr.title; url = $pr.url; worker = Get-Label $pr 'worker:'
            key = "$($pr.repo)#$($pr.number)" }
        # A PR its worker could not finish answering or rebasing has no question: it is stuck.
        if ($names -contains 'answered' -or $names -contains 'needs-rebase') {
            $stuck += $base + @{ reason = "The run could not finish this PR ($(if ($names -contains 'answered') { 'your answers' } else { 'the rebase' }))." }
            continue
        }
        $decision = Get-Decision $pr.body
        $text = Get-HeldQuestions $pr.body
        $questions += $base + @{
            blocking = $true
            question = $(if ($decision) { $decision } elseif ($text) { $text } else { 'The worker held this PR and wrote no question. Open it to see why.' })
            details = $(if ($decision) { $text } else { '' })
        }
    }
    foreach ($issue in @($gh.issues | Where-Object { (Get-Names $_) -contains 'needs-owner' })) {
        $last = if ($gh.questions) { [string]$gh.questions."$($issue.number)" } else { '' }
        $base = @{ kind = 'ticket'; repo = $slug; number = $issue.number; title = $issue.title; url = $issue.url
            worker = Get-Label $issue 'worker:'; key = "$slug#$($issue.number)" }
        $body = ($last -replace '^\*\*Worker[^*]*\*\*\s*', '').Trim()
        if ($body -match '^stopped without') {
            $log = [regex]::Match($body, 'Log: `([^`]+)`').Groups[1].Value
            $reason = Use-Provider (Get-WorkerProvider $settings ([string]$base.worker) (Get-KnownProviders)) { Get-StuckReason $log }
            $stuck += $base + @{ reason = $(if ($reason) { $reason } else { 'The run ended with no PR and no question. Its log is not on this PC.' }) }
        } elseif ($body -and $body -notmatch '^paused by') {
            $questions += $base + @{ blocking = $true; question = $body; details = '' }
        } else {
            $held += $base
        }
    }
    foreach ($issue in @($gh.issues | Where-Object { $n = Get-Names $_; $n -contains 'follow-up' -or $n -contains 'open-question' })) {
        $view = Get-FollowUpView ([string]$issue.body)
        $question = @($view.summary, $view.questions | Where-Object { $_ }) -join "`n`n"
        $questions += @{
            kind = $(if ((Get-Names $issue) -contains 'open-question') { 'question' } else { 'followup' })
            repo = $slug; number = $issue.number; title = $issue.title; url = $issue.url; worker = ''; key = "$slug#$($issue.number)"
            blocking = $false; question = $question; details = $view.details; asks = $view.questions; size = Get-Label $issue 'size:'
        }
    }
    return @{ questions = $questions; stuck = $stuck; held = $held }
}

# What the queue does with the owner's word on a question, by script (no model): $text is the answer, '' to take
# the default. Returns one of:
# - 'answered': a held PR gets the answer; its worker applies it.     'merge': a held PR merges as it is.
# - 'back': a ticket goes back to its worker, with the answer or with "take your default".
# - 'change': an open question's built default changes: queued with the answer.   'keep': it closes; nothing runs.
# - 'queue': a follow-up is queued, with the answer if any.           'drop': a follow-up closes; nothing runs.
# A follow-up asks "Do this?" first (PLAYBOOK-followup.md, Ask or queue): its default decides, and a bare "no" drops it, so
# no run starts only to read the word.
function Get-AnswerRoute($item, [string] $text) {
    $text = $text.Trim()
    switch ($item.kind) {
        'pr' { return $(if ($text) { 'answered' } else { 'merge' }) }
        'ticket' { return 'back' }
        'question' { return $(if ($text) { 'change' } else { 'keep' }) }
        'followup' {
            $no = '(no|nope|drop|skip|don''?t|do not)'
            if ($text) {
                return $(if ($text -match "^$no(\s+(it|this))?\s*[.!]?$") { 'drop' } else { 'queue' })
            }
            $default = [regex]::Match([string]$item.asks, '(?i)Default(?: built)?:\**\s*\**(\w+)').Groups[1].Value
            return $(if ($default -match "^$no$") { 'drop' } else { 'queue' })
        }
    }
    throw "not a question: $($item.kind)"
}

# One app for every project of the PC (docs/APP.md, Projects). The PC's projects as the page needs them: each
# with its name, its page's address on this PC (`local`) and on the owner's Tailscale devices (`url`, '' without one).
# $projects: name and port (tasks.ps1, Get-PcProjects); $serve: project.ps1, Read-Serve.
function Get-ProjectViews($projects, $serve) {
    return @($projects | Sort-Object { $_.name } | ForEach-Object {
        @{ name = [string]$_.name; local = "http://127.0.0.1:$($_.port)"; url = [string](Get-ServeUrl $serve $_.port) }
    })
}

# The origin of a page that may read and act here from another address, or '': only the page of a project of this
# PC, at an address that this server found itself. An exact match, and the answer is the list's own entry. This list
# is the whole guard: the header X-Queue stops another site's page only while the server says no to its browser.
function Get-PageOrigin($views, [string] $origin) {
    if (-not $origin) {
        return ''
    }
    return [string](@($views | ForEach-Object { $_.local; $_.url }) | Where-Object { $_ -and $_ -ceq $origin } | Select-Object -First 1)
}

# The address that a push opens: the app's address, on the tab of the push. The app shows every project, so the
# address names none. The app's address is the PC's plain Tailscale address (no port) when a project of the PC has it:
# the owner's phone app is there. Else this project's own address ($own).
function Get-PushUrl($views, [string] $own, [string] $click) {
    $plain = [string](@($views | ForEach-Object { $_.url }) | Where-Object { $_ -and $_ -notmatch ':\d+$' } | Select-Object -First 1)
    return "$(if ($plain) { $plain } else { $own })/#$click"
}

# Everything the page shows. $data: now, slug, workers (id, state, progress, forced, now: the ticket its force file
# names for Now), control, usage,
# settings, runs, gh (issues, prs, merged, titles, questions; $null until the first fetch), appUrl, logins, login,
# name and projects (this project's name and the PC's projects, Get-ProjectViews),
# complexities (project.ps1, Get-Complexities; models.json's alone when left out) and config (scriptorium.json, for
# the complexities of another provider than the default). The provider that is set is the project's default.
function New-Snapshot($data) {
    $now = [long]$data.now
    $models = Read-Models
    $complexities = if ($data.complexities) { @($data.complexities) } else { Get-Complexities $models $null }
    # Each coding tool this page serves, by its provider plugin's name: its models and complexities for a worker's
    # card, and what the page draws of it (`view`: its title, the features it has by their hooks' names, and its
    # windows for an account's card, the account's own first: each @{ name; title; models (it holds only some
    # models); keep (it holds the guards); seconds }).
    $default = $script:Provider
    $known = Get-KnownProviders
    $tools = @{}
    foreach ($plugin in $known) {
        Select-Provider $plugin
        $own = $plugin.Name -eq $default.Name
        $list = if ($own) { $models } else { Read-Models }
        $tools[$plugin.Name] = @{
            models = $list
            complexities = $(if ($own) { $complexities } else { @(Get-Complexities $list (Get-ProviderConfig $data.config $false)) })
            view = @{
                title = [string]$plugin.Title; hooks = @($ProviderFeatures | Where-Object { Test-ProviderHook $_ })
                windows = @(@($WindowSeconds.Keys) + @($ModelWindows.Keys) | ForEach-Object {
                    @{ name = $_; title = [string]$WindowTitles[$_]; models = $ModelWindows.Contains($_); keep = ($_ -eq $KeepWindow)
                        seconds = $(if ($ModelWindows.Contains($_)) { [long]$ModelWindows[$_].seconds } else { [long]$WindowSeconds[$_] }) }
                })
            }
        }
    }
    Select-Provider $default
    $workers = @()
    foreach ($worker in @($data.workers | Sort-Object { [int]$_.id })) {
        $s = $worker.state
        $id = [string]$worker.id
        $enabled = -not ($data.settings -and $data.settings.workers -and $data.settings.workers.$id -and $data.settings.workers.$id.enabled -eq $false)
        $marked = [bool]($data.control -and $data.control.disable -and $data.control.disable.$id)
        $status = Get-WorkerStatus ([string]$s.state) (Get-Mode $data.control $id) $enabled $marked
        $view = @{ id = $id; status = $status.status; pending = $status.pending; at = [long]$s.at; forced = [bool]$worker.forced; now = [int]$worker.now }
        # The owner's name for it (Set-WorkerName), '' for none.
        $view.name = if ($data.settings -and $data.settings.workers -and $data.settings.workers.$id) { [string]$data.settings.workers.$id.name } else { '' }
        # The worker's coding tool: its account's (plugins.ps1, Get-WorkerProvider), by its provider plugin's name.
        $plugin = Get-WorkerProvider $data.settings $id $known
        $view.provider = $(if ($plugin) { [string]$plugin.Name } else { '' })
        $tool = if ($plugin) { $tools[$plugin.Name] } else { @{ models = $models; complexities = $complexities } }
        $toolModels = $tool.models
        # The settings' `model` names a model of the default provider.
        $override = if ($data.settings -and $data.settings.model -and (-not $plugin -or $plugin.Name -eq $default.Name)) { [string]$data.settings.model } else { '' }
        # The worker's complexity switches (limits.ps1): each with the model and effort its runs use on its coding
        # tool (the settings' `model`, else the complexity's first candidate) and the PR jobs it holds while it is off.
        $view.takes = @($tool.complexities | ForEach-Object {
            $pick = if ($override) { $override } else { [string]@($_.models)[0] }
            $run = Split-Pick $toolModels $pick
            @{ name = $_.name; on = -not (Test-ComplexityOff $_.name $data.settings $id); model = $run.model; effort = $run.effort; jobs = 0 }
        })
        # A run in flight: working, or waiting in paused.json for a limit reset, for room under the workers' limit
        # (it ended at a checkpoint there), for its account, or for the owner to set the paused worker active
        # ('held').
        $held = $s.state -ne 'running' -and $s.ticket -and $s.resetsAt
        # A run whose limit has reset resumes at its script's next look, within a minute: it waits for nothing.
        # 'signedout': the worker waits for its account, which is out (docs/QUEUE.md, An account that is out), with a
        # held run or with none. The name is older than the other kinds of out; `out` below gives the kind.
        $view.activity = if ($s.state -eq 'running') { 'running' } elseif ($held) {
            if ($s.loggedOut) { 'signedout' } elseif ($s.atLimit) { 'room' } elseif ($s.stopped) { 'held' } elseif ([long]$s.resetsAt -le $now) { 'resuming' } else { 'limit' }
        } elseif ($s.state -eq 'signedout') { 'signedout' } elseif ($s.state -eq 'over-budget') { 'room' } elseif (
            # A worker the owner added: the server sets it up ('setup', or 'setup-failed' with the error), then its
            # plugins make its environment ready ('opening', with their words in `report`: a first import can take
            # long). 'error': a plugin's hook threw, or a plugin is not installed yet; the worker tries again at its
            # next look.
            @('setup', 'setup-failed', 'opening', 'error') -contains $s.state) { [string]$s.state } else { 'free' }
        if (@('setup-failed', 'error') -contains $s.state) {
            $view.error = [string]$s.error
        }
        if ($s.state -eq 'opening') {
            $view.report = [string]$s.report
        }
        # The account a held run or a waiting worker is on (its key in the queue's files), where the script names it.
        $view.on = if ($s.state -ne 'running' -and $s.account) { [string]$s.account } else { $null }
        # A stale state is a stopped script, even while its run still works: nothing then watches the run or takes the
        # next job. Counted from the app's wake: after the PC sleeps, every state is old until the scripts' next poll.
        # A failed setup has no script: it stays as it is until the owner removes the worker.
        if ($s.state -ne 'setup-failed' -and $now - [math]::Max([long]$s.at, [long]$data.awake) -gt $StaleSeconds) {
            $view.activity = 'down'
        }
        $view.run = $s.state -eq 'running' -or [bool]$held
        if ($s.ticket -and $view.status -ne 'disabled') {
            $view.ticket = [int]$s.ticket
            $view.title = $s.title
            $view.url = "https://github.com/$($data.slug)/issues/$($s.ticket)"
            $view.repo = $s.repo
            $view.kind = $s.kind
            $view.model = $s.model
            $view.effort = $s.effort
            if ($s.pr) {
                $view.prUrl = "https://github.com/$($s.repo)/pull/$($s.pr)"
            }
            # Progress: the time worked against a typical whole-ticket run of the size; an answer or a rebase has none.
            if ($s.state -eq 'running') {
                $view.startedAt = if ($s.startedAt) { [long]$s.startedAt } else { $null }
            } else {
                $view.elapsed = [long]$s.elapsed
                $view.resetsAt = [long]$s.resetsAt
            }
            if (-not $s.kind -or $s.kind -eq 'ticket') {
                $view.typical = Get-Typical $data.runs $s.size $s.model
                $view.typicalCost = Get-Typical $data.runs $s.size $s.model 'cost'
            }
            if ($worker.progress -and [int]$worker.progress.ticket -eq [int]$s.ticket) {
                $view.progress = @{ done = $worker.progress.done; next = $worker.progress.next }
            }
        }
        $workers += $view
    }

    $accounts = @()
    # Each account's name by its key in the queue's files, and the key of each worker's account.
    $names = @{}
    $keys = @{}
    if ($data.settings -and $data.settings.accounts) {
        foreach ($property in $data.settings.accounts.PSObject.Properties) {
            # Not an account of a coding tool with no plugin here: a page of a project that has it shows it. Each
            # account is reckoned with the windows of its own coding tool.
            if (-not (Test-KnownAccount $property.Value)) {
                continue
            }
            $plugin = Get-AccountProvider $property.Value $known
            Select-Provider $plugin
            $key = if ($property.Value.configDir) { $property.Value.configDir } else { 'default' }
            $uses = @($property.Value.uses)
            $usage = if ($data.usage) { $data.usage.$key } else { $null }
            # A reading of another account: the folder's login changed since.
            if ($usage -and $data.logins -and $data.logins[$key] -and [string]$usage.email -ne [string]$data.logins[$key].email) {
                $usage = $null
            }
            $budget = $null
            foreach ($use in $uses | Where-Object { $_ -like 'worker:*' }) {
                $state = ($data.workers | Where-Object { "worker:$($_.id)" -eq $use } | Select-Object -First 1).state
                if ($state -and $state.budget) {
                    $budget = $state.budget
                    break
                }
            }
            $account = @{ name = $property.Name; uses = $uses; own = [bool]$property.Value.configDir; signedIn = $false
                provider = $(if ($plugin) { [string]$plugin.Name } else { '' }) }
            $names[$key] = $property.Name
            # The account is out (worker.ps1, Get-Out): the kind and the text of its refusal, and when the workers
            # test it next.
            $record = if ($data.out) { $data.out.$key } else { $null }
            if ($record) {
                $account.out = @{ kind = [string]$record.kind; text = [string]$record.text; retryAt = [long]$record.at + 600 }
            }
            $atLimit = $false
            $clock = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            foreach ($window in @($WindowSeconds.Keys)) {
                $stopAt = if ($property.Value.stopAt -and $property.Value.stopAt.$window) { [double]$property.Value.stopAt.$window } else { [double]$DefaultStopAt[$window] }
                $w = @{ stopAt = $stopAt }
                # `pickUp`: from which share the workers take no new ticket of each size, in a window that has such
                # limits (limits.ps1).
                $pickUp = Get-PickUp $property.Value.pickUp $window
                if ($pickUp) {
                    $w.pickUp = $pickUp
                }
                if ($usage -and $usage.$window) {
                    # A reading from before the window reset counts as nothing used, as in worker.ps1's Get-Used.
                    if ([long]$usage.$window.resetsAt -le $clock) {
                        $w.used = 0.0
                    } else {
                        $w.used = [double]$usage.$window.used
                        $w.resetsAt = [long]$usage.$window.resetsAt
                    }
                }
                if ($budget -and $budget.$window -and -not $w.resetsAt) {
                    $w.resetsAt = [long]$budget.$window.resetsAt
                }
                # One window keeps room under its stop line for each human use on the account (limits.ps1,
                # $KeepWindow): its guard, with the share of the whole window the owner set and what that keeps for the
                # time left. `left`: the share of the window still to run.
                $reserve = 0.0
                if ($window -eq $KeepWindow) {
                    $left = $WindowSeconds[$window]
                    if ($w.resetsAt -and $w.resetsAt -gt $clock) {
                        $left = $w.resetsAt - $clock
                    }
                    $w.left = [math]::Round($left / $WindowSeconds[$window], 4)
                    $w.guards = @()
                    foreach ($use in $uses | Where-Object { $_ -and $_ -notlike 'worker:*' }) {
                        $share = Get-Keep $use $data.settings
                        $kept = Get-Reserve $share $left
                        $reserve += $kept
                        $w.guards += @{ use = $use; share = $share; kept = [math]::Round($kept, 4) }
                    }
                }
                # The workers stop at the ceiling: the stop line less what the guards keep.
                $w.ceiling = [math]::Round((Get-Ceiling $reserve $window $stopAt), 4)
                $w.kept = [math]::Round($stopAt - $w.ceiling, 4)
                if ($null -ne $w.used -and $w.used -ge $w.ceiling) {
                    $atLimit = $true
                }
                $account[$window] = $w
            }
            # The windows of some models (docs/QUEUE.md, A model's limit), each where the account has a reading of it:
            # its share, reset and read time, its stop line and its start line (each the account's own, else the
            # provider's). No guards.
            foreach ($window in @($ModelWindows.Keys)) {
                $reading = if ($usage) { $usage.$window } else { $null }
                if (-not $reading) {
                    continue
                }
                $stopAt = (Get-ModelLines $window $property.Value.stopAt $null).stop
                $w = @{ stopAt = $stopAt; ceiling = $stopAt; kept = 0.0; at = [long]$reading.at }
                $pickUp = Get-PickUp $property.Value.pickUp $window
                if ($pickUp) {
                    $w.pickUp = $pickUp
                }
                if ([long]$reading.resetsAt -le $clock) {
                    $w.used = 0.0
                } else {
                    $w.used = [double]$reading.used
                    $w.resetsAt = [long]$reading.resetsAt
                }
                $account[$window] = $w
            }
            if ($data.logins -and $data.logins[$key]) {
                $account.signedIn = [bool]$data.logins[$key].signedIn
                $account.email = $data.logins[$key].email
                $account.plan = $data.logins[$key].plan
            }
            $mine = @($workers | Where-Object { $uses -contains "worker:$($_.id)" })
            foreach ($view in $mine) {
                $view.account = $property.Name
                $keys[$view.id] = $key
                # A worker with no run on a login that is gone, or on an account that is out, waits for it now: its
                # script finds out only at its next look, up to a poll later.
                if ($view.activity -eq 'free' -and ($record -or ($data.logins -and $data.logins[$key] -and -not $account.signedIn))) {
                    $view.activity = 'signedout'
                }
            }
            # One word for the card: signed out (no login, or a run was refused for its login), refused (the account
            # is out for another cause: its subscription, or runs that do not start), at its stop line, not used by
            # anything, or ready.
            $account.status = if (-not $account.signedIn -or ($record -and $record.kind -eq 'login')) { 'signedout' }
                elseif ($record) { 'refused' }
                elseif ($atLimit) { 'limit' } elseif (-not @($uses | Where-Object { $_ }).Count) { 'unused' } else { 'ready' }
            $accounts += $account
        }
    }
    Select-Provider $default
    $toolViews = @{}
    foreach ($name in @($tools.Keys)) {
        $toolViews[$name] = $tools[$name].view
    }
    foreach ($view in $workers) {
        # A worker in no entry runs on the command-line login.
        $key = if ($view.on) { $view.on } elseif ($keys[$view.id]) { $keys[$view.id] } else { 'default' }
        # A held run stays on the account it began on: named when the owner moved the worker meanwhile.
        if ($view.on -and $view.run -and $names[$key] -ne $view.account) {
            $view.heldOn = $(if ($names[$key]) { $names[$key] } else { 'command line' })
        }
        if ($view.activity -eq 'signedout') {
            # The worker's own record goes first: its runs do not start although its account answers. The script
            # tries a run again after an hour; an account is tested every 10 minutes.
            $own = if ($data.out) { $data.out."worker:$($view.id)" } else { $null }
            $record = if ($own) { $own } elseif ($data.out) { $data.out.$key } else { $null }
            $view.out = if ($record) {
                @{ kind = [string]$record.kind; text = [string]$record.text; own = [bool]$own
                    retryAt = [long]$record.at + $(if ($own) { 3600 } else { 600 }) }
            } else {
                @{ kind = 'login' }
            }
        }
        $view.Remove('on')
    }

    $color = [string]$(if ($data.settings) { $data.settings.color })
    $titles = @{}
    foreach ($entry in $models.models.PSObject.Properties) {
        if ($entry.Value.title) {
            $titles[$entry.Name] = [string]$entry.Value.title
        }
    }
    $snapshot = @{
        now = $now; appUrl = $data.appUrl; slug = $data.slug; workers = $workers; accounts = $accounts; login = $data.login; github = [bool]$data.gh
        # The coding tools of the workers and the accounts ($tools above, each one's `view`), by provider name.
        tools = $toolViews
        # This project's name and the PC's projects, for the page's project switch.
        name = [string]$data.name; projects = @($data.projects | Where-Object { $_ })
        # The owner's order of the cards (Set-CardOrder), the same in every project's snapshot.
        order = @{ workers = @($data.settings.order.workers | Where-Object { $_ }); accounts = @($data.settings.order.accounts | Where-Object { $_ }) }
        questions = @(); stuck = @(); held = @(); queued = @(); parked = @(); merged = @(); runs = @()
        left = @{ count = 0; seconds = 0; cost = 0.0 }
        # The advisor rule (docs/QUEUE.md, Models), with models.json's model as `base`, for the Details tab.
        advisor = (Get-AdvisorRule $models $complexities $data.settings) + @{ base = [string]$models.advisor.model }
        # The models and efforts that Details offers for a complexity: models.json's two lists. And each model's name
        # on the page, where models.json gives one (`title`).
        models = @($models.models.PSObject.Properties | ForEach-Object { $_.Name }); efforts = @($models.efforts | Where-Object { $_ })
        modelTitles = $titles
        # The project's default provider (its plugin's title; '' with none), whose models Details sets, and its
        # windows as in `tools`.
        provider = $(if ($script:Provider) { [string]$script:Provider.Title } else { '' })
        # The features the default provider has (plugins.ps1, $ProviderFeatures), by their hooks' names: Details
        # says what the coding tool gives. And the compact sizes it takes.
        hooks = @($ProviderFeatures | Where-Object { Test-ProviderHook $_ })
        compactRange = @($models.compactRange | Where-Object { $_ })
        windows =@(@($WindowSeconds.Keys) + @($ModelWindows.Keys) | ForEach-Object {
            @{ name = $_; title = [string]$WindowTitles[$_]; models = $ModelWindows.Contains($_); keep = ($_ -eq $KeepWindow)
                seconds = $(if ($ModelWindows.Contains($_)) { [long]$ModelWindows[$_].seconds } else { [long]$WindowSeconds[$_] }) }
        })
        # The project's colour on the page (`color`): only a valid one, as a hand edit of the file skips the action.
        color = $(if ($color -match '^#[0-9a-fA-F]{6}\z') { $color.ToLowerInvariant() } else { '' })
        # The owner is away (docs/QUEUE.md, No blocking): the PC's switch, the same in every project's snapshot.
        away = [bool]$(if ($data.settings) { $data.settings.away })
        # The settings' `model`, which goes over every pick of Details for every run; '' without one.
        settingsModel = $(if ($data.settings -and $data.settings.model) { [string]$data.settings.model } else { '' })
        # Every complexity with its description, models, the first one's model and effort, the same without the owner's
        # pick (`base`), its advisor (none for a run on the advisor's own model), the owner's advisor switch
        # (`advisorOn`) and fallback effort, the two without the owner's settings (`baseAdvisor`, `baseFallback`) and
        # its compact size.
        complexities = @($complexities | ForEach-Object {
            $run = Split-Pick $models ([string]@($_.models)[0])
            $rule = Get-AdvisorRule $models @($_) $data.settings
            @{ name = $_.name; description = $_.description; models = @($_.models); model = $run.model; effort = $run.effort
                base = Split-Pick $models ([string]$_.base)
                advisor = $(if ($rule.complexities.Count -and $rule.model -ne $run.model) { $rule.model } else { '' }); advisorFallback = $_.advisorFallback
                advisorOn = [bool]$_.advisor; baseAdvisor = [bool]$_.baseAdvisor; baseFallback = [string]$_.baseFallback
                compactAt = $_.compactAt }
        })
        # The project's plugins (name, title, version, description, and whether it is the provider) for the Details tab.
        plugins = @($data.plugins | Where-Object { $_ } | ForEach-Object {
            @{ name = $_.Name; title = $_.Title; version = $_.Version; description = $_.Description; provider = [bool]$_.Provider }
        })
    }
    $gh = $data.gh
    if ($gh) {
        # A worker's state is newer than GitHub's reading (once a minute): the ticket of a run that began since has
        # no worker label there yet. It counts as claimed, so it leaves the queue and is nobody's next at once.
        foreach ($view in $workers | Where-Object { $_.ticket -and $_.run }) {
            $issue = $gh.issues | Where-Object { [int]$_.number -eq $view.ticket } | Select-Object -First 1
            if ($issue -and -not (Get-Names $issue | Where-Object { $_ -like 'worker:*' })) {
                $issue.labels = @($issue.labels) + [pscustomobject]@{ name = "worker:$($view.id)" }
            }
        }
        foreach ($view in $workers | Where-Object { $_.status -eq 'paused' -and -not $_.ticket }) {
            # A paused worker keeps its ticket: the one it claimed that has no PR yet.
            $branches = @($gh.prs | ForEach-Object { $_.headRefName })
            $own = $gh.issues | Where-Object {
                $n = Get-Names $_
                $n -contains "worker:$($view.id)" -and $n -notcontains 'needs-owner' -and $branches -notcontains "t$($_.number)"
            } | Sort-Object createdAt | Select-Object -First 1
            if ($own) {
                $view.ticket = [int]$own.number
                $view.title = $own.title
                $view.url = $own.url
            }
        }
        foreach ($view in $workers | Where-Object { $_.ticket }) {
            $issue = $gh.issues | Where-Object { [int]$_.number -eq $view.ticket } | Select-Object -First 1
            $view.areas = Get-Areas $issue
            $view.size = Get-Label $issue 'size:'
        }
        $waiting = Get-Waiting $gh $data.slug $data.settings
        $snapshot.questions = @($waiting.questions)
        $snapshot.stuck = @($waiting.stuck)
        $snapshot.held = @($waiting.held)
        $dispatch = if ($data.dispatch -and $now - [long]$data.dispatch.at -lt $StaleSeconds) { $data.dispatch } else { $null }
        $next = Get-NextTickets $gh.issues $gh.prs $workers $dispatch $data.settings $accounts
        foreach ($view in $workers) {
            $view.next = $next[$view.id]
        }
        $rows = Get-QueueRows $gh.issues $workers $dispatch $data.settings $accounts
        foreach ($view in $workers) {
            foreach ($take in $view.takes) {
                $take.jobs = @($gh.prs | Where-Object {
                    $n = Get-Names $_
                    $n -contains "worker:$($view.id)" -and $n -notcontains 'needs-owner' -and
                        ($n -contains 'answered' -or $n -contains 'needs-rebase') -and
                        (Get-QueueComplexity $_ $gh.issues) -eq $take.name
                }).Count
            }
        }
        # What is left: each queued ticket's typical time and cost by its size, and their sums.
        $typical = @{}
        foreach ($row in $rows.queued) {
            $size = if ($row.size) { $row.size } else { 'M' }
            # Once per size: the rows share a handful.
            if (-not $typical.ContainsKey($size)) {
                $typical[$size] = @{ seconds = Get-Typical $data.runs $size ''; cost = Get-Typical $data.runs $size '' 'cost' }
            }
            $row.seconds = $typical[$size].seconds
            $row.cost = $typical[$size].cost
            $snapshot.left.seconds += [double]$row.seconds
            $snapshot.left.cost += [double]$row.cost
        }
        $snapshot.left.count = @($rows.queued).Count
        $snapshot.queued = @($rows.queued)
        $snapshot.parked = @($rows.parked)
        $snapshot.merged = @($gh.merged | Sort-Object mergedAt -Descending | Select-Object -First 8 | ForEach-Object {
            @{ repo = $_.repo; number = $_.number; title = $_.title; url = $_.url; mergedAt = $_.mergedAt }
        })
    }
    $snapshot.runs = @($data.runs | Select-Object -Last 12 | ForEach-Object {
        $title = if ($gh -and $gh.titles) { $gh.titles."$($_.ticket)" } else { $null }
        @{
            ticket = $_.ticket; title = $title; kind = $_.kind; size = $_.size; model = $_.model; duration = $(if ($_.wall) { $_.duration } else { $null }); cost = $_.cost
            at = $_.at; partial = [bool]$_.partial
        }
    })
    [array]::Reverse($snapshot.runs)
    return $snapshot
}

# What a change between two snapshots tells the owner's phone: short texts without ticket content (ntfy's server
# is public; the page shows the rest). Each: title, message, priority (1-5), tags, click (the page's tab).
function Get-Events($old, $new) {
    $events = @()
    if (-not $old) {
        return $events
    }
    if ($old.github -and $new.github) {
        # Only a blocking question pushes: the others hold no work.
        $before = @($old.questions | Where-Object { $_.blocking } | ForEach-Object { $_.key })
        foreach ($question in $new.questions | Where-Object { $_.blocking -and $before -notcontains $_.key }) {
            $who = if ($question.worker) { "Worker $($question.worker)" } else { 'A worker' }
            $events += @{ title = 'Question'; message = "$who has a question that blocks its work."; priority = 4; tags = 'raising_hand'; click = 'questions' }
        }
        $stuckBefore = @($old.stuck | ForEach-Object { $_.key })
        foreach ($item in $new.stuck | Where-Object { $stuckBefore -notcontains $_.key }) {
            $events += @{ title = 'Stuck'; message = 'A run ended with no result. See the Queue tab.'; priority = 3; tags = 'warning'; click = 'queue' }
        }
        $mergedBefore = @($old.merged | ForEach-Object { $_.url })
        $merged = @($new.merged | Where-Object { $mergedBefore -notcontains $_.url })
        if ($merged.Count -gt 0) {
            $events += @{ title = 'Merged'; message = "$($merged.Count) PR$(if ($merged.Count -gt 1) { 's' }) merged."; priority = 2
                tags = 'white_check_mark'; click = 'history' }
        }
    }
    foreach ($worker in $new.workers) {
        $was = ($old.workers | Where-Object { $_.id -eq $worker.id } | Select-Object -First 1).activity
        if ($was -eq $worker.activity) {
            continue
        }
        switch ($worker.activity) {
            'limit' {
                $until = [DateTimeOffset]::FromUnixTimeSeconds($worker.resetsAt).LocalDateTime.ToString('ddd HH:mm')
                $events += @{ title = 'Usage limit'; message = "Worker $($worker.id) waits for its usage limit until $until."; priority = 3
                    tags = 'hourglass'; click = 'workers' }
            }
            'room' {
                # Only a run that ended at a checkpoint for the workers' limit; a free worker over it is no news.
                if ($worker.run) {
                    $events += @{ title = 'Stop line'; message = "Worker $($worker.id) stopped at its account's stop line. It resumes when the account has room."; priority = 3
                        tags = 'hourglass'; click = 'accounts' }
                }
            }
            'signedout' {
                # The account is out: the push names the cause, without the refusal's text (ntfy's server is public).
                $kind = if ($worker.out) { [string]$worker.out.kind } else { 'login' }
                $events += switch ($kind) {
                    'subscription' {
                        @{ title = 'Subscription refused'; message = "Worker $($worker.id)'s account refuses its subscription. Renew it, or give the worker another account."
                            priority = 4; tags = 'key'; click = 'accounts' }
                    }
                    'start' {
                        @{ title = 'Runs do not start'; message = "Worker $($worker.id)'s runs do not start. Its card says why."
                            priority = 4; tags = 'warning'; click = 'workers' }
                    }
                    default {
                        @{ title = 'Signed out'; message = "Worker $($worker.id)'s account is signed out. Sign it in again."; priority = 4
                            tags = 'key'; click = 'accounts' }
                    }
                }
            }
            'setup-failed' {
                $events += @{ title = 'Setup failed'; message = "Worker $($worker.id) could not be set up. Its card says why."; priority = 4
                    tags = 'warning'; click = 'workers' }
            }
            'down' {
                $events += @{ title = 'Worker down'; message = "Worker $($worker.id)'s script stopped answering."; priority = 4
                    tags = 'warning'; click = 'workers' }
            }
            'running' {
                if ($was -in @('limit', 'resuming')) {
                    $events += @{ title = 'Resumed'; message = "Worker $($worker.id) resumed after the usage limit."; priority = 2
                        tags = 'arrow_forward'; click = 'workers' }
                }
            }
        }
    }
    $quiet = {
        param($snapshot)
        @($snapshot.workers).Count -gt 0 -and -not ($snapshot.workers | Where-Object { $_.status -eq 'active' -and $_.activity -ne 'down' })
    }
    if ((& $quiet $new) -and -not (& $quiet $old)) {
        $events += @{ title = 'Safe to switch off'; message = 'No worker is active.'; priority = 3; tags = 'zzz'; click = 'workers' }
    }
    $empty = {
        param($snapshot)
        $on = @($snapshot.workers | Where-Object { $_.status -ne 'disabled' })
        $snapshot.github -and @($snapshot.queued).Count -eq 0 -and $on.Count -gt 0 -and
            -not ($on | Where-Object { $_.status -ne 'active' -or $_.activity -ne 'free' })
    }
    # Not at the page's start: its first snapshot has no reading of GitHub, so an empty queue is no news then.
    if ($old.github -and (& $empty $new) -and -not (& $empty $old)) {
        $events += @{ title = 'Queue empty'; message = 'Nothing queued; every worker free.'; priority = 2; tags = 'inbox_tray'; click = 'queue' }
    }
    return $events
}
