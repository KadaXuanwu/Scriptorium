# A worker script (docs/QUEUE.md): has its plugins make its clone's environment ready, claims the next job (the
# dispatcher: a new ticket goes to the idle worker whose account's free room most wants spending) and starts a run, a
# headless session of the provider's coding tool on it with what the plugins give it (docs/PLUGINS.md). Watches the
# plan's usage while a run works, and resumes a run the usage limit cut off once the limit resets. Loops until stopped;
# started at logon by setup.ps1's task.
param(
    # The project's main checkout.
    [Parameter(Mandatory = $true)] [string] $Project,
    [Parameter(Mandatory = $true)] [int] $Id,
    # The worker's copy: `<main>-w<Id>` beside the main checkout when left out.
    [string] $Clone,
    [int] $PollSeconds = 300
)

$ErrorActionPreference = 'Stop'
# gh writes UTF-8; Windows PowerShell would read it in the console's old code page and garble titles.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'project.ps1')
. (Join-Path $PSScriptRoot 'plugins.ps1')
. (Join-Path $PSScriptRoot 'budget.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')
. (Join-Path $PSScriptRoot 'areas.ps1')
. (Join-Path $PSScriptRoot 'comments.ps1')
. (Join-Path $PSScriptRoot 'away.ps1')

$Project = Resolve-Project $Project
$config = Read-Project $Project
if (-not $Clone) {
    $Clone = "$Project-w$Id"
}
# A plugin the file names that is not installed yet (plugins.ps1, Get-MissingPlugins): the worker loads the others,
# starts no run and says so on its card, and starts again when setup.ps1 has cloned it (Start-CodeWatch below).
$missing = Get-MissingPlugins $PSScriptRoot $config
$projectPlugins = Import-Plugins $PSScriptRoot $config -Installed

# One loop per worker: stopping the task ends only its console host, so an older loop may still run, on old code.
# End it with its run; the ticket resumes here (PLAYBOOK.md, Branch). Only this project's worker of this number.
Get-CommandLines -Shells |
    Where-Object { $_.ProcessId -ne $PID -and (Test-ProjectProcess $_.CommandLine 'worker.ps1' $Project) -and $_.CommandLine -match "-Id $Id\b" } |
    ForEach-Object { Stop-ProcessTree $_.ProcessId }

$me = "worker:$Id"
$Clone = (Resolve-Path $Clone).Path
$queueDir = Join-Path $Clone '.queue'
$pausedFile = Join-Path $queueDir 'paused.json'
$warnFile = Join-Path $queueDir 'limit.md'
$stopFile = Join-Path $queueDir 'stop.md'
$commentsFile = Join-Path $queueDir 'comments.md'
# There while the owner is away (docs/QUEUE.md, No blocking; away.ps1).
$awayFile = Join-Path $queueDir 'away.md'
# Written by a run that hands its ticket on at its model's limit (docs/QUEUE.md, A model's limit).
$handoffFile = Join-Path $queueDir 'handoff.md'
$progressFile = Join-Path $queueDir 'progress.json'
$mainQueueDir = Join-Path $Project '.queue'
# The accounts' records are the PC's (pc.ps1): the workers of every project read and write them.
$usageFile = Join-Path $PcDir 'usage.json'
$historyFile = Join-Path $mainQueueDir 'history.jsonl'
$accessFile = Join-Path $PcDir 'access.json'
# Forced from the queue app: the next job starts past the area, room and ceiling checks; the run ending clears it.
$forceFile = Join-Path $mainQueueDir "force-$Id.json"
# Queued as this worker's next from the queue app (docs/QUEUE.md, Queue next): no force, the run in progress goes on.
$nextFile = Join-Path $mainQueueDir "next-$Id.json"
# Wakes (docs/QUEUE.md, Wakes): a write to the first ends the merger's wait, a write to the second an idle worker's.
$wakeMerger = Join-Path $mainQueueDir 'wake-merger'
$wakeWorkers = Join-Path $mainQueueDir 'wake-workers'
New-Item -ItemType Directory -Force (Join-Path $queueDir 'logs'), $mainQueueDir | Out-Null
# The providers this worker can run on (plugins.ps1, Get-Providers): the project's default first.
$providers = Get-Providers $PSScriptRoot $projectPlugins
# A PC from before an account had a provider: the accounts this worker is on become the provider that the project
# itself lists first (pc.ps1), and none with a project that lists none. Not while a plugin is missing: it may be the
# default provider, and the first here another tool's.
$ownProvider = Get-ProjectProviderName $projectPlugins
if ($ownProvider -and -not $missing.Count) {
    Update-AccountProviders $Project @("$Id") $ownProvider
}
# The provider (docs/PLUGINS.md, A provider): the plugin that runs the coding tool, reads its logs and knows its
# accounts and windows. It is the one of the worker's account (plugins.ps1, Get-WorkerProvider), so a worker runs on
# its coding tool in any project. Without one the worker starts no run.
$provider = Get-WorkerProvider (Read-ProjectSettings $Project) "$Id" $providers
# scriptorium.json's models are the default provider's (project.ps1, Get-ProviderConfig).
$isDefault = [bool]($provider -and $provider.Name -eq $providers[0].Name)
# The worker's plugins: the project's, without the other providers. Their playbooks and hooks are no part of its runs.
$plugins = @($projectPlugins | Where-Object { -not $_.Provider -or ($provider -and $_.Name -eq $provider.Name) })
if ($provider -and @($plugins | ForEach-Object { $_.Name }) -notcontains $provider.Name) {
    $plugins = @($provider) + $plugins
}
# A pull of a plugin restarts the worker as a pull of Scriptorium does. So does a change to the provider's models.json:
# its windows are read once, when a script starts (limits.ps1, Set-Windows).
Start-CodeWatch (@((Join-Path $Project 'scriptorium.json')) + @($plugins | ForEach-Object { $_.Dir }) +
    @($plugins | Where-Object { $_.Provider } | ForEach-Object { Join-Path $_.Dir 'models.json' }) +
    @($missing | ForEach-Object { $_.Watch }))
Set-Provider $provider @{ Project = $Project; Copy = $Clone; Worker = $Id; QueueDir = $queueDir
    Machine = { Read-Settings }; Log = { param($text) Write-Log "$text" } }
# Every turn reads the whole context again, so a run's context is compacted at the compact size of the job's
# complexity, where the provider can (docs/CONFIG.md, The compact size). A run never hands off to a fresh session:
# that cost 24 turns of reading, a compaction 7.
Set-Location $Clone
$repo = (& gh repo view --json nameWithOwner -q .nameWithOwner)
# The repo's owner, whose other repos a ticket's `repo:<Name>` label names.
$owner = $repo.Split('/')[0]

# The windows of the whole account, shortest first: the provider's (limits.ps1, Set-Windows).
$windows = @($WindowSeconds.Keys)

# Windows PowerShell's ConvertFrom-Json passes a JSON list on as one object; returning it from a variable unrolls it.
function Get-GhJson([string[]] $GhArgs, [string] $Slug = $repo) {
    $json = ((& gh @GhArgs -R $Slug) -join "`n") | ConvertFrom-Json
    return $json
}

function Get-Names($item) {
    return @($item.labels | ForEach-Object { $_.name })
}

function Get-Size($item) {
    $label = Get-Names $item | Where-Object { $_ -match '^size:[SML]$' } | Select-Object -First 1
    if ($label) {
        return $label.Substring(5)
    }
    return 'M'
}

# How hard the ticket is to get right, which picks its model (Models); size is only what it costs.
function Get-Complexity($item) {
    return Get-TicketComplexity (Get-Names $item) (Get-ProjectComplexities)
}

function Write-Log([string] $Text) {
    Add-Content -Path (Join-Path $queueDir 'worker.log') -Value "$(Get-Date -Format s) $Text" -Encoding utf8
}

function Get-Now {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Format-Time([long] $unix) {
    return [DateTimeOffset]::FromUnixTimeSeconds($unix).LocalDateTime.ToString('ddd HH:mm')
}

function Format-Share([double] $share) {
    return "$([math]::Round($share * 100)) %"
}

# This worker's state for the others' dispatching and the queue app: idle, over-budget, drained, stopped or
# disabled (refreshed every poll), running (every 30 s), paused (its run waits for a limit reset or for its account)
# or signedout (it has no run and its account is out, Get-Out; the name is the app's, for every kind of out). A
# running one also names its job, account, ticket size and the usage it started from, so workers sharing an account
# count what it has left. The account's budget rides along for the app. The app turns these into the worker's status
# (active, paused, disabled) and what it does (docs/APP.md, Worker status).
function Write-State([string] $state, $running) {
    $record = @{ state = $state; at = (Get-Now); queueDir = $queueDir; clone = $Clone }
    if ($running) {
        $record += $running
    }
    if ($script:budget) {
        $record.budget = $script:budget
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $mainQueueDir "worker-$Id.json") -Encoding utf8
}

# The account's budget per window as the app shows it (docs/APP.md).
function Save-Budget($budget) {
    $script:budget = @{}
    foreach ($window in $windows) {
        $script:budget[$window] = @{
            used = $budget[$window].used; ceiling = $budget[$window].ceiling; resetsAt = (Get-Now) + $budget[$window].left
        }
    }
}

# The owner's control from the queue app (`.queue/control.json`, written by the app only), this worker's entry:
# 'drain' (no new job; its run finishes), 'stop' (no new job, and its run wraps up at its next checkpoint), or $null.
function Get-Control {
    $file = Join-Path $mainQueueDir 'control.json'
    if (-not (Test-Path $file)) {
        return $null
    }
    try {
        $control = Get-Content $file -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    $mode = if ($control.workers) { $control.workers."$Id" } else { $null }
    if ($mode -eq 'drain' -or $mode -eq 'stop') {
        return $mode
    }
    return $null
}

function Get-WorkerStates {
    $states = @()
    foreach ($file in Get-ChildItem (Join-Path $mainQueueDir 'worker-*.json')) {
        $states += @{ Worker = [int]($file.BaseName.Substring(7)); State = (Get-Content $file.FullName -Raw | ConvertFrom-Json) }
    }
    return $states
}

# A comment on the job's PR, or on its ticket when it has none yet.
function Send-Comment($job, [string] $text) {
    if ($job.Kind -eq 'ticket') {
        & gh issue comment $job.Ticket --body "**Worker ${Id}:** $text" -R $repo | Out-Null
    } else {
        & gh pr comment $job.Pr --body "**Worker ${Id}:** $text" -R (Get-JobRepo $job) | Out-Null
    }
}

# Where a job's work happens: this repo, or another of the owner's named by its ticket's `repo:<Name>` label
# (PLAYBOOK-repo.md). A job from before that label existed has none: this repo.
function Get-JobRepo($job) {
    if ($job.Repo) {
        return $job.Repo
    }
    return $repo
}

function Get-TicketRepo($ticket) {
    $label = Get-Names $ticket | Where-Object { $_ -like 'repo:*' } | Select-Object -First 1
    if ($label) {
        return "$owner/$($label.Substring(5))"
    }
    return $repo
}

# The worker's checkout of a job's repo: its own clone, or `<Name>-w<Id>` beside it, cloned on first use and given the
# clone's GitHub identity.
function Get-JobDir([string] $slug) {
    if ($slug -eq $repo) {
        return $Clone
    }
    $dir = Join-Path (Split-Path $Clone -Parent) "$($slug.Split('/')[1])-w$Id"
    if (-not (Test-Path $dir)) {
        Write-Log "cloning $slug to $dir"
        & gh repo clone $slug $dir | Out-Null
    }
    foreach ($key in @('user.name', 'user.email')) {
        $value = & git -C $Clone config --local --get $key
        if ($value) {
            & git -C $dir config $key $value
        } else {
            & git -C $dir config --unset $key
        }
    }
    & git -C $dir config --unset-all credential.https://github.com.helper
    foreach ($helper in @(& git -C $Clone config --local --get-all credential.https://github.com.helper)) {
        & git -C $dir config --add credential.https://github.com.helper $helper
    }
    return $dir
}

# Calls one hook of the project's plugins (plugins.ps1; docs/PLUGINS.md) for $copy, the checkout the call is about.
# -Report: between jobs the worker's state says what a plugin does (`opening` with its words), kept fresh, so the queue
# app does not read a long wait (a first import) as a silent script. Not over a held run: its state names the run, and
# the app and the other scripts read a state without one as a run that has ended. A hook that throws stops the call.
function Invoke-WorkerHooks([string] $hook, [string] $copy, [switch] $Report) {
    $log = { param($text) Write-Log "$text" }
    # Not $report: PowerShell names ignore case, so that is the switch, and it takes no script block.
    $say = if ($Report) {
        { param($text) if (-not (Test-Path $pausedFile)) { Write-State 'opening' @{ report = [string]$text } } }
    } else {
        # In a run (Invoke-Worker): the plugin's words keep the run's state fresh, so the wait for a passive worker's
        # environment does not read as a silent script either.
        { param($text) if ($script:running) { Write-State 'running' $script:running } }
    }
    return Invoke-Hooks $plugins $hook $Project $copy $Id $queueDir (Read-Settings) $say $log
}

# The settings (docs/QUEUE.md, Settings): the project's own with the PC's (pc.ps1, Read-ProjectSettings), read before
# every decision and run so a change applies from the next.
function Read-Settings {
    return Read-ProjectSettings $Project
}

# The account register: which login each use runs on (`worker:N`, `frontdesk`, `personal`), so moving a use to
# another account is one edit. Human uses are every use but a worker's: only those keep room free.
function Get-Accounts {
    $json = Read-Settings
    $accounts = @()
    if ($json -and $json.accounts) {
        foreach ($property in $json.accounts.PSObject.Properties) {
            # Only the accounts of this worker's provider: another coding tool's login is no login to it.
            if (-not (Test-AccountOf $property.Value $provider.Name)) {
                continue
            }
            $uses = @($property.Value.uses | Where-Object { $_ })
            $accounts += @{
                Name = $property.Name; ConfigDir = $property.Value.configDir; Account = Get-Account $property.Value.configDir
                Uses = $uses; Human = @($uses | Where-Object { $_ -notlike 'worker:*' } | Sort-Object)
                StopAt = $property.Value.stopAt; PickUp = $property.Value.pickUp
            }
        }
    }
    return $accounts
}

# A worker's settings, its own entry over the shared one; its login is the account the register gives it, else the
# Windows user's command-line login. `model` is the shared one only: the project's override of every worker's
# mapping. It names a model of the default provider, so a worker on another coding tool leaves it. `passive` is the
# worker's own only (docs/QUEUE.md, A passive worker): the page's Config sets it there.
function Get-RunSettings([int] $worker) {
    $settings = @{ model = $null; configDir = $null; sizes = $null; ghConfigDir = $null; passive = $false }
    $json = Read-Settings
    if (-not $json) {
        return $settings
    }
    $own = $null
    if ($json.workers) {
        $own = $json.workers."$worker"
    }
    if ($isDefault -and $json.model) {
        $settings.model = $json.model
    }
    foreach ($key in @('sizes', 'ghConfigDir')) {
        if ($own -and $own.$key) {
            $settings[$key] = $own.$key
        } elseif ($json.$key) {
            $settings[$key] = $json.$key
        }
    }
    $settings.passive = [bool]($own -and $own.passive -eq $true)
    $entry = Get-Accounts | Where-Object { $_.Uses -contains "worker:$worker" } | Select-Object -First 1
    if ($entry) {
        $settings.configDir = $entry.ConfigDir
    }
    return $settings
}

# The worker's GitHub identity: with a signed-in `ghConfigDir`, this script's gh calls, its run's gh calls and pushes
# (gh as the clone's git credential helper) and the clone's commit author are that bot account, so GitHub notifies the
# owner of what the worker does. Without it, all of that is the owner's own login.
function Set-GitHubIdentity([string] $ghConfigDir) {
    $ErrorActionPreference = 'Continue'
    if ($ghConfigDir) {
        $env:GH_CONFIG_DIR = $ghConfigDir
        $user = (& gh api user 2>$null) | ConvertFrom-Json
        if ($user -and $user.login) {
            if ($script:identity -ne $user.login) {
                $gh = (Get-Command gh).Source.Replace('\', '/')
                & git -C $Clone config user.name $user.login
                & git -C $Clone config user.email "$($user.id)+$($user.login)@users.noreply.github.com"
                & git -C $Clone config --replace-all credential.https://github.com.helper ''
                & git -C $Clone config --add credential.https://github.com.helper "!'$gh' auth git-credential"
                $script:identity = $user.login
                Write-Log "GitHub identity: $($user.login)"
            }
            return
        }
        Write-Log "GitHub identity: $ghConfigDir isn't signed in, using the owner's login"
    }
    Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    if ($script:identity) {
        foreach ($key in @('user.name', 'user.email')) {
            & git -C $Clone config --unset $key
        }
        & git -C $Clone config --unset-all credential.https://github.com.helper
        $script:identity = $null
        Write-Log 'GitHub identity: the owner''s login'
    }
}

# Off in the settings (`workers.<id>.enabled: false`), e.g. while no account is linked to it (docs/QUEUE.md, Settings).
function Test-Enabled([int] $worker) {
    $json = Read-Settings
    return -not ($json -and $json.workers -and $json.workers."$worker" -and $json.workers."$worker".enabled -eq $false)
}

# Whether the owner's Now (docs/QUEUE.md, Now) names another ticket than this job's: the job's run then ends at its
# next checkpoint and is not held, and a run held at a checkpoint is freed.
function Test-NowElsewhere($job) {
    $now = Read-Now $forceFile
    return [bool]($now -and $now -ne [int]$job.Ticket)
}

# The plugins close what Start opened in the worker's copy and in the checkouts of other repos it ran in
# (docs/PLUGINS.md, Close).
function Close-Environment {
    $list = Join-Path $queueDir 'checkouts.txt'
    $checkouts = @($Clone) + @(if (Test-Path $list) { Get-Content $list })
    Close-Checkouts $plugins $checkouts $Project $Id $queueDir (Read-Settings) { param($text) Write-Log "$text" }
    $script:environmentOpen = $false
}

# A passive worker that waits with no run and none held closes its environment (docs/QUEUE.md, A passive worker). Once
# for each time it was opened, and once after the script starts: the run before a restart may have left it open, so an
# editor the owner opened by hand in a passive worker's copy closes then too. A held run keeps it: Close saves nothing.
$script:environmentOpen = $true
function Close-WhenPassive {
    if ($script:environmentOpen -and (Get-RunSettings $Id).passive -and -not (Test-Path $pausedFile)) {
        Close-Environment
    }
}

# Disabled: its paused run is dropped (its ticket goes back to the queue, Get-NextJob). As it becomes disabled, the
# plugins close its environment (Close-Environment). Only then: an editor the owner opens later in a disabled copy
# stays open.
function Disable-Worker {
    if (Test-Path $pausedFile) {
        Remove-Item $pausedFile
        Write-Log 'disabled: dropped the paused run; its ticket goes back to the queue'
    }
    $was = try { (Get-Content (Join-Path $mainQueueDir "worker-$Id.json") -Raw | ConvertFrom-Json).state } catch { '' }
    Write-State 'disabled'
    if ($was -ne 'disabled') {
        Close-Environment
    }
}

# Usage is per account: runs on the same login share it.
function Get-Account([string] $configDir) {
    if ($configDir) {
        return $configDir
    }
    return 'default'
}

function Get-ConfigDir([string] $account) {
    if ($account -eq 'default') {
        return $null
    }
    return $account
}

# An account's login as the provider reads it (docs/PLUGINS.md, GetLogin): @{ SignedIn; Email; Plan; PlanSize; Stamp },
# read each time, so a sign-in or a plan change applies at once. With a provider that cannot tell: signed in, on a plan
# of size 1.
function Get-Login([string] $account) {
    $login = Invoke-Provider 'GetLogin' @{ Login = [string](Get-ConfigDir $account) }
    if (-not $login) {
        return @{ SignedIn = $true; Email = ''; Plan = ''; PlanSize = 1.0; Stamp = '' }
    }
    return $login
}

# The login's plan size, relative to the provider's smallest plan: a run costs a bigger plan a smaller share.
function Get-AccountPlanSize([string] $account) {
    $size = [double](Get-Login $account).PlanSize
    return $(if ($size -gt 0) { $size } else { 1.0 })
}

# The login's email; '' when signed out.
function Get-LoginEmail([string] $account) {
    return [string](Get-Login $account).Email
}

# A log the run is still writing: open it shared.
function Read-Log([string] $log) {
    if (-not (Test-Path $log)) {
        return ''
    }
    $stream = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {
        return (New-Object System.IO.StreamReader($stream)).ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

# The plan's usage from a run's log, its last (or first) reading. $null for a log without one, and with a provider that
# reads none: its workers then run until the plan refuses.
function Get-Usage([string] $text, [switch] $First) {
    return ConvertTo-Reading (Invoke-Provider 'ReadUsage' @{ Text = $text; First = [bool]$First }) (Get-Now)
}

# A window's share in use now: nothing once it has reset.
function Get-Used($usage, [string] $window) {
    if (-not $usage -or -not $usage.$window -or [long]$usage.$window.resetsAt -le (Get-Now)) {
        return 0.0
    }
    return [double]$usage.$window.used
}

function Read-AllUsage {
    return Read-RecordFile $usageFile
}

# Shared with the other workers of every project of the PC and with the pages, per account (budget.ps1, Save-Reading).
function Save-Usage([string] $account, $usage) {
    $usage.email = Get-LoginEmail $account
    Save-Reading $usageFile $account $usage
}

# The account's record that a window of some models is used up until its reset (limits.ps1, Test-WindowOut), from a
# reading whose request the window refused, also when the reading had no such window: without it, a refused start
# would give its ticket back to this account every poll.
function Save-WindowOut([string] $account, [string] $window, $usage) {
    $record = if ($usage) { $usage } else { @{ at = 0 } }
    if (-not (Test-WindowOut $record $window (Get-Now))) {
        $resetsAt = if ($record.refusedResetsAt -gt (Get-Now)) { [long]$record.refusedResetsAt } else { (Get-Now) + 86400 }
        $record[$window] = @{ used = 1.0; resetsAt = $resetsAt }
        Save-Usage $account $record
    }
}

# An account's usage, read again with a probe when the last reading is older than $maxAge seconds (30 minutes: idle
# accounts get no run events, and the owner's own sessions spend them too). A window of some models it may not read:
# the queue app shows that window's read time.
function Get-FreshUsage([string] $configDir, [int] $maxAge = 1800) {
    $account = Get-Account $configDir
    $stored = (Read-AllUsage)[$account]
    # A reading of another account is no reading: the folder's login changed since.
    if ($stored -and [string]$stored.email -ne (Get-LoginEmail $account)) {
        $stored = $null
    }
    if ($stored -and (Get-Now) - [long]$stored.at -lt $maxAge) {
        return $stored
    }
    $reply = Invoke-Probe $configDir
    if (-not $reply -or -not $reply.usage) {
        # A refused probe finds an account that is out before a ticket is claimed for it. Not for 'start': one
        # failed request is no proof, and a record stops every worker on the account.
        if ($reply -and $reply.answered -and $reply.kind -in @('login', 'subscription') -and -not (Read-Out)[$account]) {
            Set-Out $account (New-OutRecord $reply.kind $reply.text (Get-LoginStamp $account))
            Write-Log "$account is out ($($reply.kind)): $($reply.text)"
        }
        return $stored
    }
    Save-Usage $account $reply.usage
    return $reply.usage
}

# A probe (docs/PLUGINS.md, GetProbe): the cheapest request that shows an account's usage and whether the account takes
# requests, in a folder that holds no project; a refused one costs nothing. @{ usage (the reading, $null without one);
# answered (it got a reply, a refusal too); kind (of the refusal, limits.ps1, $OutKinds; '' when the account answered);
# text }. $null: the probe itself failed or passed its time limit (plugins.ps1, $ProbeSeconds), or the provider has
# none.
function Invoke-Probe([string] $configDir) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-$($config.name)-probe"
    New-Item -ItemType Directory -Force $dir | Out-Null
    try {
        $reply = Invoke-ProviderProbe ([string]$configDir) $dir
    } catch {
        Write-Log "probe error: $_"
        return $null
    }
    if (-not $reply) {
        return $null
    }
    return @{ usage = (ConvertTo-Reading $reply.Usage (Get-Now)); answered = [bool]$reply.Answered; kind = [string]$reply.Kind; text = [string]$reply.Text }
}

# The login a folder holds now: what the provider says changes with a sign-in (when its credentials were last
# written), and its email.
function Get-LoginStamp([string] $account) {
    $login = Get-Login $account
    return "$($login.Stamp) $($login.Email)"
}

# Accounts that are out (`out.json` in the PC's folder, shared by the workers and the queue app): an account that refused a run
# for its subscription or its login, or on which neither a run nor a probe could start (limits.ps1, $OutKinds). Per
# account: the kind, the refusal's text, the time of the last test and the login then. The fact is the account's, not
# a ticket's: no worker starts a run on it, no dispatcher gives its workers a ticket, and the app shows it on the
# account's card and on each of its workers' cards. A worker whose runs do not start although its account answers (a
# wrong setting) has a record of its own, under `worker:<id>`: only that worker stops.
$outFile = Join-Path $PcDir 'out.json'
function Read-Out {
    return Read-RecordFile $outFile
}

# $stamp: what a change of ends the wait early. An account's login (Get-LoginStamp), a worker's settings.
function New-OutRecord([string] $kind, [string] $text, [string] $stamp) {
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) {
        $text = $text.Substring(0, 297) + '...'
    }
    return @{ kind = $kind; text = $text; at = (Get-Now); login = $stamp }
}

# When the settings were last written, the project's and the PC's: the owner's change may be the fix of a worker whose
# runs do not start.
function Get-SettingsStamp {
    return (@((Join-Path $mainQueueDir 'settings.json'), (Join-Path $PcDir 'settings.json')) |
        ForEach-Object { if (Test-Path $_) { (Get-Item $_).LastWriteTimeUtc.Ticks } else { 0 } }) -join ' '
}

# $record: $null removes the account's record. Under the lock of the accounts' records and written whole, as usage.json
# (budget.ps1, Save-Reading).
function Set-Out([string] $account, $record) {
    $lock = Enter-PcLock 'Usage'
    try {
        $all = Read-Out
        $all.Remove($account)
        if ($record) {
            $all[$account] = $record
        }
        Save-JsonFile $outFile $all
    } finally {
        Exit-PcLock $lock
    }
}

# The record that stops this worker's next run, $null when it may start: this worker's own, else its account's.
# - The worker's own (two runs in a row did not start although its account answers a probe): no test can prove the
#   fix, so the record goes after an hour, or at once when the settings change, and the next run is the test. The
#   worker keeps its ticket meanwhile.
# - An account that is out: tested again every 10 minutes, and at once when the folder's login changed (the owner
#   signed it in again). The test is a probe, not a run: no ticket is claimed for it, and the worker's card stays as
#   it is until the account answers.
function Get-Out([string] $configDir) {
    $own = (Read-Out)[$me]
    if ($own) {
        if ((Get-SettingsStamp) -eq $own.login -and (Get-Now) - [long]$own.at -lt 3600) {
            return $own
        }
        Set-Out $me $null
        Write-Log 'tries a run again'
    }
    $account = Get-Account $configDir
    $record = (Read-Out)[$account]
    if (-not $record) {
        return $null
    }
    if ((Get-LoginStamp $account) -eq $record.login -and (Get-Now) - [long]$record.at -lt 600) {
        return $record
    }
    $reply = Invoke-Probe $configDir
    # With a provider that has no probe, the next run is the test.
    if (-not (Test-ProviderHook 'Probe') -or ($reply -and $reply.answered -and $OutKinds -notcontains $reply.kind)) {
        Set-Out $account $null
        Write-Log "$account takes runs again"
        return $null
    }
    # A probe with no reply keeps what the last refusal said.
    $stamp = Get-LoginStamp $account
    $record = if ($reply -and $reply.answered) { New-OutRecord $reply.kind $reply.text $stamp } else { New-OutRecord $record.kind $record.text $stamp }
    Set-Out $account $record
    return $record
}

# The owner's picks on a worker's card (models, advisor, compact sizes): the worker's mapping for this coding tool
# (project.ps1, Get-WorkerMapping). $worker: this worker, or another of this tool that the dispatcher judges.
function Read-Picks([string] $worker = "$Id") {
    $toolConfig = Get-ProviderConfig $config $isDefault
    $here = @(Get-ChildItem (Join-Path $mainQueueDir 'worker-*.json') | ForEach-Object { $_.BaseName.Substring(7) })
    return (Get-WorkerMapping (Read-Settings) $worker ([string]$provider.Name) (Get-OwnComplexities (Read-Models) $toolConfig) $here).picks
}

# The ticket complexities (project.ps1, Get-Complexities): the provider's models with the project's over them, and
# the models and compact sizes of the worker's mapping.
function Get-ProjectComplexities([string] $worker = "$Id") {
    return Get-Complexities (Read-Models) (Get-ProviderConfig $config $isDefault) (Read-Picks $worker)
}


# The playbooks a run follows, in order (docs/PLUGINS.md, The playbook): the base's and each plugin's, copied into the
# clone's queue folder before each run, then the project's own from origin/main of the clone. The run reads the copies:
# it gets no folder of Scriptorium or of a plugin, so it cannot change the code that runs it. The base's parts
# (playbook/PLAYBOOK-*.md) go beside its copy, unnamed: PLAYBOOK.md says when a run reads each.
function Get-Playbooks {
    $folder = Join-Path $queueDir 'playbooks'
    New-Item -ItemType Directory -Force $folder | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'playbook/PLAYBOOK-*.md') $folder -Force
    $sources = [ordered]@{ 'PLAYBOOK.md' = (Join-Path $PSScriptRoot 'PLAYBOOK.md') }
    foreach ($plugin in $plugins) {
        $sources["plugin-$($plugin.Name).md"] = Join-Path $plugin.Dir 'PLAYBOOK.md'
    }
    $books = @()
    foreach ($name in $sources.Keys) {
        if (Test-Path $sources[$name]) {
            Copy-Item $sources[$name] (Join-Path $folder $name) -Force
            $books += "$($folder.Replace('\', '/'))/$name"
        }
    }
    if ($config.playbook) {
        $books += "git -C '$($Clone.Replace('\', '/'))' show origin/main:$($config.playbook)"
    }
    return $books -join ', then '
}

# Models an account was refused (`access.json` in the PC's folder, per account the time of the refusal): skipped for a day, then
# tried again, so a plan that gains a model finds it. A refused start costs nothing. Saved by Save-ModelRefused
# (budget.ps1).
function Read-Access {
    return Read-RecordFile $accessFile
}

# One of an account's lines in a window of some models, 'stop' or 'start' (queue app, Accounts; limits.ps1,
# Get-ModelLines).
function Get-ModelLine([string] $account, [string] $window, [string] $line) {
    $entry = @(Get-Accounts) | Where-Object { $_.Account -eq $account } | Select-Object -First 1
    return (Get-ModelLines $window $(if ($entry) { $entry.StopAt }) $(if ($entry) { $entry.PickUp })).$line
}

# -Advisor: whether the model can be a run's advisor, else whether a run can start on it.
function Test-ModelRefused([string] $account, [string] $model, [switch] $Advisor) {
    # The limit of the model's window on the account (limits.ps1) until the reset: from its start line no run starts on
    # the model there, from its stop line no run gets the model as its advisor.
    $window = Get-ModelWindow $model
    if ($window -and (Test-WindowOut (Read-AllUsage)[$account] $window (Get-Now) (Get-ModelLine $account $window $(if ($Advisor) { 'stop' } else { 'start' })))) {
        return $true
    }
    if (-not $model) {
        return $false
    }
    $refusedAt = (Read-Access)[$account].$model
    return $refusedAt -and (Get-Now) - [long]$refusedAt -lt 86400
}

# Whether an account has a model for a ticket complexity now: the owner's override, else a candidate of the
# complexity, that the plan did not refuse in the last day and whose window is not at its limit (Test-ModelRefused).
# Without one a run only gets refused: no dispatcher gives a worker on that account a ticket of the complexity, and the
# ticket waits for another account, the next day (the model is tried again) or the window's reset. $worker: the worker
# whose mapping names the candidates, as two workers on one account can run a complexity on two models.
function Test-ModelLeft([string] $complexity, $settings, [string] $account, [string] $worker = "$Id") {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    $picks = if ($settings.model) { @([string]$settings.model) } else { Get-ComplexityModels (Get-ProjectComplexities $worker) $complexity }
    return [bool]($picks | Where-Object { -not (Test-ModelRefused $account ($_ -split '@')[0]) })
}

# The model and effort a run of this ticket's complexity uses on this account: the settings' `model` if set (the
# owner's override), else the first of the complexity's candidates (docs/QUEUE.md, Models), best first, that the
# account wasn't refused; at the effort a candidate names after `@` (`model@high`), else that model's in the provider's
# models.json (project.ps1, Split-Pick). No candidate left: the last. Its refusal sends a ticket back to
# the queue (Test-ModelLeft then holds it there) and parks a PR's job. -After: the `after` pick of a window of some
# models, for the rest of a job whose account reached that window's limit (docs/QUEUE.md, A model's limit).
function Get-RunModel([string] $complexity, $settings, [string] $account, [string] $After) {
    $list = Read-Models
    if (-not $complexity) {
        $complexity = 'medium'
    }
    if ($After) {
        $pick = [string]$ModelWindows[$After].after
    } elseif ($settings.model) {
        $pick = [string]$settings.model
    } else {
        $candidates = Get-ComplexityModels (Get-ProjectComplexities) $complexity
        $pick = [string]($candidates | Where-Object { -not (Test-ModelRefused $account ($_ -split '@')[0]) } | Select-Object -First 1)
        if (-not $pick -and $candidates.Count) {
            $pick = [string]$candidates[-1]
        }
    }
    $run = Split-Pick $list $pick
    return @{ Model = $run.model; Effort = $run.effort }
}

# What the workers may spend of an account's windows (limits.ps1): per window its share used, the ceiling, the
# pick-up limit of each ticket size and the seconds left before it resets. Each human use the register gives the
# account keeps room under the stop line of the window that keeps (limits.ps1, $KeepWindow): its share for the time left.
function Get-Budget([string] $account, $usage) {
    $settings = Read-Settings
    $entry = @(Get-Accounts) | Where-Object { $_.Account -eq $account } | Select-Object -First 1
    $budget = @{}
    foreach ($window in $windows) {
        $used = Get-Used $usage $window
        $left = [long]$WindowSeconds[$window]
        if ($usage -and $usage.$window -and [long]$usage.$window.resetsAt -gt (Get-Now)) {
            $left = [long]$usage.$window.resetsAt - (Get-Now)
        }
        $reserve = 0.0
        # Only one window keeps a reserve: the others fill to their margin on any account.
        if ($entry -and $window -eq $KeepWindow) {
            foreach ($use in $entry.Human) {
                $reserve += Get-Reserve (Get-Keep $use $settings) $left
            }
        }
        # The account's own stop line (queue app, Accounts), else the default.
        $stopAt = if ($entry -and $entry.StopAt) { $entry.StopAt.$window } else { $null }
        $budget[$window] = @{ used = $used; ceiling = Get-Ceiling $reserve $window $stopAt; left = $left
            pickUp = Get-PickUp $(if ($entry) { $entry.PickUp }) $window }
    }
    return $budget
}

# Idle workers that could take a new ticket now, this one first, each with its account's budget and settings. Only
# the workers on this worker's coding tool: another tool's account has other windows and another probe, and its own
# workers give its tickets out.
function Get-Candidates {
    $candidates = @()
    $register = Read-Settings
    foreach ($worker in Get-WorkerStates) {
        $state = $worker.State
        if ($worker.Worker -ne $Id -and [string](Get-WorkerProvider $register "$($worker.Worker)" $providers).Name -ne $provider.Name) {
            continue
        }
        # An idle state older than two polls is a worker script that stopped.
        if ($worker.Worker -ne $Id -and ($state.state -ne 'idle' -or (Get-Now) - [long]$state.at -gt 2 * $PollSeconds + 60)) {
            continue
        }
        $settings = Get-RunSettings $worker.Worker
        # A passive worker gets no new ticket from the queue (docs/QUEUE.md, A passive worker).
        if ($settings.passive) {
            continue
        }
        $account = Get-Account $settings.configDir
        # An account that is out takes no ticket (Get-Out); its worker may not have seen the record yet. Looked at
        # again after the reading: its probe can find the account out.
        if ((Read-Out)[$account]) {
            continue
        }
        $usage = Get-FreshUsage $settings.configDir
        if ((Read-Out)[$account]) {
            continue
        }
        $candidates += @{
            Worker = $worker.Worker; Settings = $settings; Account = $account; Usage = $usage
            Budget = Get-Budget $account $usage
        }
    }
    return $candidates
}

# Best fit: among the candidates that take a ticket of this size now (Get-Fit), the one whose free room in the longest
# window most wants spending before its reset, then the most room in the shortest. $null when none takes it. With a
# provider that reads no usage: the first candidate.
function Select-Worker([string] $size, $candidates) {
    $best = $null
    $bestPace = $null
    $bestRoom = $null
    foreach ($candidate in $candidates) {
        if (-not (Get-Fit $size $candidate.Budget)) {
            continue
        }
        $room = @{}
        foreach ($window in $windows) {
            $room[$window] = $candidate.Budget[$window].ceiling - $candidate.Budget[$window].used
        }
        $pace = if ($LongWindow) { Get-Pace $room[$LongWindow] $candidate.Budget[$LongWindow].left } else { 0.0 }
        $short = if ($ShortWindow) { $room[$ShortWindow] } else { 0.0 }
        if (-not $best -or $pace -gt $bestPace -or ($pace -eq $bestPace -and $short -gt $bestRoom)) {
            $best = $candidate
            $bestPace = $pace
            $bestRoom = $short
        }
    }
    return $best
}

# What this worker does next: its own PRs (answers to apply, then conflicts), then its own ticket without a PR
# (answered, or a run cut short), then a new ticket: in queue order (priority, then the bigger ticket, then the older
# one), each goes to the idle worker it fits best; this
# worker claims the first that falls to it. Called under the queue mutex, so two workers never claim the same ticket.
function Get-NextJob {
    $issues = @(Get-GhJson @('issue', 'list', '--state', 'open', '--limit', '500', '--json', 'number,title,labels,body,createdAt'))
    $open = @($issues | ForEach-Object { $_.number })
    # Worker PRs live in this repo and in every other one an open ticket names; branch t<N> is ticket N's in any.
    $slugs = @(@($repo) + @($issues | ForEach-Object { Get-TicketRepo $_ }) | Sort-Object -Unique)
    $prs = @()
    foreach ($slug in $slugs) {
        $prs += @(Get-GhJson @('pr', 'list', '--state', 'open', '--limit', '200', '--json', 'number,headRefName,labels') $slug |
            ForEach-Object { $_ | Add-Member -NotePropertyName Repo -NotePropertyValue $slug -PassThru })
    }
    $prBranches = @($prs | ForEach-Object { $_.headRefName })
    # The complexities the owner switched off for a worker (limits.ps1): it takes no new ticket of one, and its
    # PRs' answers and rebases wait. A ticket already started goes on: a hold would strand its area and its work.
    $settings = Read-Settings

    # A disabled worker's claims, once its last run has ended, and a removed worker's (the queue app's Remove: it has no
    # state file): its PRs and the tickets they close become this worker's; a ticket without a PR goes back to the
    # queue, for whichever worker fits it.
    $gone = @(Get-WorkerStates | Where-Object {
        $_.Worker -ne $Id -and -not (Test-Enabled $_.Worker) -and
            ($_.State.state -ne 'running' -or (Get-Now) - [long]$_.State.at -gt 2 * $PollSeconds + 60)
    } | ForEach-Object { "worker:$($_.Worker)" })
    $known = @(Get-ChildItem (Join-Path $mainQueueDir 'worker-*.json') | ForEach-Object { "worker:$($_.BaseName.Substring(7))" })
    foreach ($item in @($issues) + @($prs)) {
        $from = Get-Names $item | Where-Object { $gone -contains $_ -or ($_ -match '^worker:\d+$' -and $known -notcontains $_) } |
            Select-Object -First 1
        if (-not $from) {
            continue
        }
        $isPr = [bool]$item.headRefName
        $where = if ($isPr) { $item.Repo } else { $repo }
        $labels = @($item.labels | Where-Object { $_.name -ne $from })
        if ($isPr -or $prBranches -contains "t$($item.number)") {
            & gh $(if ($isPr) { 'pr' } else { 'issue' }) edit $item.number --remove-label $from --add-label $me -R $where | Out-Null
            $labels += [pscustomobject]@{ name = $me }
            Write-Log "adopted $where#$($item.number) from $from"
        } else {
            & gh issue edit $item.number --remove-label $from -R $where | Out-Null
            Write-Log "requeued #$($item.number) from $from"
        }
        $item.labels = $labels
    }

    # Now (docs/QUEUE.md, Now): the ticket this worker's force file names with `now` goes before all its other jobs. A
    # ticket that left the queue meanwhile ends the Now: the worker takes no other ticket in its place. The owner gave
    # it by hand, so the worker's complexity switches do not count (docs/QUEUE.md, Complexity switches).
    $now = Read-Now $forceFile
    if ($now) {
        $ticket = Select-Now $issues $now $me $prBranches
        if ($ticket) {
            & gh issue edit $ticket.number --add-label $me -R $repo | Out-Null
            Write-Log "now: #$($ticket.number) onto worker $Id"
            return @{ Kind = 'ticket'; Ticket = $ticket.number; Title = $ticket.title; Repo = Get-TicketRepo $ticket; Size = Get-Size $ticket
                Complexity = Get-Complexity $ticket; Blockers = @(Get-Blockers $ticket $open) }
        }
        Remove-Item $forceFile -ErrorAction SilentlyContinue
        Write-Log "now: #$now left the queue, so the Now ends"
    }

    # Queue next, forced (docs/QUEUE.md, Queue next): the ticket the owner queued as this worker's next and forced with
    # the arrow goes before its other jobs, by the rules of a Now's ticket. Its claim carries it from here, so the next
    # file goes; the force file makes its run a forced run. A ticket that left the queue ends it, and the worker takes no
    # other job this pass: it came here past the stop line (the main loop).
    $forcedNext = Read-Next $nextFile -Forced
    if ($forcedNext) {
        Remove-Item $nextFile -ErrorAction SilentlyContinue
        $ticket = Select-Now $issues $forcedNext $me $prBranches
        if ($ticket) {
            Set-Content $forceFile (@{ ticket = $ticket.number } | ConvertTo-Json -Compress) -Encoding utf8
            & gh issue edit $ticket.number --add-label $me -R $repo | Out-Null
            Write-Log "next: forced #$($ticket.number) onto worker $Id"
            return @{ Kind = 'ticket'; Ticket = $ticket.number; Title = $ticket.title; Repo = Get-TicketRepo $ticket; Size = Get-Size $ticket
                Complexity = Get-Complexity $ticket; Blockers = @(Get-Blockers $ticket $open) }
        }
        Write-Log "next: #$forcedNext left the queue"
        return $null
    }

    foreach ($kind in @('answered', 'needs-rebase')) {
        $pr = $prs | Where-Object {
            $n = Get-Names $_
            $branch = $_.headRefName
            $n -contains $me -and $n -contains $kind -and $n -notcontains 'needs-owner' -and
                -not (Test-ComplexityOff (Get-Complexity ($issues | Where-Object { "t$($_.number)" -eq $branch } | Select-Object -First 1)) $settings "$Id")
        } | Select-Object -First 1
        if ($pr) {
            $number = [int]$pr.headRefName.Substring(1)
            $ticket = $issues | Where-Object { $_.number -eq $number } | Select-Object -First 1
            return @{ Kind = $kind; Ticket = $number; Title = $ticket.title; Pr = $pr.number; Repo = $pr.Repo; Complexity = Get-Complexity $ticket }
        }
    }

    $resume = $issues | Where-Object {
        $n = Get-Names $_
        $n -contains $me -and $n -notcontains 'needs-owner' -and $prBranches -notcontains "t$($_.number)"
    } | Sort-Object createdAt | Select-Object -First 1
    if ($resume) {
        # Blockers: only a ticket that a Now claimed has open ones.
        return @{ Kind = 'ticket'; Ticket = $resume.number; Title = $resume.title; Repo = Get-TicketRepo $resume; Size = Get-Size $resume
            Complexity = Get-Complexity $resume; Blockers = @(Get-Blockers $resume $open) }
    }

    # Areas held by any ticket in flight: claimed by a worker and not parked on a question. Another repo counts as an
    # area of its own.
    $busy = @($issues | Where-Object {
        $n = Get-Names $_
        ($n | Where-Object { $_ -like 'worker:*' }) -and $n -notcontains 'needs-owner'
    } | ForEach-Object { Get-Names $_ } | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })

    # Queue next (docs/QUEUE.md, Queue next): the ticket the owner queued as this worker's next is its next new ticket,
    # in place of the queue's. It waits as a queue's ticket does: for its blockers and its areas (Get-NextWait), for a
    # model the account has left and for the pick-up limit of its size. While it waits, the file stays and this worker
    # takes no other new ticket (the dispatcher below gives it none). Its claim carries it from here, so the file goes;
    # so does one whose ticket left the queue. The worker's complexity switches do not count for it. On a passive
    # worker it waits for the arrow, which forces it (above).
    $passive = (Get-RunSettings $Id).passive
    $queuedNext = Read-Next $nextFile
    if ($queuedNext) {
        $ticket = Select-Now $issues $queuedNext $me $prBranches
        if (-not $ticket) {
            Remove-Item $nextFile -ErrorAction SilentlyContinue
            Write-Log "next: #$queuedNext left the queue"
        } elseif (-not $passive -and -not (Get-NextWait $ticket $open $busy)) {
            $own = Get-RunSettings $Id
            $account = Get-Account $own.configDir
            if ((Test-ModelLeft (Get-Complexity $ticket) $own $account) -and
                (Get-Fit (Get-Size $ticket) (Get-Budget $account (Get-FreshUsage $own.configDir)))) {
                Remove-Item $nextFile -ErrorAction SilentlyContinue
                & gh issue edit $ticket.number --add-label $me -R $repo | Out-Null
                Write-Log "next: #$($ticket.number) onto worker $Id"
                return @{ Kind = 'ticket'; Ticket = $ticket.number; Title = $ticket.title; Repo = Get-TicketRepo $ticket; Size = Get-Size $ticket
                    Complexity = Get-Complexity $ticket }
            }
        }
    }
    # A passive worker takes no new ticket from the queue: only what the owner gave it, and its own PRs and tickets.
    if ($passive) {
        return $null
    }

    # A ticket that another worker's force file names for Now waits for that worker, and so does one queued as another
    # worker's next (this worker's own is read above).
    $reserved = @(Get-ChildItem (Join-Path $mainQueueDir 'force-*.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "force-$Id.json" } | ForEach-Object { Read-Now $_.FullName } | Where-Object { $_ }) +
        @(Get-ChildItem (Join-Path $mainQueueDir 'next-*.json') -ErrorAction SilentlyContinue | ForEach-Object { Read-Next $_.FullName } | Where-Object { $_ })
    $queued = @($issues | Where-Object {
        $n = Get-Names $_
        ($n | Where-Object { $_ -match '^P[0-2]$' }) -and -not ($n | Where-Object { $_ -like 'worker:*' -or $_ -eq 'needs-owner' }) -and
            $reserved -notcontains $_.number
    })
    # A ticket waits while a ticket its `Blocked by` line names is open.
    $queue = @($queued | Where-Object {
        @(Get-Blockers $_ $open).Count -eq 0
    } | Sort-Object @{ Expression = { Get-Priority (Get-Names $_) } }, @{ Expression = { Get-SizeRank (Get-Size $_) } }, createdAt)
    if ($queue.Count -eq 0) {
        return $null
    }

    # Forced: the ticket the queue app showed as this worker's next, which its force file names, whatever its area or
    # size (areas.ps1, Select-Forced). Only an open blocker still holds one back.
    $mine = @($queue | Where-Object { -not (Test-ComplexityOff (Get-Complexity $_) $settings "$Id") })
    if ((Test-Path $forceFile) -and $mine.Count -gt 0) {
        $wanted = 0
        try {
            $wanted = [int](Get-Content $forceFile -Raw | ConvertFrom-Json).ticket
        } catch {
        }
        $ticket = Select-Forced $mine $wanted $busy
        & gh issue edit $ticket.number --add-label "worker:$Id" -R $repo | Out-Null
        Write-Log "forced #$($ticket.number) onto worker $Id"
        return @{ Kind = 'ticket'; Ticket = $ticket.number; Title = $ticket.title; Repo = Get-TicketRepo $ticket; Size = Get-Size $ticket
            Complexity = Get-Complexity $ticket }
    }

    # Not a worker with a ticket queued as its next: it takes that one at its next look.
    $candidates = @(Get-Candidates | Where-Object { -not (Test-Path (Join-Path $mainQueueDir "next-$($_.Worker).json")) })
    # Why each ticket this pass skipped waits, for the queue app (docs/APP.md).
    $waiting = @{}
    $nextReset = if ($ShortWindow) { @($candidates | ForEach-Object { (Get-Now) + [long]$_.Budget[$ShortWindow].left } | Sort-Object)[0] } else { Get-Now }
    while ($queue.Count -gt 0 -and $candidates.Count -gt 0) {
        # The first ticket in queue order whose areas are free and that a candidate takes: one that has its
        # complexity on, at its size.
        $pick = $null
        foreach ($ticket in $queue) {
            $areas = @(Get-Names $ticket | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })
            if ((Get-Clashes $areas $busy).Count -gt 0) {
                continue
            }
            # The page says why a ticket waits that no worker takes (app/state.ps1, Get-QueueRows).
            $complexity = Get-Complexity $ticket
            $takers = @($candidates | Where-Object { -not (Test-ComplexityOff $complexity $settings "$($_.Worker)") })
            if ($takers.Count -eq 0) {
                continue
            }
            # Only an account whose plan has a model for the complexity now (Test-ModelLeft).
            $takers = @($takers | Where-Object { Test-ModelLeft $complexity $_.Settings $_.Account "$($_.Worker)" })
            if ($takers.Count -eq 0) {
                $waiting["$($ticket.number)"] = "no idle worker's account has a model for complexity $complexity now (a plan without it, or the model's window at its limit)"
                continue
            }
            $size = Get-Size $ticket
            $best = Select-Worker $size $takers
            if (-not $best) {
                $waiting["$($ticket.number)"] = "over the pick-up limit for size ${size}: waits for a usage reset ($(Format-Time $nextReset))"
                continue
            }
            $pick = @{ Ticket = $ticket; Areas = $areas; Size = $size; Complexity = $complexity }
            break
        }
        if (-not $pick) {
            break
        }
        $ticket = $pick.Ticket
        & gh issue edit $ticket.number --add-label "worker:$($best.Worker)" -R $repo | Out-Null
        Write-Log ("assigned #$($ticket.number) (size $($pick.Size), complexity $($pick.Complexity)) to worker $($best.Worker): " +
            (($windows | ForEach-Object { "$($WindowTitles[$_]) $(Format-Share $best.Budget[$_].used) of $(Format-Share $best.Budget[$_].ceiling)" }) -join ', '))
        if ($best.Worker -eq $Id) {
            return @{ Kind = 'ticket'; Ticket = $ticket.number; Title = $ticket.title; Repo = Get-TicketRepo $ticket; Size = $pick.Size
                Complexity = $pick.Complexity }
        }
        # The other worker finds it as its own ticket on its next poll.
        $candidates = @($candidates | Where-Object { $_.Worker -ne $best.Worker })
        $busy += $pick.Areas
        $queue = @($queue | Where-Object { $_.number -ne $ticket.number })
    }
    @{ at = (Get-Now); waiting = $waiting } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $mainQueueDir 'dispatch.json') -Encoding utf8
    return $null
}

# A window of the account at or over the workers' ceiling: no new job this poll. The ceiling rises as the reset nears
# and the reserve shrinks, so the next poll looks again.
function Test-OverBudget([string] $configDir) {
    $budget = Get-Budget (Get-Account $configDir) (Get-FreshUsage $configDir)
    Save-Budget $budget
    foreach ($window in $windows) {
        if ($budget[$window].used -ge $budget[$window].ceiling) {
            $line = "usage at $(Format-Share $budget[$window].used) of $($WindowTitles[$window]), over the workers' $(Format-Share $budget[$window].ceiling); waiting"
            if ($script:overBudget -ne $line) {
                Write-Log $line
                $script:overBudget = $line
            }
            return $true
        }
    }
    $script:overBudget = $null
    return $false
}

# Saves a run's reading when its log has a new event, and returns the account's newest reading. The same event as at
# the last look is no new reading (budget.ps1, Get-ReadingKey): the stored one counts then.
function Save-RunUsage([string] $log, [string] $account, $usage) {
    $key = "$log|$(Get-ReadingKey $usage)"
    $stored = (Read-AllUsage)[$account]
    if ($key -eq $script:readingKey -and $stored -and [string]$stored.email -eq (Get-LoginEmail $account)) {
        return $stored
    }
    $script:readingKey = $key
    Save-Usage $account $usage
    return $usage
}

# While the run works: record usage. At the workers' limit, leave the run the note that ends it at its next
# checkpoint; withdraw the note if the account has room again before then (a window reset, a
# moved stop line). The note carries the whole instruction, so a run that read an older playbook follows it too.
# With a provider whose runs' logs hold no usage (budget.ps1, Test-ProbeAfterRun) the reading is a probe's, one look
# every $RunProbeSeconds, a failed one too. A newer reading of the page's Ping or of another worker on the account
# counts as it, with no probe.
function Update-Usage([string] $log, [string] $account) {
    if (Test-ProbeAfterRun (Test-ProviderHook 'ReadUsage') (Test-ProviderHook 'Probe')) {
        if ((Get-Now) - [long]$script:runProbedAt -lt $RunProbeSeconds) {
            return
        }
        $script:runProbedAt = Get-Now
        $usage = Get-FreshUsage (Get-ConfigDir $account) $RunProbeSeconds
    } else {
        $usage = Get-Usage (Read-Log $log)
        if ($usage) {
            $usage = Save-RunUsage $log $account $usage
        }
    }
    if (-not $usage) {
        return
    }
    $budget = Get-Budget $account $usage
    Save-Budget $budget
    # A forced run ignores the workers' limit; only the plan's own limit pauses it.
    if (Test-Path $forceFile) {
        return
    }
    $over = $windows | Where-Object { $budget[$_].used -ge $budget[$_].ceiling } | Select-Object -First 1
    if ($over -and -not (Test-Path $warnFile)) {
        $note = "The account's usage is at $(Format-Share $budget[$over].used) of its $($WindowTitles[$over]) window, the workers' limit " +
            "$(Format-Share $budget[$over].ceiling); it resets $(Format-Time ((Get-Now) + $budget[$over].left)). " +
            'End at your next checkpoint: commit and push, post every question you would hold as a ticket comment, post one ' +
            'handoff comment on the ticket (done, next), then end the run without a PR. The worker script holds your ' +
            'session and resumes it when the account has room. It is not a failure.'
        Set-Content $warnFile $note -Encoding utf8
        $script:limitNoted = $true
        Write-Log "limit note for #$($script:running.ticket): $note"
    } elseif (-not $over -and (Test-Path $warnFile)) {
        Remove-Item $warnFile
        Write-Log "limit note withdrawn for #$($script:running.ticket): the account has room again"
    }
}

# Every run's cost: in money where the provider reads one ($read: its ReadRun answer; less $costBefore: a resumed
# session's result counts the part before its pause again) and per window from its first and last usage readings, a
# window that reset meanwhile left out. A run that isn't a whole ticket (partial: paused, resumed, answers, rebase)
# counts toward the account's spending but not toward ticket estimates. $numbers (the provider's, docs/PLUGINS.md,
# ReadRun; none if the log could not be read) become more fields of the line, for report.ps1; the page reads the lines
# as objects and ignores them. With a provider that reads usage, a run with no reading did no request: no line.
function Add-History($job, [string] $account, [string] $model, [string] $text, [bool] $partial, [long] $startedAt, [double] $costBefore, $numbers, [bool] $resumed, $read) {
    $start = $null
    $end = $null
    try {
        $start = Get-Usage $text -First
        $end = Get-Usage $text
    } catch {
        Write-Log "usage error: $_"
    }
    if ((Test-ProviderHook 'ReadUsage') -and (-not $start -or -not $end)) {
        return
    }
    $run = @{
        account = $account; model = $model; size = $job.Size; complexity = $job.Complexity; ticket = $job.Ticket; kind = $job.Kind
        partial = $partial; at = (Get-Now); planSize = Get-AccountPlanSize $account
        # Went on in a held session: report.ps1 shows what such a start reads again.
        resumed = $resumed
    }
    # Seconds of wall time, run start to run end, for the queue app's typical run time. The wall flag marks a line
    # with this meaning; older lines hold the last turn only.
    $run.duration = $run.at - $startedAt
    $run.wall = $true
    if ($read -and $read.Ended -and $null -ne $read.Cost) {
        $run.cost = [math]::Max(0.0, [double]$read.Cost - $costBefore)
    }
    foreach ($window in $windows) {
        if ($start -and $end -and $start.$window -and $end.$window -and $start.$window.resetsAt -eq $end.$window.resetsAt) {
            $run[$window] = [math]::Max(0.0, [double]$end.$window.used - [double]$start.$window.used)
        }
    }
    if ($numbers) {
        foreach ($key in @($numbers.Keys)) {
            $run[$key] = $numbers[$key]
        }
    }
    Add-Content $historyFile ($run | ConvertTo-Json -Compress) -Encoding utf8
}

function Invoke-Worker($job, [string] $log, $paused) {
    $slug = Get-JobRepo $job
    $dir = Get-JobDir $slug
    # The environment of the job's checkout (the main loop's Start covered the clone, except a passive worker's, which
    # opens here), then what the run gets from the plugins (docs/PLUGINS.md, GetRun). A hook that throws starts no
    # run: the ticket stays this worker's.
    if ($dir -ne $Clone) {
        # Kept for Close-Environment, which closes what Start opens here.
        $list = Join-Path $queueDir 'checkouts.txt'
        if (-not ((Test-Path $list) -and @(Get-Content $list) -contains $dir)) {
            Add-Content $list $dir -Encoding utf8
        }
    }
    if ($dir -ne $Clone -or (Get-RunSettings $Id).passive) {
        $script:environmentOpen = $true
        Invoke-WorkerHooks 'Start' $dir | Out-Null
    }
    $given = Merge-RunAnswers (Invoke-WorkerHooks 'GetRun' $dir)

    # A resumed run keeps the model, effort and account its session started on.
    $settings = Get-RunSettings $Id
    $configDir = $settings.configDir
    $pick = Get-RunModel $job.Complexity $settings (Get-Account $configDir)
    # A PR's job on an account at the stop line of its model's window starts on the model after it (docs/QUEUE.md, A
    # model's limit): a start on the model would soon be refused. Between the window's two lines it still runs on it.
    $after = Get-ModelWindow $pick.Model
    if ($job.Kind -eq 'ticket' -or $paused -or -not $after -or -not $ModelWindows[$after].after -or
        -not (Test-WindowOut (Read-AllUsage)[(Get-Account $configDir)] $after (Get-Now) (Get-ModelLine (Get-Account $configDir) $after 'stop'))) {
        $after = ''
    }
    if ($after) {
        $pick = Get-RunModel $job.Complexity $settings (Get-Account $configDir) -After $after
    }
    $model = $pick.Model
    $effort = $pick.Effort
    if ($paused) {
        $model = $paused.Model
        if ($paused.Effort) {
            $effort = $paused.Effort
        }
        $configDir = $paused.ConfigDir
    }
    # The run's advisor (limits.ps1, Get-Advisor): one for the whole session, like its model, so a resume and a
    # compaction see the same tools. A session held before the advisor existed has none recorded: it gets one now.
    $advisorOf = Get-AdvisorRule (Read-Models) (Get-ProjectComplexities) (Read-Picks)
    $hasAdvisor = [bool]$advisorOf.model -and -not (Test-ModelRefused (Get-Account $configDir) ([string]$advisorOf.model) -Advisor)
    $advisor = Get-Advisor $advisorOf $job.Complexity $model $hasAdvisor
    if ($paused -and $null -ne $paused.Advisor) {
        $advisor = [string]$paused.Advisor
    } elseif (-not $paused) {
        # Without the advisor its complexity has, a higher effort where the complexity names one that makes up for it
        # (Get-FallbackEffort). A resumed session keeps its effort.
        $effort = Get-FallbackEffort $advisorOf $job.Complexity $model $effort $hasAdvisor
    }

    # The base playbook's parts (Get-Playbooks) that a message names.
    $parts = "$($queueDir.Replace('\', '/'))/playbooks"
    switch ($job.Kind) {
        'answered' { $task = "apply the owner's answers and comments on PR #$($job.Pr) and its ticket #$($job.Ticket) (branch t$($job.Ticket)), by step 8 of $parts/PLAYBOOK-jobs.md" }
        'needs-rebase' { $task = "rebase PR #$($job.Pr) (ticket #$($job.Ticket), branch t$($job.Ticket)) onto main, by step 9 of $parts/PLAYBOOK-jobs.md" }
        default { $task = "ticket #$($job.Ticket), branch t$($job.Ticket)" }
    }
    $playbooks = Get-Playbooks
    # The window of some models whose limit the account reached, for a session that goes on with the model after it.
    $out = if ($paused -and $paused.ModelOut) { [string]$paused.ModelOut } else { $after }
    $session = ''
    if ($paused -and $paused.Session) {
        $cause = if ($paused.ModelOut) {
            "Your account reached the limit of its $($WindowTitles[$out]) window, so this session goes on with $model. Read $parts/PLAYBOOK-limit.md first."
        } elseif ($paused.Stopped) { 'The owner paused your worker, and it is active again now.' } else { 'A usage limit or a lost login stopped you, and it is cleared now.' }
        # The pause can last hours, and the playbooks may change meanwhile: a resumed run shipped by old rules.
        $prompt = "$cause Checkpoint first (PLAYBOOK.md, Checkpoints). " +
            "The playbooks may have changed while you were stopped: read them again, $playbooks; where one differs " +
            "from what you read before, the new text wins. Then carry on with your job where you stopped: $task."
        $session = [string]$paused.Session
    } else {
        if ($dir -eq $Clone) {
            $prompt = "You are queue worker $Id, in your own clone. Run git fetch, then read and follow the playbooks " +
                "in this order, a later one winning where two differ: $playbooks. Your job: $task."
        } else {
            $prompt = "You are queue worker $Id, in your own clone of $slug; your ticket is in $repo. Run git fetch, then " +
                "read and follow the playbooks in this order, a later one winning where two differ: $playbooks " +
                "(Another repository applies: read $parts/PLAYBOOK-repo.md). Your job: $task."
        }
    }
    $prompt += " You run on $model$(if ($effort) { " at $effort effort" }): name $(if ($effort) { 'both' } else { 'it' }) in the PR body. Your queue folder is " +
        "$($queueDir.Replace('\', '/')): at each checkpoint write progress.json there and look for limit.md, stop.md, " +
        "comments.md and away.md there (PLAYBOOK.md, Checkpoints). The Scriptorium folder is $($PSScriptRoot.Replace('\', '/')): " +
        "run a script of it where a playbook says so, and change no file in it."
    # The rest of a job whose model reached its limit (docs/QUEUE.md, A model's limit). The note carries the whole
    # instruction, so a run that read an older playbook follows it too.
    if ($paused -and $paused.ModelOut -and $job.Kind -eq 'ticket') {
        $first = if ($paused.From) { [string]$paused.From } else { 'its first model' }
        $prompt += " The model's limit: this ticket ran on $first for its decisions, such as how a feature works, a look, " +
            'or a code structure that stays (docs/QUEUE.md, Models). If those decisions are made and ' +
            "written down (code, docs, the ticket), finish the job on $model and name both models in the PR body. If not: " +
            'commit and push, post one handoff comment on the ticket (done, the decisions still open, next), write ' +
            'handoff.md in your queue folder, and end the run without a PR. The worker script then gives the ticket to a ' +
            "worker whose account has $first left, which starts fresh from your comment."
    } elseif ($out) {
        $prompt += " Your account reached the limit of its $($WindowTitles[$out]) window, so this job runs on ${model}: the PR already " +
            "holds the ticket's decisions."
    }
    # A blocked ticket that a worker has, from a Now (docs/QUEUE.md, Now).
    if ($job.Blockers) {
        $blockers = '#' + ($job.Blockers -join ', #')
        $prompt += " Your ticket is blocked by $blockers, which is still open, and the owner wants it built now: build " +
            "it on main as it is, and do not wait for $blockers or ask about it. A merge conflict with $blockers later is accepted."
    }
    if ($given.Prompt) {
        $prompt += " $($given.Prompt)"
    }
    # What the provider starts the run from (docs/PLUGINS.md, GetCommand): the same for the run and for the compaction
    # of its session (Compress-Session). The cap of one run (docs/QUEUE.md, The cap of a run) and the compact size of
    # the job's complexity (docs/CONFIG.md, The compact size) are 0 for none.
    $compactAt = Get-ComplexityCompactAt (Get-ProjectComplexities) $job.Complexity
    $runCap = Get-RunCap (Read-Models) (Get-ProviderConfig $config $isDefault)
    $run = @{
        Prompt = $prompt; Session = $session; Model = $model; Effort = $effort; Advisor = $advisor
        CompactAt = $compactAt; Cap = $runCap; Login = [string]$configDir
        # The base's commands, the project's and the plugins', then the tool rules in the provider's own syntax.
        Commands = @(Get-RunCommands $config $given); Tools = @(Get-RunTools $config $given); McpServers = $given.McpServers
        # The playbooks, the project's rules and the usage warning stay in the clone.
        Dir = $dir; AddDirs = @(if ($dir -ne $Clone) { $Clone })
    }
    $command = Invoke-Provider 'GetCommand' @{ Copy = $dir; Run = $run }
    if (-not $command -or -not $command.FilePath) {
        throw "plugin $($provider.Name), GetCommand: it gave no command for the run"
    }
    Write-Log "compacts at $compactAt"

    Remove-Item $warnFile, $stopFile, $commentsFile, $handoffFile -ErrorAction SilentlyContinue
    Write-AwayNote $awayFile ([bool](Read-Settings).away)
    if (-not $paused) {
        Remove-Item $progressFile -ErrorAction SilentlyContinue
    }
    $account = Get-Account $configDir
    $script:running.model = $model
    $script:running.effort = $effort
    # What the run's process takes from this script's environment: what the plugins set (docs/PLUGINS.md, GetRun), then
    # the provider's own (its login, its switches). A variable with no value is taken away for the run.
    $variables = @{}
    foreach ($name in @($given.Env.Keys)) {
        $variables[$name] = $given.Env[$name]
    }
    if ($command.Env) {
        foreach ($name in @($command.Env.Keys)) {
            $variables[$name] = $command.Env[$name]
        }
    }
    $previousVariables = @{}
    foreach ($name in @($variables.Keys)) {
        $previousVariables[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $(if ($null -ne $variables[$name]) { [string]$variables[$name] }))
    }
    $runStartedAt = Get-Now
    $commentsCheckedAt = 0
    try {
        $process = Start-Process $command.FilePath -ArgumentList $command.Arguments -WorkingDirectory $dir -NoNewWindow `
            -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        # The queue app ends a run by these two (app/server.ps1, Stop-Run): the process and when it started, so a
        # number that Windows gave to another process since is never that run. Written at once.
        $script:running.pid = $process.Id
        $script:running.pidStarted = ''
        try {
            $script:running.pidStarted = [string]$process.StartTime.ToUniversalTime().Ticks
        } catch {
        }
        Write-State 'running' $script:running
        while (-not $process.HasExited) {
            # Returns at once when the run ends, so its end is not seen up to 30 seconds late.
            [void]$process.WaitForExit(30000)
            # Never let a hiccup here end the watch: the run would go on unwatched and its ticket start again.
            try {
                # First, so a failure below never makes a live script look down in the queue app.
                Write-State 'running' $script:running
                Update-Usage $log $account
                # Also for the owner's Now: this worker has another ticket to do at once.
                $stop = (Get-Control) -eq 'stop' -or -not (Test-Enabled $Id) -or (Test-NowElsewhere $job)
                if ($stop -and -not (Test-Path $stopFile)) {
                    Set-Content $stopFile ('The owner stopped this worker. At your next checkpoint: commit, push, post a ' +
                        'handoff comment on the ticket (done, next), then end. The ticket resumes later, here or on another worker.') -Encoding utf8
                    $script:stopNoted = $true
                    Write-Log "stop note for #$($job.Ticket)"
                } elseif (-not $stop -and (Test-Path $stopFile)) {
                    # The owner set the worker active again: the run goes on.
                    Remove-Item $stopFile
                    Write-Log "stop note withdrawn for #$($job.Ticket)"
                }
                # The owner may leave or come back during a run (docs/QUEUE.md, No blocking).
                Write-AwayNote $awayFile ([bool](Read-Settings).away)
                # The owner's unread comments on the ticket and the job's PR, every 2 minutes (PLAYBOOK.md, Comments).
                if ((Get-Now) - $commentsCheckedAt -ge 120) {
                    $commentsCheckedAt = Get-Now
                    $unread = @{ "ticket #$($job.Ticket)" = (Get-UnreadCount $job.Ticket $repo) }
                    $pr = $job.Pr
                    if (-not $pr) {
                        $pr = @(Get-GhJson @('pr', 'list', '--head', "t$($job.Ticket)", '--state', 'open', '--json', 'number') $slug)[0].number
                    }
                    if ($pr) {
                        $unread["PR #$pr"] = Get-UnreadCount $pr $slug
                    }
                    Write-CommentNote $commentsFile $unread
                }
            } catch {
                Write-Log "watch error: $_"
            }
        }
    } finally {
        foreach ($name in $previousVariables.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousVariables[$name])
        }
        # However the run ended, the plugins leave its environment clean (EndRun). An error there is no run's.
        try {
            Invoke-WorkerHooks 'EndRun' $dir | Out-Null
        } catch {
            Write-Log "EndRun error: $_"
        }
    }

    # What the provider reads from the run's log (docs/PLUGINS.md, ReadUsage, ReadRun). A hook that throws never loses
    # the run's end: the run then counts as one with no result (a hard stop).
    $text = Read-Log $log
    $usage = $null
    try {
        $usage = Get-Usage $text
    } catch {
        Write-Log "usage error: $_"
    }
    if ($usage) {
        [void](Save-RunUsage $log $account $usage)
    }
    # A provider whose runs' logs hold no usage (budget.ps1, Test-ProbeAfterRun): the account is read with a probe now,
    # before the next ticket is taken. Not as $usage: a probe's refusal is not this run's.
    if (Test-ProbeAfterRun (Test-ProviderHook 'ReadUsage') (Test-ProviderHook 'Probe')) {
        try {
            $reply = Invoke-Probe $configDir
            if ($reply -and $reply.usage) {
                Save-Usage $account $reply.usage
            }
        } catch {
            Write-Log "usage error: $_"
        }
    }
    $read = $null
    try {
        $read = Invoke-Provider 'ReadRun' @{ Text = $text }
    } catch {
        Write-Log "run log error: $_"
    }
    if (-not $read) {
        $read = @{}
    }
    # What the end says (limits.ps1, Get-RunEnd): the plan's limit, a model it lacks, a model window's limit (the main
    # loop requeues the ticket or holds the job for the model after it, docs/QUEUE.md, A model's limit), a refusal of
    # the account ($OutKinds), the run's cap (parked like a run without a PR, Test-Outcome, never held).
    $runEnd = Get-RunEnd $read $usage $paused
    $session = $runEnd.Session
    # A resumed session's result holds its whole cost, the part before the pause too.
    $costBefore = if ($paused -and $paused.Session -and $paused.Cost) { [double]$paused.Cost } else { 0.0 }
    $cost = [math]::Max($costBefore, [double]$read.Cost)
    # The same for its advisor's cost, the session's so far kept beside Cost (Suspend-Job). The run's numbers for the
    # history: a log they cannot be read from loses only them, never the run's end.
    $advisorBefore = if ($paused -and $paused.Session -and $paused.AdvisorCost) { [double]$paused.AdvisorCost } else { 0.0 }
    $advisorCost = $advisorBefore
    $numbers = $read.Numbers
    if ($numbers -and $null -ne $numbers.advisorCost) {
        $advisorCost = [math]::Max($advisorBefore, [double]$numbers.advisorCost)
        # shortcut: a session that goes on with another model after its model's limit counts its earlier cost as the
        # advisor's. Its lines are partial and the report leaves them out; keep the cost by model if it needs them.
        $numbers.advisorCost = [math]::Max(0.0, [double]$numbers.advisorCost - $advisorBefore)
    }
    if ($runEnd.ModelRefused) {
        Save-ModelRefused $accessFile $account $model (Get-Now)
    }
    if ($runEnd.WindowOut) {
        Save-WindowOut $account $runEnd.WindowOut $usage
    }
    # Ended at a checkpoint for the workers' limit or for the owner's pause, or at the stop note of the owner's Now,
    # its job not done (limits.ps1, Get-RunHold): the main loop holds it with its session (Suspend-Job), or frees its
    # ticket. GitHub is asked only when there is a hold to drop.
    $stopStands = Test-Path $stopFile
    $hold = Get-RunHold $runEnd (Test-NowElsewhere $job) ([bool]$script:limitNoted) ([bool]$script:stopNoted) $stopStands (Test-Enabled $Id)
    if ($hold -and (Test-Finished $job)) {
        $hold = $null
    }
    $marks = Get-RunMarks $runEnd $hold ([bool]$paused) ([string]$job.Kind) $stopStands
    if (-not $runEnd.ModelRefused) {
        Add-History $job $account $model $text $marks.Partial $runStartedAt $costBefore $numbers ([bool]$run.Session) $read
    }
    if ($marks.Compact) {
        Compress-Session $run $session "$log.compact"
    }
    return @{
        AtLimit = $marks.AtLimit
        Stopped = $marks.Stopped
        Freed = $marks.Freed
        ModelRefused = $runEnd.ModelRefused
        # The window of some models whose limit the account reached, else ''; and the model the run was on.
        ModelOut = $runEnd.WindowOut
        From = $model
        Limited = $runEnd.Limited
        Refusal = $runEnd.Refusal
        RefusalText = $runEnd.RefusalText
        Holds = $marks.Holds
        LoggedOut = $false
        # The cap that the run reached, else 0.
        Capped = $(if ($runEnd.Capped) { [double]$runCap } else { 0 })
        Session = $session
        Cost = $cost
        AdvisorCost = $advisorCost
        Usage = $usage
        Model = $model
        Effort = $effort
        Advisor = $advisor
        ConfigDir = $configDir
    }
}

# Cut off by the plan's usage limit or by its account (out: Get-Out), or ended at a checkpoint for the workers' limit
# or the owner's pause: keep the session to resume later, instead of parking the job. An account that is out is the
# owner's to fix in the queue app (Accounts), not the ticket's: no comment, and the run resumes when the account
# takes runs again. A run held at the workers' limit resumes by room, not by time (Get-RoomWait); so does a run held for
# a pause, once the owner sets the worker active.
function Suspend-Job($job, $end) {
    # Not zero for a run held for its account: the queue app reads a ticket with a reset time as a run in flight.
    $resetsAt = (Get-Now) + $(if ($end.LoggedOut) { 0 } else { 1800 })
    if (-not $end.LoggedOut -and $end.Usage -and $end.Usage.refusedResetsAt -gt (Get-Now)) {
        $resetsAt = $end.Usage.refusedResetsAt
    } elseif (-not $end.LoggedOut -and $end.Limited -and -not $end.Usage) {
        # The plan's limit ended a run whose log holds no usage (budget.ps1, Test-ProbeAfterRun), so no reading names
        # the reset: it is that of the account's full windows, from the probe when the run ended. Without it the run
        # resumed blind every 30 minutes, each time with a comment. With no full window (the service's own shortage,
        # a probe that failed): the 30 minutes. An error here must not lose the session: the 30 minutes too.
        # shortcut: a window whose stop line is 100 % counts as full only at a reading of exactly 100 %; one refused
        # just under it waits the 30 minutes again and again. Take the reset from the refusal's text if that is seen.
        try {
            $account = Get-Account $end.ConfigDir
            Save-Budget (Get-Budget $account (Read-AllUsage)[$account])
            $roomAt = Get-RoomAt $script:budget
            if ($roomAt -gt (Get-Now)) {
                $resetsAt = $roomAt
            }
        } catch {
            Write-Log "reset error: $_"
        }
    }
    if ($end.Stopped -or $end.ModelOut) {
        # Not zero: the queue app reads a ticket with a reset time as a run in flight.
        $resetsAt = Get-Now
    }
    @{
        Kind = $job.Kind; Ticket = $job.Ticket; Title = $job.Title; Pr = $job.Pr; Repo = (Get-JobRepo $job); Size = $job.Size; Complexity = $job.Complexity; Session = $end.Session; Cost = $end.Cost
        AdvisorCost = $end.AdvisorCost
        Model = $end.Model; Effort = $end.Effort; Advisor = [string]$end.Advisor; ConfigDir = $end.ConfigDir; ResetsAt = $resetsAt; LoggedOut = [bool]$end.LoggedOut
        AtLimit = [bool]$end.AtLimit; Stopped = [bool]$end.Stopped
        # The window of some models whose limit ended the run, and the model the run was on (Invoke-Worker's prompt).
        ModelOut = [string]$end.ModelOut; From = [string]$end.From
        # The time worked so far, so the queue app's progress goes on from here after the resume.
        Elapsed = (Get-Now) - [long]$script:running.startedAt
    } | ConvertTo-Json | Set-Content $pausedFile -Encoding utf8
    if ($end.Stopped) {
        # The run wrote its handoff comment itself, and the owner paused it: no comment from the script.
        Remove-Item $stopFile -ErrorAction SilentlyContinue
        Write-Log "held #$($job.Ticket) for the owner's pause"
        return
    }
    if ($end.LoggedOut) {
        Write-Log "held #$($job.Ticket) for its account $(Get-Account $end.ConfigDir)"
        return
    }
    if ($end.AtLimit) {
        Send-Comment $job "stopped at a checkpoint: its account reached the workers' usage limit. It resumes on its own when the account has room."
        Write-Log "held #$($job.Ticket) at the workers' limit"
        return
    }
    if ($end.ModelOut) {
        $more = if ($job.Kind -eq 'ticket') { " If the decisions it is on $($end.From) for are still open, the run hands the ticket to a worker whose account has $($end.From) left." } else { '' }
        Send-Comment $job "its account reached the limit of its $($WindowTitles[$end.ModelOut]) window: the run goes on now with $($end.Model).$more"
        Write-Log "#$($job.Ticket) goes on with $($end.Model): its account reached the limit of $($end.ModelOut)"
        return
    }
    Send-Comment $job "paused by the plan's usage limit; resumes on its own after it resets ($(Format-Time $resetsAt))."
    Write-Log "paused #$($job.Ticket) until $(Format-Time $resetsAt)"
}

# The seconds a run held at the workers' limit waits before it looks again; 0 resumes it now: its account takes a small
# ticket again (Get-Fit, size S), so the run does not resume straight into the stop line. Not its own size: the part
# left of it is unknown, and room an S may use should not wait for a reset. Else until the next window reset, at most a
# poll: a look a minute before the reset waited a whole poll after it.
function Get-RoomWait($paused) {
    $budget = Get-Budget (Get-Account $paused.ConfigDir) (Get-FreshUsage $paused.ConfigDir)
    Save-Budget $budget
    if (Get-Fit 'S' $budget) {
        return 0
    }
    return [long][math]::Min($PollSeconds, ($windows | ForEach-Object { $budget[$_].left } | Measure-Object -Minimum).Minimum)
}

# Whether a run ended its job: a ticket in a PR or a question (or closed), an answered or a rebase job with its label
# gone. Changes nothing.
function Test-Finished($job) {
    if ($job.Kind -ne 'ticket') {
        $pr = Get-GhJson @('pr', 'view', "$($job.Pr)", '--json', 'state,labels') (Get-JobRepo $job)
        return -not ($pr.state -eq 'OPEN' -and (Get-Names $pr) -contains $job.Kind)
    }
    $issue = Get-GhJson @('issue', 'view', "$($job.Ticket)", '--json', 'state,labels')
    $prs = @(Get-GhJson @('pr', 'list', '--head', "t$($job.Ticket)", '--state', 'open', '--json', 'number') (Get-JobRepo $job))
    return -not ($issue.state -eq 'OPEN' -and (Get-Names $issue) -notcontains 'needs-owner' -and $prs.Count -eq 0)
}

# A run must end its job (Test-Finished); anything else is parked for the owner (limits.ps1, Get-Outcome). $cap: the
# cap that the run reached, else 0.
function Test-Outcome($job, [string] $log, [double] $cap) {
    $outcome = Get-Outcome (Test-Finished $job) ([string]$job.Kind) $cap $log
    if (-not $outcome) {
        return
    }
    if ($outcome.Pr) {
        & gh pr edit $job.Pr --add-label needs-owner -R (Get-JobRepo $job) | Out-Null
    } else {
        & gh issue edit $job.Ticket --add-label needs-owner -R $repo | Out-Null
    }
    Send-Comment $job $outcome.Comment
}

# Compacts a session that is held at the workers' limit or for the owner's pause, at once, where the provider can
# (docs/PLUGINS.md, GetCompact). Its cache is still warm, so the compaction reads the context cheaply; hours later the
# cache is gone, and the resume then reads only the summary. $run: what the run started from, so the cache holds: the
# same model, tools and settings. A failure is not the job's: the session then resumes whole (plugins.ps1,
# Invoke-ProviderCompact).
function Compress-Session($run, [string] $session, [string] $log) {
    $line = Invoke-ProviderCompact $run $session $log
    if ($line) {
        Write-Log $line
    }
}

# While this worker's account is out, its tickets that no run holds go back to the queue, for a worker on another
# account: each open ticket it claimed that does not wait on the owner and has no PR, but not $keep, the ticket of
# its held run. Otherwise the ticket and its areas wait with the account. The same rule as for a disabled worker
# (Get-NextJob).
function Remove-Claims([int] $keep) {
    foreach ($issue in @(Get-GhJson @('issue', 'list', '--state', 'open', '--label', $me, '--limit', '100', '--json', 'number,labels'))) {
        if ($issue.number -eq $keep -or (Get-Names $issue) -contains 'needs-owner') {
            continue
        }
        if (@(Get-GhJson @('pr', 'list', '--head', "t$($issue.number)", '--state', 'open', '--json', 'number') (Get-TicketRepo $issue)).Count -gt 0) {
            continue
        }
        & gh issue edit $issue.number --remove-label $me -R $repo | Out-Null
        Write-Log "requeued #$($issue.number): the account is out"
    }
}

# A run that waits in paused.json, as the queue app shows it: its ticket and the progress so far.
function Get-HeldView($p) {
    return @{ account = Get-Account $p.ConfigDir; ticket = $p.Ticket; title = $p.Title; repo = $p.Repo; resetsAt = [long]$p.ResetsAt; loggedOut = [bool]$p.LoggedOut; atLimit = [bool]$p.AtLimit
        stopped = [bool]$p.Stopped
        kind = $p.Kind; pr = $p.Pr; size = $p.Size; model = $p.Model; effort = $p.Effort; elapsed = [long]$p.Elapsed }
}

$mutex = New-Object System.Threading.Mutex($false, "Local\Scriptorium-$($config.name)-Queue")
# Nothing of the PC's stays in the project: account keys and records from before the PC's files move there (pc.ps1).
try {
    Initialize-Pc $Project
} catch {
    Write-Log "the PC's files: $_"
}
$script:budgetAt = 0
$script:claimsAt = 0
# Runs in a row that did not start although the account answered a probe.
$script:startFails = 0
while ($true) {
    # $job is still the last pass's. Its run may have opened or pushed a PR: the merger looks now, not at its next
    # poll. Only here, after the run's outcome is settled: Test-Outcome parks a ticket whose PR merged before its
    # ticket closed.
    if ($job) {
        Send-Wake $wakeMerger
    }
    # Between jobs only: a run in progress finishes on the old code.
    if (Test-CodeChanged) {
        Write-Log 'script changed: restarting on the new code'
        Restart-OnNewCode (Get-TaskName $config.name "worker $Id")
    }
    $polledAt = Get-Date
    $job = $null
    $paused = $null
    $roomAt = 0
    try {
        if (-not (Test-Enabled $Id)) {
            Disable-Worker
            Start-Sleep 30
            continue
        }
        # A plugin of scriptorium.json is not installed yet: no run starts without it (it may be the provider, or
        # what makes the environment). The worker restarts when its files are there (Start-CodeWatch).
        if ($missing.Count) {
            Write-State 'error' @{ error = (Get-MissingText $missing) }
            Start-Sleep 30
            continue
        }
        # The worker's account is another coding tool's now (the owner moved the worker): it starts again on that
        # tool. Between jobs only, and not with a run held: a held session is its own tool's. A worker with no
        # provider looks again for one that was installed since.
        $known = $providers
        if (-not $provider) {
            $known = Get-Providers $PSScriptRoot $projectPlugins
        }
        if (-not (Test-Path $pausedFile) -and [string](Get-WorkerProvider (Read-Settings) "$Id" $known).Name -ne [string]$provider.Name) {
            Write-Log "the account's coding tool changed: restarting on it"
            Restart-OnNewCode (Get-TaskName $config.name "worker $Id")
        }
        # The worker restarts when scriptorium.json changes (Start-CodeWatch), so a provider added there is found.
        if (-not $provider) {
            Write-State 'error' @{ error = $(if ($providers.Count) {
                    "no provider: this worker's account is of a coding tool with no plugin here. Add its plugin to scriptorium.json and run setup.ps1, or put the worker on another account (the page, Workers)."
                } else {
                    'no provider: add a provider plugin to scriptorium.json and run setup.ps1 (docs/PLUGINS.md, A provider)'
                }) }
            Start-Sleep 30
            continue
        }
        # Not a passive worker's: its environment opens for a run only (Invoke-Worker).
        if (-not (Get-RunSettings $Id).passive) {
            $script:environmentOpen = $true
            Invoke-WorkerHooks 'Start' $Clone -Report | Out-Null
        }
        Set-GitHubIdentity (Get-RunSettings $Id).ghConfigDir
        $mode = Get-Control
        # Paused from the queue app: no new job until the owner sets the worker active. A stop also holds a run
        # that waits for its limit reset; a drain lets that run resume and finish first ("finish the ticket").
        if ($mode -and -not ($mode -eq 'drain' -and (Test-Path $pausedFile))) {
            # The account's budget once a poll, from the last usage reading (a new one can cost a request), so the
            # queue app still draws what the budget keeps for the owner.
            if ((Get-Now) - $script:budgetAt -ge $PollSeconds) {
                $script:budgetAt = Get-Now
                try {
                    $account = Get-Account (Get-RunSettings $Id).configDir
                    Save-Budget (Get-Budget $account (Read-AllUsage)[$account])
                } catch {
                    Write-Log "budget error: $_"
                }
            }
            # A held run stays named on the card, so it does not read as finished.
            $held = if (Test-Path $pausedFile) {
                Get-HeldView (Get-Content $pausedFile -Raw | ConvertFrom-Json)
            }
            Write-State $(if ($mode -eq 'stop') { 'stopped' } else { 'drained' }) $held
            Close-WhenPassive
            Start-Sleep 30
            continue
        }
        if (Test-Path $pausedFile) {
            $paused = Get-Content $pausedFile -Raw | ConvertFrom-Json
            # The owner's Now for another ticket (docs/QUEUE.md, Now) takes the place of a run held at a checkpoint
            # (Test-HeldAtCheckpoint): its session goes, and its ticket starts fresh from its handoff comment, here or
            # on another worker. A PR's job stays this worker's.
            # shortcut: the Now's ticket is not looked at first, so one that left the queue since the click still frees
            # the held run; look it up here if that costs a session in use.
            if ((Test-HeldAtCheckpoint $paused) -and (Test-NowElsewhere $paused)) {
                Remove-Item $pausedFile
                if ($paused.Kind -eq 'ticket') {
                    & gh issue edit $paused.Ticket --remove-label $me -R $repo | Out-Null
                }
                Write-Log "freed the held #$($paused.Ticket) for the owner's Now"
                continue
            }
            # Any other held run goes first. A Now that waits behind it would keep its ticket from every worker: it ends.
            if (Read-Now $forceFile) {
                Remove-Item $forceFile -ErrorAction SilentlyContinue
                Write-Log "now: ended, the worker holds the run of #$($paused.Ticket)"
            }
            # A run that ended at a checkpoint, or that its account refused, is held on its account. If the owner
            # moved the worker to another account meanwhile, the session cannot follow: the ticket starts fresh there,
            # from its handoff comment. The same for a run that waits for a limit reset on an account that is out
            # now: it would wait for that account for ever.
            $heldOn = Get-Account $paused.ConfigDir
            if (($paused.AtLimit -or $paused.Stopped -or $paused.LoggedOut -or $paused.ModelOut -or (Read-Out)[$heldOn]) -and $heldOn -ne (Get-Account (Get-RunSettings $Id).configDir)) {
                Remove-Item $pausedFile
                Write-Log "dropped the held session of #$($paused.Ticket): the worker moved to another account; its ticket starts fresh"
                continue
            }
        }
        # The account of the next run is out (Get-Out): no run starts and no ticket is taken until it takes runs
        # again. Looked at every 30 seconds, so a sign-in or the owner's switch to another account applies at once.
        $runConfigDir = if ($paused) { $paused.ConfigDir } else { (Get-RunSettings $Id).configDir }
        if (Get-Out $runConfigDir) {
            # Only for an account that is out: a worker on another account can run the ticket. A worker that stops
            # for its own record keeps its ticket: the cause may be every worker's (the settings), and then the
            # ticket would stop them one after another.
            if (-not (Read-Out)[$me] -and (Get-Now) - $script:claimsAt -ge 600) {
                $script:claimsAt = Get-Now
                try {
                    Remove-Claims $(if ($paused) { [int]$paused.Ticket } else { 0 })
                } catch {
                    Write-Log "requeue error: $_"
                }
            }
            if ($paused) {
                $view = Get-HeldView $paused
                $view.loggedOut = $true
                Write-State 'paused' $view
            } else {
                Write-State 'signedout' @{ account = Get-Account $runConfigDir }
            }
            Close-WhenPassive
            Start-Sleep 30
            continue
        }
        $script:claimsAt = 0
        if ($paused) {
            # A run held for its account resumes now: the account takes runs again.
            $wait = if ($paused.LoggedOut) { 0 } else { [long]$paused.ResetsAt - (Get-Now) }
            if ($paused.AtLimit -or $paused.Stopped) {
                $wait = Get-RoomWait $paused
            }
            if ($wait -gt 0) {
                $view = Get-HeldView $paused
                # A run held for a pause that now waits for room reads as one held at the stop line.
                $view.atLimit = $view.atLimit -or $view.stopped
                # Looked at again every poll, so a stop meanwhile holds it; a disable or the owner's Now wakes it
                # within a minute.
                Write-State 'paused' $view
                $wake = (Get-Now) + [math]::Min($wait + 60, $PollSeconds)
                while ((Get-Now) -lt $wake -and (Test-Enabled $Id) -and -not ((Test-HeldAtCheckpoint $paused) -and (Test-NowElsewhere $paused))) {
                    Start-Sleep ([math]::Max(1, [math]::Min(60, $wake - (Get-Now))))
                }
                continue
            }
            $job = $paused
            # Closed while paused (cancelled, or merged by hand): nothing left to resume.
            if ((Get-GhJson @('issue', 'view', "$($paused.Ticket)", '--json', 'state')).state -ne 'OPEN') {
                Remove-Item $pausedFile
                Write-Log "dropped paused #$($paused.Ticket): closed"
                $job = $null
                $paused = $null
            }
        } elseif (-not (Test-Path $forceFile) -and -not (Read-Next $nextFile -Forced) -and (Test-OverBudget $runConfigDir)) {
            Write-State 'over-budget'
            # The account has room when its last full window resets: the wait below ends then, not a poll later.
            $roomAt = Get-RoomAt $script:budget
        } elseif ((Read-Out)[(Get-Account $runConfigDir)]) {
            # The usage reading's probe found the account out: the next look waits for it.
            continue
        } else {
            Write-State 'idle'
            try {
                [void]$mutex.WaitOne()
            } catch [System.Threading.AbandonedMutexException] {
            }
            try {
                $job = Get-NextJob
            } finally {
                $mutex.ReleaseMutex()
            }
        }
        if ($job) {
            $log = Join-Path $queueDir "logs/$(Get-Date -Format yyyyMMdd-HHmmss)-t$($job.Ticket)-$($job.Kind).jsonl"
            $script:running = @{
                account = Get-Account $runConfigDir; size = $job.Size; complexity = $job.Complexity
                ticket = $job.Ticket; title = $job.Title; repo = Get-JobRepo $job; kind = $job.Kind; pr = $job.Pr
                startedAt = (Get-Now) - $(if ($paused) { [long]$paused.Elapsed } else { 0 }); log = $log
            }
            $script:stopNoted = $false
            $script:limitNoted = $false
            Write-State 'running' $script:running
            Write-Log "$($job.Kind) #$($job.Ticket) -> $log"
            $end = Invoke-Worker $job $log $paused
            $next = (Get-RunModel $job.Complexity (Get-RunSettings $Id) (Get-Account $runConfigDir)).Model
            # What follows (limits.ps1, Get-RunAction). A run that did not start is never its ticket's failure. Whose
            # it is decides who stops (Get-Out): the account's stops every worker on it; this worker's own (a model its
            # plan lacks, a wrong setting) stops only this worker.
            $account = Get-Account $end.ConfigDir
            # The model after a model window's limit (docs/QUEUE.md, A model's limit), and for a start that failed for
            # a cause the text does not name, a probe: whether the account takes requests at all.
            $after = if ($end.ModelOut) { Get-RunModel $job.Complexity $null $account -After $end.ModelOut } else { @{ Model = '' } }
            $reply = if ($end.Refusal -eq 'start') { Invoke-Probe $end.ConfigDir } else { $null }
            $halted = (Test-Path $stopFile) -or (Get-Control) -eq 'stop' -or -not (Test-Enabled $Id)
            $act = Get-RunAction $end ([string]$job.Kind) ([bool]$paused) $next (Test-Path $handoffFile) ([string]$after.Model) $reply `
                ([int]$script:startFails) $halted ([bool]$script:stopNoted)
            $script:startFails = $act.StartFails
            $end.Refusal = $act.Refusal
            $end.RefusalText = $act.RefusalText
            if ($act.Action -eq 'next-model') {
                # The job comes back as this worker's own on the next pass, on the next candidate.
                Write-Log "$($end.Model) refused on $(Get-Account $runConfigDir); #$($job.Ticket) goes on $next"
                continue
            }
            # A Now for another ticket than this job's stays: the worker takes that ticket next (Get-NextJob).
            if (-not (Test-NowElsewhere $job)) {
                Remove-Item $forceFile -ErrorAction SilentlyContinue
            }
            if ($act.Action -eq 'handed-on') {
                # A run on the model after found the ticket's decisions still open: back to the queue, where no
                # dispatcher gives it to this account until the window's reset (Test-ModelLeft).
                Remove-Item $handoffFile, $pausedFile -ErrorAction SilentlyContinue
                & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                Send-Comment $job ("handed on: its decisions need the model it began on, and this worker's account reached that model's limit. " +
                    'A worker whose account has the model left takes it next, fresh from the handoff comment.')
                Write-Log "requeued #$($job.Ticket): handed on for its first model"
                continue
            }
            if ($act.Action -eq 'requeue-window') {
                Remove-Item $pausedFile -ErrorAction SilentlyContinue
                & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                Write-Log "requeued #$($job.Ticket): $account reached the limit of $($end.ModelOut)"
                continue
            }
            if ($act.Action -eq 'go-on') {
                # The model after decides whether the ticket's decisions are made (Invoke-Worker's prompt).
                $end.Model = $after.Model
                $end.Effort = $after.Effort
                Suspend-Job $job $end
                continue
            }
            if ($act.Action -eq 'retry-start') {
                Write-Log "#$($job.Ticket) did not start ($($end.RefusalText)): tries once more"
                continue
            }
            if ($act.Action -eq 'requeue-model') {
                # A fact of the plan, not of the ticket or the worker: no dispatcher gives it to this account
                # (Test-ModelLeft).
                & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                Write-Log "requeued #$($job.Ticket): the plan of $account has no model for complexity $($job.Complexity) ($($end.RefusalText))"
                continue
            }
            if ($act.Whose) {
                $whose = if ($act.Whose -eq 'worker') { $me } else { $account }
                $stamp = if ($act.Whose -eq 'worker') { Get-SettingsStamp } else { Get-LoginStamp $account }
                Set-Out $whose (New-OutRecord $end.Refusal $end.RefusalText $stamp)
                Write-Log "$whose is out ($($end.Refusal)): $($end.RefusalText)"
                $end.LoggedOut = $act.LoggedOut
            }
            switch ($act.Action) {
                'suspend' {
                    Suspend-Job $job $end
                }
                'not-started' {
                    # For an account that is out the ticket goes back to the queue at the next look (Remove-Claims);
                    # for this worker's own record it stays this worker's.
                    Write-Log "#$($job.Ticket) did not start"
                }
                'freed' {
                    # Its ticket starts fresh from its handoff comment, here or on another worker. A PR's job stays
                    # this worker's.
                    Remove-Item $stopFile, $pausedFile -ErrorAction SilentlyContinue
                    if ($job.Kind -eq 'ticket') {
                        & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                    }
                    Write-Log "freed #$($job.Ticket) for the owner's Now"
                }
                'stopped' {
                    # The ticket or PR starts fresh when the owner resumes, or goes to another worker when this one
                    # is disabled.
                    Remove-Item $stopFile -ErrorAction SilentlyContinue
                    Write-Log "stopped #$($job.Ticket)"
                }
                'done' {
                    Remove-Item $pausedFile -ErrorAction SilentlyContinue
                    if ($act.Judge) {
                        # Under the dispatch lock, which the merger holds from a merge to its ticket's close (merge.ps1):
                        # between the two, a merged ticket reads as one without a PR.
                        $lock = Enter-PcLock "$($config.name)-Queue"
                        try {
                            Test-Outcome $job $log $end.Capped
                        } finally {
                            Exit-PcLock $lock
                        }
                    }
                    Write-Log "done #$($job.Ticket)"
                }
            }
            continue
        }
    } catch {
        Write-Log "error: $_"
        # A plugin's hook that threw (Start, GetRun): no run starts, the card shows the error, and the worker tries
        # again at its next look (docs/PLUGINS.md, When a hook throws).
        if ("$_" -like 'plugin *') {
            Write-State 'error' @{ error = "$_" }
        }
    }
    # No job this pass.
    Close-WhenPassive
    # A force from the queue app since this poll began, a wake (the merger changed a PR, the owner acted on the
    # page), changed code, or a disable (looked at once a minute; its editors then close) wakes the next one early.
    $wake = (Get-Now) + $PollSeconds
    if ($roomAt) {
        $wake = [math]::Min($wake, $roomAt + 5)
    }
    $enabledAt = Get-Now
    $enabled = $true
    while ((Get-Now) -lt $wake -and -not (Test-CodeChanged) -and $enabled -and
        -not ((Test-Path $forceFile) -and (Get-Item $forceFile).LastWriteTime -gt $polledAt) -and
        -not ((Test-Path $nextFile) -and (Get-Item $nextFile).LastWriteTime -gt $polledAt) -and
        -not ((Test-Path $wakeWorkers) -and (Get-Item $wakeWorkers).LastWriteTime -gt $polledAt)) {
        Start-Sleep 5
        if ((Get-Now) - $enabledAt -ge 60) {
            $enabledAt = Get-Now
            $enabled = Test-Enabled $Id
        }
    }
}
