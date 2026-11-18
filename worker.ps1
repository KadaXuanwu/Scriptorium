# A worker script (docs/QUEUE.md): has its plugins make its clone's environment ready, claims the next job (the
# dispatcher: a new ticket goes to the idle worker whose account's free room most wants spending) and starts a run, a
# headless Claude session on it with what the plugins give it (docs/PLUGINS.md). Watches the plan's usage while a run works, and resumes a run
# the usage limit cut off once the limit resets. Loops until stopped; started at logon by setup.ps1's task.
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

$Project = Resolve-Project $Project
$config = Read-Project $Project
if (-not $Clone) {
    $Clone = "$Project-w$Id"
}
$plugins = Import-Plugins $PSScriptRoot $config
# A pull of a plugin restarts the worker as a pull of Scriptorium does.
Start-CodeWatch (@((Join-Path $Project 'scriptorium.json')) + @($plugins | ForEach-Object { $_.Dir }))

# One loop per worker: stopping the task ends only its console host, so an older loop may still run, on old code.
# End it with its run; the ticket resumes here (PLAYBOOK.md, Branch). Only this project's worker of this number.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and (Test-ProjectProcess $_.CommandLine 'worker.ps1' $Project) -and $_.CommandLine -match "-Id $Id\b" } |
    ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }

$me = "worker:$Id"
$Clone = (Resolve-Path $Clone).Path
$queueDir = Join-Path $Clone '.queue'
$pausedFile = Join-Path $queueDir 'paused.json'
$warnFile = Join-Path $queueDir 'limit.md'
$stopFile = Join-Path $queueDir 'stop.md'
$commentsFile = Join-Path $queueDir 'comments.md'
# Written by a run that hands its ticket on at the Fable limit (docs/QUEUE.md, The Fable limit).
$handoffFile = Join-Path $queueDir 'handoff.md'
$progressFile = Join-Path $queueDir 'progress.json'
$mainQueueDir = Join-Path $Project '.queue'
$usageFile = Join-Path $mainQueueDir 'usage.json'
$historyFile = Join-Path $mainQueueDir 'history.jsonl'
$accessFile = Join-Path $mainQueueDir 'access.json'
# Forced from the queue app: the next job starts past the area, room and ceiling checks; the run ending clears it.
$forceFile = Join-Path $mainQueueDir "force-$Id.json"
New-Item -ItemType Directory -Force (Join-Path $queueDir 'logs'), $mainQueueDir | Out-Null
# Every turn reads the whole context again, so Claude Code compacts a run's context: 33k tokens before the compact
# window of the job's complexity, which Invoke-Worker sets for each run (docs/CONFIG.md, The compact window). A run
# never hands off to a fresh session: that cost 24 turns of reading, a compaction 7.
# Tools no run used in 631 logs; without them every turn reads 4,750 tokens less.
$UnusedTools = 'Task,CronCreate,CronDelete,CronList,DesignSync,EnterWorktree,ExitWorktree,ListAgents,NotebookEdit,' +
    'PushNotification,RemoteTrigger,ReportFindings,SendMessage,WebFetch,WebSearch'
Set-Location $Clone
$repo = (& gh repo view --json nameWithOwner -q .nameWithOwner)
# The repo's owner, whose other repos a ticket's `repo:<Name>` label names.
$owner = $repo.Split('/')[0]

$windows = @('five_hour', 'seven_day')

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
# (PLAYBOOK.md, Another repository). A job from before that label existed has none: this repo.
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
        $log
    }
    return Invoke-Hooks $plugins $hook $Project $copy $Id $queueDir (Read-Settings) $say $log
}

# The main checkout's .queue/settings.json (docs/QUEUE.md, Settings), read before every decision and run so a change
# applies from the next.
function Read-Settings {
    $file = Join-Path $mainQueueDir 'settings.json'
    if (-not (Test-Path $file)) {
        return $null
    }
    return Get-Content $file -Raw | ConvertFrom-Json
}

# The account register: which login each use runs on (`worker:N`, `frontdesk`, `personal`), so moving a use to
# another account is one edit. Human uses are every use but a worker's: only those keep room free.
function Get-Accounts {
    $json = Read-Settings
    $accounts = @()
    if ($json -and $json.accounts) {
        foreach ($property in $json.accounts.PSObject.Properties) {
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
# Windows user's command-line login.
function Get-RunSettings([int] $worker) {
    $settings = @{ model = $null; configDir = $null; sizes = $null; ghConfigDir = $null; assignedOnly = $null }
    $json = Read-Settings
    if (-not $json) {
        return $settings
    }
    $own = $null
    if ($json.workers) {
        $own = $json.workers."$worker"
    }
    foreach ($key in @('model', 'sizes', 'ghConfigDir', 'assignedOnly')) {
        if ($own -and $own.$key) {
            $settings[$key] = $own.$key
        } elseif ($json.$key) {
            $settings[$key] = $json.$key
        }
    }
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

# Disabled: its paused run is dropped (its ticket goes back to the queue, Get-NextJob).
function Disable-Worker {
    if (Test-Path $pausedFile) {
        Remove-Item $pausedFile
        Write-Log 'disabled: dropped the paused run; its ticket goes back to the queue'
    }
    Write-State 'disabled'
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

# The login's plan size (budget.ps1), read from its credentials each time, so a plan change applies at once.
function Get-AccountPlanSize([string] $account) {
    $dir = Get-ConfigDir $account
    if (-not $dir) {
        $dir = Join-Path $HOME '.claude'
    }
    $file = Join-Path $dir '.credentials.json'
    if (-not (Test-Path $file)) {
        return 1.0
    }
    return Get-PlanSize ([string](Get-Content $file -Raw | ConvertFrom-Json).claudeAiOauth.rateLimitTier)
}

# The login's email, from its profile file (as the queue app reads it); $null when signed out.
function Get-LoginEmail([string] $account) {
    $dir = Get-ConfigDir $account
    $file = if ($dir) { Join-Path $dir '.claude.json' } else { Join-Path $HOME '.claude.json' }
    if (-not (Test-Path $file)) {
        return $null
    }
    # A regex, not ConvertFrom-Json: the file can hold keys differing only in case, which Windows PowerShell refuses.
    $match = [regex]::Match((Get-Content $file -Raw -Encoding UTF8), '"emailAddress"\s*:\s*"([^"]+)"')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
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

# The plan's usage from a stream-json log's last (or first) rate_limit_event: each window's share used and reset, and
# whether the plan refused the run. The Fable window too, but its refusal is not `refused`: it stops only Fable.
function Get-Usage([string] $text, [switch] $First) {
    # Only events with the plan's windows: a model the plan lacks sends a rejection without them.
    $lines = ($text -split "`n") | Where-Object { $_ -like '*"rate_limit_event"*' -and $_ -like '*"unifiedWindows"*' }
    if (-not $lines) {
        return $null
    }
    $line = if ($First) { @($lines)[0] } else { @($lines)[-1] }
    $info = ($line | ConvertFrom-Json).rate_limit_info
    $rejected = $info.status -eq 'rejected'
    $usage = @{ at = (Get-Now); refused = $rejected -and $info.rateLimitType -ne $FableWindow
        fableRefused = $rejected -and $info.rateLimitType -eq $FableWindow; refusedResetsAt = [long]$info.resetsAt }
    foreach ($window in @($windows) + $FableWindow) {
        $value = $info.unifiedWindows.$window
        if ($value) {
            $usage[$window] = @{ used = [double]$value.utilization; resetsAt = [long]$value.resetsAt; at = $usage.at }
        }
    }
    return $usage
}

# A window's share in use now: nothing once it has reset.
function Get-Used($usage, [string] $window) {
    if (-not $usage -or -not $usage.$window -or [long]$usage.$window.resetsAt -le (Get-Now)) {
        return 0.0
    }
    return [double]$usage.$window.used
}

function Read-AllUsage {
    $all = @{}
    try {
        (Get-Content $usageFile -Raw -ErrorAction Stop | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $all[$_.Name] = $_.Value }
    } catch {
        # Missing or unreadable: an empty cache, so every account is read again. A bad file must not stop the worker.
    }
    return $all
}

# Shared with the other workers, per account. Under its own mutex and written whole: two workers that saved in the
# same second once tore the file, and every worker then failed each poll.
$usageMutex = New-Object System.Threading.Mutex($false, "Local\Scriptorium-$($config.name)-Usage")
function Save-Usage([string] $account, $usage) {
    $usage.email = Get-LoginEmail $account
    try {
        [void]$usageMutex.WaitOne()
    } catch [System.Threading.AbandonedMutexException] {
    }
    try {
        $all = Read-AllUsage
        # Merge-Usage changes $usage itself, so the caller's reading is the account's newest too.
        $all[$account] = Merge-Usage $all[$account] $usage
        $all | ConvertTo-Json -Depth 4 | Set-Content "$usageFile.tmp" -Encoding utf8
        Move-Item "$usageFile.tmp" $usageFile -Force
    } finally {
        $usageMutex.ReleaseMutex()
    }
}

# The account's record of the Fable limit until the reset (Test-FableOut), from a reading whose request Fable refused,
# also when its event had no Fable window: without it, a refused start would give its ticket back to this account
# every poll.
function Save-FableOut([string] $account, $usage) {
    $record = if ($usage) { $usage } else { @{ at = 0 } }
    if (-not (Test-FableOut $record (Get-Now))) {
        $resetsAt = if ($record.refusedResetsAt -gt (Get-Now)) { [long]$record.refusedResetsAt } else { (Get-Now) + 86400 }
        $record[$FableWindow] = @{ used = 1.0; resetsAt = $resetsAt }
        Save-Usage $account $record
    }
}

# An account's usage, read again with a one-word Haiku request when the last reading is older than 30 minutes: idle
# accounts get no run events, and the owner's own sessions spend them too. The Fable window it does not read: only a
# Fable request reports it, and a Fable probe was dropped; the queue app shows its read time.
function Get-FreshUsage([string] $configDir) {
    $account = Get-Account $configDir
    $stored = (Read-AllUsage)[$account]
    # A reading of another account is no reading: the folder's login changed since.
    if ($stored -and $stored.email -ne (Get-LoginEmail $account)) {
        $stored = $null
    }
    if ($stored -and (Get-Now) - [long]$stored.at -lt 1800) {
        return $stored
    }
    $text = Invoke-Probe $configDir
    $usage = Get-Usage $text
    if (-not $usage) {
        # A refused probe finds an account that is out before a ticket is claimed for it. Not for 'start': one
        # failed request is no proof, and a record stops every worker on the account.
        $reply = Read-Probe $text
        if ($reply -and $reply.kind -in @('login', 'subscription') -and -not (Read-Out)[$account]) {
            Set-Out $account (New-OutRecord $reply.kind $reply.text (Get-LoginStamp $account))
            Write-Log "$account is out ($($reply.kind)): $($reply.text)"
        }
        return $stored
    }
    Save-Usage $account $usage
    return $usage
}

# A probe: one word from Haiku on a login, in a folder with no CLAUDE.md. The cheapest request that shows the
# account's usage and whether the account takes requests; a refused one costs nothing. Returns its stream-json text.
function Invoke-Probe([string] $configDir) {
    $ErrorActionPreference = 'Continue'
    $dir = Join-Path $env:TEMP "scriptorium-$($config.name)-probe"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $previousConfigDir = $env:CLAUDE_CONFIG_DIR
    if ($configDir) {
        $env:CLAUDE_CONFIG_DIR = $configDir
    }
    Push-Location $dir
    try {
        return (& claude -p 'Reply: ok' --model haiku --output-format stream-json --verbose 2>$null) -join "`n"
    } finally {
        Pop-Location
        $env:CLAUDE_CONFIG_DIR = $previousConfigDir
    }
}

# What a probe's reply says of its account: the kind of its refusal (limits.ps1, Get-Refusal; '' when the account
# answered) and its text. $null without a result line: the probe itself failed.
function Read-Probe([string] $text) {
    $line = ($text -split "`n") | Where-Object { $_ -like '*"type":"result"*' } | Select-Object -Last 1
    if (-not $line) {
        return $null
    }
    $result = $line | ConvertFrom-Json
    return @{ kind = Get-Refusal $result; text = [string]$result.result }
}

# The login a folder holds now: when its credentials were last written, and its email. A sign-in changes it.
function Get-LoginStamp([string] $account) {
    $dir = Get-ConfigDir $account
    if (-not $dir) {
        $dir = Join-Path $HOME '.claude'
    }
    $file = Join-Path $dir '.credentials.json'
    return "$(if (Test-Path $file) { (Get-Item $file).LastWriteTimeUtc.Ticks } else { 0 }) $(Get-LoginEmail $account)"
}

# Accounts that are out (`.queue/out.json`, shared by the workers and the queue app): an account that refused a run
# for its subscription or its login, or on which neither a run nor a probe could start (limits.ps1, $OutKinds). Per
# account: the kind, the refusal's text, the time of the last test and the login then. The fact is the account's, not
# a ticket's: no worker starts a run on it, no dispatcher gives its workers a ticket, and the app shows it on the
# account's card and on each of its workers' cards. A worker whose runs do not start although its account answers (a
# wrong setting) has a record of its own, under `worker:<id>`: only that worker stops.
$outFile = Join-Path $mainQueueDir 'out.json'
function Read-Out {
    $out = @{}
    try {
        (Get-Content $outFile -Raw -ErrorAction Stop | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $out[$_.Name] = $_.Value }
    } catch {
        # Missing or unreadable: no account is out. The next refusal writes it again.
    }
    return $out
}

# $stamp: what a change of ends the wait early. An account's login (Get-LoginStamp), a worker's settings.
function New-OutRecord([string] $kind, [string] $text, [string] $stamp) {
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) {
        $text = $text.Substring(0, 297) + '...'
    }
    return @{ kind = $kind; text = $text; at = (Get-Now); login = $stamp }
}

# When the settings were last written: the owner's change may be the fix of a worker whose runs do not start.
function Get-SettingsStamp {
    $file = Join-Path $mainQueueDir 'settings.json'
    return "$(if (Test-Path $file) { (Get-Item $file).LastWriteTimeUtc.Ticks } else { 0 })"
}

# $record: $null removes the account's record. Under the usage mutex and written whole, as usage.json.
function Set-Out([string] $account, $record) {
    try {
        [void]$usageMutex.WaitOne()
    } catch [System.Threading.AbandonedMutexException] {
    }
    try {
        $all = Read-Out
        $all.Remove($account)
        if ($record) {
            $all[$account] = $record
        }
        $all | ConvertTo-Json -Depth 3 | Set-Content "$outFile.tmp" -Encoding utf8
        Move-Item "$outFile.tmp" $outFile -Force
    } finally {
        $usageMutex.ReleaseMutex()
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
    $reply = Read-Probe (Invoke-Probe $configDir)
    if ($reply -and $OutKinds -notcontains $reply.kind) {
        Set-Out $account $null
        Write-Log "$account takes runs again"
        return $null
    }
    # A probe with no result keeps what the last refusal said.
    $stamp = Get-LoginStamp $account
    $record = if ($reply) { New-OutRecord $reply.kind $reply.text $stamp } else { New-OutRecord $record.kind $record.text $stamp }
    Set-Out $account $record
    return $record
}

# The ticket complexities (project.ps1, Get-Complexities): models.json's with the project's over them, and the
# compact window the owner set on the page.
function Get-ProjectComplexities {
    return Get-Complexities (Read-Models) $config (Read-Settings)
}


# The playbooks a run follows, in order (docs/PLUGINS.md, The playbook): the base's and each plugin's, copied into the
# clone's queue folder before each run, then the project's own from origin/main of the clone. The run reads the copies:
# it gets no folder of Scriptorium or of a plugin, so it cannot change the code that runs it.
function Get-Playbooks {
    $folder = Join-Path $queueDir 'playbooks'
    New-Item -ItemType Directory -Force $folder | Out-Null
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

# Models an account was refused (`.queue/access.json`, per account the time of the refusal): skipped for a day, then
# tried again, so a plan that gains a model finds it. A refused start costs nothing.
function Read-Access {
    $access = @{}
    if (Test-Path $accessFile) {
        (Get-Content $accessFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $access[$_.Name] = $_.Value }
    }
    return $access
}

# One of the account's Fable lines, 'stop' or 'design' (queue app, Accounts; limits.ps1, Get-FableLines).
function Get-FableLine([string] $account, [string] $line) {
    $entry = @(Get-Accounts) | Where-Object { $_.Account -eq $account } | Select-Object -First 1
    return (Get-FableLines $(if ($entry) { $entry.StopAt }) $(if ($entry) { $entry.PickUp })).$line
}

# -Advisor: whether the model can be a run's advisor, else whether a run can start on it.
function Test-ModelRefused([string] $account, [string] $model, [switch] $Advisor) {
    # The account's Fable limit (limits.ps1) until the reset: from its design line no Fable run starts on it, from its
    # stop line no run gets the Fable advisor.
    $line = Get-FableLine $account $(if ($Advisor) { 'stop' } else { 'design' })
    if ($model -like '*fable*' -and (Test-FableOut (Read-AllUsage)[$account] (Get-Now) $line)) {
        return $true
    }
    $refusedAt = (Read-Access)[$account].$model
    return $refusedAt -and (Get-Now) - [long]$refusedAt -lt 86400
}

function Set-ModelRefused([string] $account, [string] $model) {
    $access = Read-Access
    $mine = @{}
    if ($access[$account]) {
        $access[$account].PSObject.Properties | ForEach-Object { $mine[$_.Name] = $_.Value }
    }
    $mine[$model] = Get-Now
    $access[$account] = $mine
    $access | ConvertTo-Json -Depth 3 | Set-Content $accessFile -Encoding utf8
}

# Whether an account has a model for a ticket complexity now: the owner's override, else a candidate in
# models.json, that the plan did not refuse in the last day and that is not Fable at its limit (Test-ModelRefused).
# Without one a run only gets refused: no dispatcher gives a worker on that account a ticket of the complexity, and the
# ticket waits for another account, the next day (the model is tried again) or the Fable reset.
function Test-ModelLeft([string] $complexity, $settings, [string] $account) {
    if (-not $complexity) {
        $complexity = 'medium'
    }
    $picks = if ($settings.model) { @([string]$settings.model) } else { Get-ComplexityModels (Get-ProjectComplexities) $complexity }
    return [bool]($picks | Where-Object { -not (Test-ModelRefused $account ($_ -split '@')[0]) })
}

# The model and effort a run of this ticket's complexity uses on this account: the settings' `model` if set (the
# owner's override), else the first of the complexity's candidates in models.json (docs/QUEUE.md, Models), best first,
# that the account wasn't refused; at the effort a candidate names after `@` (`claude-opus-5-5@high`), else that
# model's effort there, xhigh for a model not listed. No candidate left: the last. Its refusal sends a ticket back to
# the queue (Test-ModelLeft then holds it there) and parks a PR's job. -AfterFable: models.json's `afterFable`, for the
# rest of a job whose account reached the Fable limit (docs/QUEUE.md, The Fable limit).
function Get-RunModel([string] $complexity, $settings, [string] $account, [switch] $AfterFable) {
    $list = Read-Models
    if (-not $complexity) {
        $complexity = 'medium'
    }
    if ($AfterFable) {
        $pick = [string]$list.afterFable
    } elseif ($settings.model) {
        $pick = [string]$settings.model
    } else {
        $candidates = Get-ComplexityModels (Get-ProjectComplexities) $complexity
        $pick = [string]($candidates | Where-Object { -not (Test-ModelRefused $account ($_ -split '@')[0]) } | Select-Object -First 1)
        if (-not $pick) {
            $pick = [string]$candidates[-1]
        }
    }
    $model, $effort = $pick -split '@'
    if (-not $effort) {
        $effort = if ($list.models.$model) { [string]$list.models.$model.effort } else { 'xhigh' }
    }
    return @{ Model = $model; Effort = $effort }
}

# What the workers may spend of an account's windows (limits.ps1): per window its share used, the ceiling, the
# pick-up limit of each ticket size and the seconds left before it resets. Each human use the register gives the account keeps room under the week's stop line:
# its share for the time left.
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
        # Only the week keeps a reserve: the 5-hour window fills to its margin on any account.
        if ($entry -and $window -eq 'seven_day') {
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

# Idle workers that could take a new ticket now, this one first, each with its account's budget and settings.
function Get-Candidates {
    $candidates = @()
    foreach ($worker in Get-WorkerStates) {
        $state = $worker.State
        # An idle state older than two polls is a worker script that stopped.
        if ($worker.Worker -ne $Id -and ($state.state -ne 'idle' -or (Get-Now) - [long]$state.at -gt 2 * $PollSeconds + 60)) {
            continue
        }
        $settings = Get-RunSettings $worker.Worker
        # assignedOnly (Settings): a worker the owner keeps to the tickets labelled for it gets no new one.
        if ($settings.assignedOnly) {
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

# Best fit: among the candidates that take a ticket of this size now (Get-Fit), the one whose free weekly room most
# wants spending before its reset, then the most 5-hour room. $null when none takes it.
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
        $pace = Get-Pace $room.seven_day $candidate.Budget.seven_day.left
        if (-not $best -or $pace -gt $bestPace -or ($pace -eq $bestPace -and $room.five_hour -gt $bestRoom.five_hour)) {
            $best = $candidate
            $bestPace = $pace
            $bestRoom = $room
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
        return @{ Kind = 'ticket'; Ticket = $resume.number; Title = $resume.title; Repo = Get-TicketRepo $resume; Size = Get-Size $resume
            Complexity = Get-Complexity $resume }
    }
    if ((Get-RunSettings $Id).assignedOnly) {
        return $null
    }

    # Areas held by any ticket in flight: claimed by a worker and not parked on a question. Another repo counts as an
    # area of its own.
    $busy = @($issues | Where-Object {
        $n = Get-Names $_
        ($n | Where-Object { $_ -like 'worker:*' }) -and $n -notcontains 'needs-owner'
    } | ForEach-Object { Get-Names $_ } | Where-Object { $_ -like 'area:*' -or $_ -like 'repo:*' })

    $queued = @($issues | Where-Object {
        $n = Get-Names $_
        ($n | Where-Object { $_ -match '^P[0-2]$' }) -and -not ($n | Where-Object { $_ -like 'worker:*' -or $_ -eq 'needs-owner' })
    })
    # A ticket waits while a ticket its `Blocked by` line names is open.
    $queue = @($queued | Where-Object {
        $blockers = @(([string]$_.body -split "`n") | Where-Object { $_ -match '^\s*blocked by' } |
            ForEach-Object { [regex]::Matches($_, '#(\d+)') } | ForEach-Object { [int]$_.Groups[1].Value })
        -not ($blockers | Where-Object { $open -contains $_ })
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

    $candidates = @(Get-Candidates)
    # Why each ticket this pass skipped waits, for the queue app (docs/APP.md).
    $waiting = @{}
    $nextReset = @($candidates | ForEach-Object { (Get-Now) + [long]$_.Budget.five_hour.left } | Sort-Object)[0]
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
            $takers = @($takers | Where-Object { Test-ModelLeft $complexity $_.Settings $_.Account })
            if ($takers.Count -eq 0) {
                $waiting["$($ticket.number)"] = "no idle worker's account has a model for complexity $complexity now (a plan without it, or its Fable week at the design line)"
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
            "5-hour $(Format-Share $best.Budget.five_hour.used) of $(Format-Share $best.Budget.five_hour.ceiling), week " +
            "$(Format-Share $best.Budget.seven_day.used) of $(Format-Share $best.Budget.seven_day.ceiling)")
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
            $line = "usage at $(Format-Share $budget[$window].used) of $window, over the workers' $(Format-Share $budget[$window].ceiling); waiting"
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

# While the run works: record usage. At the workers' limit, leave the run the note that ends it at its next
# checkpoint; withdraw the note if the account has room again before then (a window reset, a
# moved stop line). The note carries the whole instruction, so a run that read an older playbook follows it too.
function Update-Usage([string] $log, [string] $account) {
    $usage = Get-Usage (Read-Log $log)
    if (-not $usage) {
        return
    }
    Save-Usage $account $usage
    $budget = Get-Budget $account $usage
    Save-Budget $budget
    # A forced run ignores the workers' limit; only the plan's own limit pauses it.
    if (Test-Path $forceFile) {
        return
    }
    $over = $windows | Where-Object { $budget[$_].used -ge $budget[$_].ceiling } | Select-Object -First 1
    if ($over -and -not (Test-Path $warnFile)) {
        $note = "The account's usage is at $(Format-Share $budget[$over].used) of its $over window, the workers' limit " +
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

# Every run's cost: in dollars (the log's result, less $costBefore: a resumed session's result counts the part before
# its pause again) and per window from its first and last usage readings, a window that reset meanwhile left out. A run
# that isn't a whole ticket (partial: paused, resumed, answers, rebase) counts toward the account's spending but not
# toward ticket estimates.
function Add-History($job, [string] $account, [string] $model, [string] $text, [bool] $partial, [long] $startedAt, [double] $costBefore) {
    $start = Get-Usage $text -First
    $end = Get-Usage $text
    if (-not $start -or -not $end) {
        return
    }
    $run = @{
        account = $account; model = $model; size = $job.Size; complexity = $job.Complexity; ticket = $job.Ticket; kind = $job.Kind
        partial = $partial; at = (Get-Now); planSize = Get-AccountPlanSize $account
    }
    # Seconds of wall time, run start to run end, for the queue app's typical run time. The log's own duration_ms is
    # only the last turn. The wall flag marks a line with this meaning; older lines hold the last turn only.
    $run.duration = $run.at - $startedAt
    $run.wall = $true
    $resultLine = ($text -split "`n") | Where-Object { $_ -like '*"type":"result"*' } | Select-Object -Last 1
    if ($resultLine) {
        $result = $resultLine | ConvertFrom-Json
        $run.cost = [math]::Max(0.0, [double]$result.total_cost_usd - $costBefore)
    }
    foreach ($window in $windows) {
        if ($start.$window -and $end.$window -and $start.$window.resetsAt -eq $end.$window.resetsAt) {
            $run[$window] = [math]::Max(0.0, [double]$end.$window.used - [double]$start.$window.used)
        }
    }
    Add-Content $historyFile ($run | ConvertTo-Json -Compress) -Encoding utf8
}

function Invoke-Worker($job, [string] $log, $paused) {
    $slug = Get-JobRepo $job
    $dir = Get-JobDir $slug
    # The environment of the job's checkout (the main loop's Start covered the clone), then what the run gets from the
    # plugins (docs/PLUGINS.md, GetRun). A hook that throws starts no run: the ticket stays this worker's.
    if ($dir -ne $Clone) {
        Invoke-WorkerHooks 'Start' $dir | Out-Null
    }
    $given = Merge-RunAnswers (Invoke-WorkerHooks 'GetRun' $dir)
    # Always a config, with no server when no plugin gives one: the queue app ends a run by this file's path.
    $mcpConfig = Join-Path $queueDir 'mcp.json'
    [System.IO.File]::WriteAllText($mcpConfig, (ConvertTo-McpConfig $given.McpServers))

    # A resumed run keeps the model, effort and account its session started on.
    $settings = Get-RunSettings $Id
    $configDir = $settings.configDir
    $pick = Get-RunModel $job.Complexity $settings (Get-Account $configDir)
    # A PR's job on an account at its Fable stop line starts on the model after Fable (docs/QUEUE.md, The Fable limit): a
    # start on Fable would soon be refused. Between the design line and the stop line it still runs on Fable.
    $afterFable = $job.Kind -ne 'ticket' -and -not $paused -and $pick.Model -like '*fable*' -and
        (Test-FableOut (Read-AllUsage)[(Get-Account $configDir)] (Get-Now) (Get-FableLine (Get-Account $configDir) 'stop'))
    if ($afterFable) {
        $pick = Get-RunModel $job.Complexity $settings (Get-Account $configDir) -AfterFable
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
    $advisorOf = Get-AdvisorRule (Read-Models) (Get-ProjectComplexities)
    $hasAdvisor = -not (Test-ModelRefused (Get-Account $configDir) ([string]$advisorOf.model) -Advisor)
    $advisor = Get-Advisor $advisorOf $job.Complexity $model $hasAdvisor
    if ($paused -and $null -ne $paused.Advisor) {
        $advisor = [string]$paused.Advisor
    } elseif (-not $paused) {
        # Without the advisor its complexity has, a higher effort where models.json says it makes up for it
        # (Get-FallbackEffort). A resumed session keeps its effort.
        $effort = Get-FallbackEffort $advisorOf $job.Complexity $model $effort $hasAdvisor
    }

    switch ($job.Kind) {
        'answered' { $task = "apply the owner's answers and comments on PR #$($job.Pr) and its ticket #$($job.Ticket) (branch t$($job.Ticket))" }
        'needs-rebase' { $task = "rebase PR #$($job.Pr) (ticket #$($job.Ticket), branch t$($job.Ticket)) onto main" }
        default { $task = "ticket #$($job.Ticket), branch t$($job.Ticket)" }
    }
    $playbooks = Get-Playbooks
    if ($paused -and $paused.Session) {
        $cause = if ($paused.FableOut) {
            "Your account reached its weekly Fable limit, so this session goes on with $model. Read the Fable limit part of the playbook first."
        } elseif ($paused.Stopped) { 'The owner paused your worker, and it is active again now.' } else { 'A usage limit or a lost login stopped you, and it is cleared now.' }
        # The pause can last hours, and the playbooks may change meanwhile: a resumed run shipped by old rules.
        $prompt = "$cause Checkpoint first (PLAYBOOK.md, Checkpoints). " +
            "The playbooks may have changed while you were stopped: read them again, $playbooks; where one differs " +
            "from what you read before, the new text wins. Then carry on with your job where you stopped: $task."
        $resumeArgs = @('--resume', $paused.Session)
    } else {
        if ($dir -eq $Clone) {
            $prompt = "You are queue worker $Id, in your own clone. Run git fetch, then read and follow the playbooks " +
                "in this order, a later one winning where two differ: $playbooks. Your job: $task."
        } else {
            $prompt = "You are queue worker $Id, in your own clone of $slug; your ticket is in $repo. Run git fetch, then " +
                "read and follow the playbooks in this order, a later one winning where two differ: $playbooks " +
                "(Another repository applies). Your job: $task."
        }
        $resumeArgs = @()
    }
    $prompt += " You run on $model at $effort effort: name both in the PR body. Your queue folder is " +
        "$($queueDir.Replace('\', '/')): at each checkpoint write progress.json there and look for limit.md, stop.md " +
        "and comments.md there (PLAYBOOK.md, Checkpoints). The Scriptorium folder is $($PSScriptRoot.Replace('\', '/')): " +
        "run a script of it where a playbook says so, and change no file in it."
    # The rest of a Fable job (docs/QUEUE.md, The Fable limit). The note carries the whole
    # instruction, so a run that read an older playbook follows it too.
    if ($paused -and $paused.FableOut -and $job.Kind -eq 'ticket') {
        $prompt += " The Fable limit: this ticket ran on Fable for its decisions, such as how a feature works, a look, " +
            'or a code structure that stays (docs/QUEUE.md, Models). If those decisions are made and ' +
            "written down (code, docs, the ticket), finish the job on $model and name both models in the PR body. If not: " +
            'commit and push, post one handoff comment on the ticket (done, the decisions still open, next), write ' +
            'handoff.md in your queue folder, and end the run without a PR. The worker script then gives the ticket to a ' +
            'worker whose account has Fable, which starts fresh from your comment.'
    } elseif (($paused -and $paused.FableOut) -or $afterFable) {
        $prompt += " Your account reached its weekly Fable limit, so this job runs on ${model}: the PR already holds the " +
            "ticket's decisions."
    }
    if ($given.Prompt) {
        $prompt += " $($given.Prompt)"
    }
    # Claude Code's own commit and PR attribution off: CLAUDE.md allows none. The advisor on (Use-Advisor turns it off).
    $runSettings = Join-Path $queueDir 'run-settings.json'
    $advisorSetting = if ($advisor) { ",`"advisorModel`":`"$advisor`"" } else { '' }
    # The base's tools, the project's and the plugins' (Get-RunTools), as a list: a rule may hold a space
    # (`Bash(unity command:*)`), and a comma-joined --allowedTools value is not sure to keep such a rule whole.
    $allow = ConvertTo-Json -InputObject @(Get-RunTools $config $given) -Compress
    [System.IO.File]::WriteAllText($runSettings, '{"includeCoAuthoredBy":false,"attribution":{"commit":"","pr":""},' +
        '"permissions":{"allow":' + $allow + '}' + $advisorSetting + '}')
    # The same for the run and for the compaction of its session (Compress-Session).
    $sessionArgs = @('--permission-mode', 'auto', '--mcp-config', "`"$mcpConfig`"",
        '--strict-mcp-config', '--settings', "`"$runSettings`"",
        '--disallowedTools', "`"$UnusedTools`"", '--output-format', 'stream-json', '--verbose',
        '--model', $model, '--effort', $effort)
    if ($dir -ne $Clone) {
        # The playbook, CLAUDE.md and the usage warning stay in the clone.
        $sessionArgs += @('--add-dir', "`"$Clone`"")
    }
    $claudeArgs = @('-p', "`"$prompt`"") + $resumeArgs + $sessionArgs

    Remove-Item $warnFile, $stopFile, $commentsFile, $handoffFile -ErrorAction SilentlyContinue
    if (-not $paused) {
        Remove-Item $progressFile -ErrorAction SilentlyContinue
    }
    $account = Get-Account $configDir
    $script:running.model = $model
    $script:running.effort = $effort
    $previousConfigDir = $env:CLAUDE_CONFIG_DIR
    if ($configDir) {
        $env:CLAUDE_CONFIG_DIR = $configDir
    }
    $previousAdvisor = Use-Advisor $advisor
    # What the run's process takes from this script's environment: what the plugins set (docs/PLUGINS.md, GetRun), then
    # the compact window of the job's complexity, in plain digits (docs/CONFIG.md, The compact window).
    $variables = @{}
    foreach ($name in @($given.Env.Keys)) {
        $variables[$name] = $given.Env[$name]
    }
    $variables['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] = [string](Get-ComplexityWindow (Get-ProjectComplexities) $job.Complexity)
    Write-Log "compact window: $($variables['CLAUDE_CODE_AUTO_COMPACT_WINDOW'])"
    $previousVariables = @{}
    foreach ($name in @($variables.Keys)) {
        $previousVariables[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $variables[$name])
    }
    $runStartedAt = Get-Now
    $commentsCheckedAt = 0
    try {
        $process = Start-Process (Get-Command claude).Source -ArgumentList $claudeArgs -WorkingDirectory $dir -NoNewWindow `
            -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        while (-not $process.HasExited) {
            Start-Sleep 30
            # Never let a hiccup here end the watch: the run would go on unwatched and its ticket start again.
            try {
                # First, so a failure below never makes a live script look down in the queue app.
                Write-State 'running' $script:running
                Update-Usage $log $account
                $stop = (Get-Control) -eq 'stop' -or -not (Test-Enabled $Id)
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
        $env:CLAUDE_CONFIG_DIR = $previousConfigDir
        $env:CLAUDE_CODE_DISABLE_ADVISOR_TOOL = $previousAdvisor
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

    $text = Read-Log $log
    $usage = Get-Usage $text
    if ($usage) {
        Save-Usage $account $usage
    }
    $limited = $usage -and $usage.refused
    $modelRefused = $false
    # The account reached its Fable limit (docs/QUEUE.md, The Fable limit): the main loop requeues the ticket or holds
    # the job for the model after Fable.
    $fableOut = $false
    # The account refused the run, or the run could not start on it (limits.ps1, $OutKinds): its kind and its text.
    $refusal = ''
    $refusalText = ''
    $session = [regex]::Match($text, '"session_id":"([^"]+)"').Groups[1].Value
    # A resumed session's result holds its whole cost, the part before the pause too.
    $costBefore = if ($paused -and $paused.Session -and $paused.Cost) { [double]$paused.Cost } else { 0.0 }
    $cost = $costBefore
    $resultLine = ($text -split "`n") | Where-Object { $_ -like '*"type":"result"*' } | Select-Object -Last 1
    if ($resultLine) {
        $result = $resultLine | ConvertFrom-Json
        $cost = [math]::Max($cost, [double]$result.total_cost_usd)
        $kind = Get-Refusal $result
        $refusalText = [string]$result.result
        # A run refused at its first turn did no work: it starts fresh later, not as a resume. Not for the plan's
        # limit: that pause resumes the session the refusal named, as before.
        if ($kind -and $kind -ne 'limit' -and [double]$result.total_cost_usd -eq 0) {
            $session = if ($paused) { $paused.Session } else { '' }
        }
        if ($kind -eq 'model') {
            # The plan doesn't include the model (e.g. "Fable 5.1 requires usage credits").
            $modelRefused = $true
            Set-ModelRefused $account $model
        } elseif ($kind -eq 'limit') {
            $limited = $true
        } elseif ($kind -eq 'fable') {
            $fableOut = $true
        } elseif ($kind -and -not $limited) {
            $refusal = $kind
        }
    }
    # The Fable limit by its rate limit event too: a run that ended with an error in a wording Get-Refusal does not
    # know, or with no result line.
    if ($usage -and $usage.fableRefused -and -not ($resultLine -and -not $result.is_error)) {
        $fableOut = $true
        $refusal = ''
    }
    if ($fableOut) {
        Save-FableOut $account $usage
    }
    # Ended at a checkpoint for the workers' limit or for the owner's pause, its job not done: the main loop holds
    # it with its session (Get-Hold, Suspend-Job).
    $hold = $null
    if (-not ($limited -or $refusal -or $modelRefused -or $fableOut)) {
        $clean = [bool]$resultLine -and -not $result.is_error
        $hold = Get-Hold ([bool]$script:limitNoted) ([bool]$script:stopNoted) (Test-Path $stopFile) $clean (Test-Enabled $Id)
        if ($hold -and (Test-Finished $job)) {
            $hold = $null
        }
    }
    $atLimit = $hold -eq 'limit'
    $stopped = $hold -eq 'pause' -and [bool]$session
    if (-not $modelRefused) {
        $partial = $limited -or $fableOut -or [bool]$refusal -or $atLimit -or $stopped -or [bool]$paused -or $job.Kind -ne 'ticket'
        Add-History $job $account $model $text $partial $runStartedAt $costBefore
    }
    # Not after a stop note the owner withdrew: that run resumes at once, with its cache still warm.
    if ($session -and ($atLimit -or ($stopped -and (Test-Path $stopFile)))) {
        Compress-Session $dir $configDir $session $sessionArgs "$log.compact" $advisor
    }
    return @{
        AtLimit = $atLimit
        Stopped = $stopped
        ModelRefused = $modelRefused
        FableOut = $fableOut
        Limited = $limited
        Refusal = $refusal
        RefusalText = $refusalText
        # Whether a refused run is held for its account: one that did work, or a PR's job. A ticket that no run
        # began is not held: it goes back to the queue (Remove-Claims).
        Holds = [bool]$session -or $job.Kind -ne 'ticket'
        LoggedOut = $false
        Session = $session
        Cost = $cost
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
    }
    if ($end.Stopped -or $end.FableOut) {
        # Not zero: the queue app reads a ticket with a reset time as a run in flight.
        $resetsAt = Get-Now
    }
    @{
        Kind = $job.Kind; Ticket = $job.Ticket; Title = $job.Title; Pr = $job.Pr; Repo = (Get-JobRepo $job); Size = $job.Size; Complexity = $job.Complexity; Session = $end.Session; Cost = $end.Cost
        Model = $end.Model; Effort = $end.Effort; Advisor = [string]$end.Advisor; ConfigDir = $end.ConfigDir; ResetsAt = $resetsAt; LoggedOut = [bool]$end.LoggedOut
        AtLimit = [bool]$end.AtLimit; Stopped = [bool]$end.Stopped; FableOut = [bool]$end.FableOut
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
    if ($end.FableOut) {
        $more = if ($job.Kind -eq 'ticket') { ' If the decisions it is on Fable for are still open, the run hands the ticket to a worker whose account has Fable.' } else { '' }
        Send-Comment $job "its account reached the weekly Fable limit: the run goes on now with $($end.Model).$more"
        Write-Log "#$($job.Ticket) goes on with $($end.Model): its account reached the Fable limit"
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

# A run must end its job (Test-Finished); anything else is parked for the owner, so a failing ticket never loops.
function Test-Outcome($job, [string] $log) {
    if (Test-Finished $job) {
        return
    }
    if ($job.Kind -ne 'ticket') {
        & gh pr edit $job.Pr --add-label needs-owner -R (Get-JobRepo $job) | Out-Null
        Send-Comment $job "stopped without finishing ($($job.Kind)). Log: ``$log``"
        return
    }
    & gh issue edit $job.Ticket --add-label needs-owner -R $repo | Out-Null
    Send-Comment $job "stopped without a PR or a question. Log: ``$log``"
}

# Compacts a session that is held at the workers' limit or for the owner's pause, at once.
# Its cache is still warm, so
# the compaction reads the context cheaply; hours later the cache is gone, and the resume then reads only the summary.
# The run's own arguments: the cache holds only for the same model, tools and settings. A failure is not the job's:
# the session then resumes whole. The run's advisor too ($advisor, Use-Advisor).
function Compress-Session([string] $dir, [string] $configDir, [string] $session, $sessionArgs, [string] $log, [string] $advisor) {
    $previous = $env:CLAUDE_CONFIG_DIR
    if ($configDir) {
        $env:CLAUDE_CONFIG_DIR = $configDir
    }
    $previousAdvisor = Use-Advisor $advisor
    try {
        $process = Start-Process (Get-Command claude).Source -ArgumentList (@('-p', '/compact', '--resume', $session) + $sessionArgs) `
            -WorkingDirectory $dir -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        if (-not $process.WaitForExit(600000)) {
            $process.Kill()
            Write-Log "compaction: no end after 10 minutes, stopped; the session resumes whole. Log: $log"
            return
        }
        $text = Read-Log $log
        $tokens = [regex]::Match($text, '"pre_tokens":(\d+),"post_tokens":(\d+)')
        if ($tokens.Success) {
            $cached = [regex]::Match($text, '"cacheReadInputTokens":(\d+)').Groups[1].Value
            Write-Log "compacted the session: $($tokens.Groups[1].Value) -> $($tokens.Groups[2].Value) tokens, $cached read from the cache"
        } else {
            Write-Log "compaction failed; the session resumes whole. Log: $log"
        }
    } catch {
        Write-Log "compaction error: $_"
    } finally {
        $env:CLAUDE_CONFIG_DIR = $previous
        $env:CLAUDE_CODE_DISABLE_ADVISOR_TOOL = $previousAdvisor
    }
}

# The advisor switch for the claude processes this script starts next: on with $advisor (the run's settings file names
# it), else off, also where the login's own settings name one: a run of the queue gets only the queue's
# advisor. Returns the variable's value before, for the caller to put back.
function Use-Advisor([string] $advisor) {
    $previous = $env:CLAUDE_CODE_DISABLE_ADVISOR_TOOL
    $env:CLAUDE_CODE_DISABLE_ADVISOR_TOOL = if ($advisor) { $null } else { '1' }
    return $previous
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
$script:budgetAt = 0
$script:claimsAt = 0
# Runs in a row that did not start although the account answered a probe.
$script:startFails = 0
while ($true) {
    # Between jobs only: a run in progress finishes on the old code.
    if (Test-CodeChanged) {
        Write-Log 'script changed: restarting on the new code'
        Restart-OnNewCode (Get-TaskName $config.name "worker $Id")
    }
    $polledAt = Get-Date
    $job = $null
    $paused = $null
    try {
        if (-not (Test-Enabled $Id)) {
            Disable-Worker
            Start-Sleep 30
            continue
        }
        Invoke-WorkerHooks 'Start' $Clone -Report | Out-Null
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
            Start-Sleep 30
            continue
        }
        if (Test-Path $pausedFile) {
            $paused = Get-Content $pausedFile -Raw | ConvertFrom-Json
            # A run that ended at a checkpoint, or that its account refused, is held on its account. If the owner
            # moved the worker to another account meanwhile, the session cannot follow: the ticket starts fresh there,
            # from its handoff comment. The same for a run that waits for a limit reset on an account that is out
            # now: it would wait for that account for ever.
            $heldOn = Get-Account $paused.ConfigDir
            if (($paused.AtLimit -or $paused.Stopped -or $paused.LoggedOut -or $paused.FableOut -or (Read-Out)[$heldOn]) -and $heldOn -ne (Get-Account (Get-RunSettings $Id).configDir)) {
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
                # Looked at again every poll, so a stop meanwhile holds it.
                Write-State 'paused' $view
                Start-Sleep ([math]::Min($wait + 60, $PollSeconds))
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
        } elseif (-not (Test-Path $forceFile) -and (Test-OverBudget $runConfigDir)) {
            Write-State 'over-budget'
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
            $log = Join-Path $queueDir "logs\$(Get-Date -Format yyyyMMdd-HHmmss)-t$($job.Ticket)-$($job.Kind).jsonl"
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
            if ($end.ModelRefused -and -not $paused -and $next -ne $end.Model) {
                # The job comes back as this worker's own on the next pass, on the next candidate.
                Write-Log "$($end.Model) refused on $(Get-Account $runConfigDir); #$($job.Ticket) goes on $next"
                continue
            }
            Remove-Item $forceFile -ErrorAction SilentlyContinue
            # A run that did not start is never its ticket's failure. Whose it is decides who stops (Get-Out): the
            # account's stops every worker on it; this worker's own (a model its plan lacks, a wrong setting) stops
            # only this worker.
            $account = Get-Account $end.ConfigDir
            # The Fable limit (docs/QUEUE.md). A run on the model after Fable found the ticket's
            # decisions still open and handed it on: back to the queue, where no dispatcher gives it to this account
            # until the Fable reset (Test-ModelLeft).
            if ($job.Kind -eq 'ticket' -and (Test-Path $handoffFile)) {
                Remove-Item $handoffFile, $pausedFile -ErrorAction SilentlyContinue
                & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                Send-Comment $job ("handed on: its decisions need Fable, and this worker's account reached the Fable limit. " +
                    'A worker whose account has Fable takes it next, fresh from the handoff comment.')
                Write-Log "requeued #$($job.Ticket): handed on for Fable"
                continue
            }
            if ($end.FableOut) {
                if ($job.Kind -eq 'ticket' -and -not $end.Session) {
                    # No run began the ticket: it goes back to the queue the same way.
                    Remove-Item $pausedFile -ErrorAction SilentlyContinue
                    & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                    Write-Log "requeued #$($job.Ticket): $account reached the Fable limit"
                } else {
                    # A run that did work, or a PR's job: it goes on now with the model after Fable, which decides
                    # whether the ticket's decisions are made (Invoke-Worker's prompt).
                    $after = Get-RunModel $job.Complexity $null $account -AfterFable
                    $end.Model = $after.Model
                    $end.Effort = $after.Effort
                    Suspend-Job $job $end
                }
                continue
            }
            $whose = ''
            if ($end.Refusal -in @('login', 'subscription')) {
                $whose = $account
            } elseif ($end.Refusal -eq 'start') {
                # A cause the text does not name: a probe says whether the account takes requests at all.
                $reply = Read-Probe (Invoke-Probe $end.ConfigDir)
                if ($reply -and $OutKinds -contains $reply.kind) {
                    $whose = $account
                    $end.Refusal = $reply.kind
                    $end.RefusalText = $reply.text
                } elseif ($script:startFails -lt 1) {
                    # The account answers. Once may be chance: the job comes back as this worker's own on the next pass.
                    $script:startFails++
                    Write-Log "#$($job.Ticket) did not start ($($end.RefusalText)): tries once more"
                    continue
                } else {
                    $whose = $me
                }
            } elseif ($end.ModelRefused -and $job.Kind -eq 'ticket' -and -not $paused) {
                # The plan has none of the complexity's models: a fact of the plan, not of the ticket or the worker.
                # The ticket goes back to the queue, where no dispatcher gives it to this account (Test-ModelLeft).
                # A PR's job and a resumed run are parked below, as before.
                & gh issue edit $job.Ticket --remove-label $me -R $repo | Out-Null
                Write-Log "requeued #$($job.Ticket): the plan of $account has no model for complexity $($job.Complexity) ($($end.RefusalText))"
                continue
            } elseif (-not $end.ModelRefused) {
                $script:startFails = 0
            }
            if ($whose) {
                $stamp = if ($whose -eq $me) { Get-SettingsStamp } else { Get-LoginStamp $account }
                Set-Out $whose (New-OutRecord $end.Refusal $end.RefusalText $stamp)
                Write-Log "$whose is out ($($end.Refusal)): $($end.RefusalText)"
                $end.LoggedOut = $end.Holds
            }
            if ($end.Limited -or $end.LoggedOut -or $end.AtLimit -or $end.Stopped) {
                Suspend-Job $job $end
            } elseif ($whose) {
                # No run began this ticket. For an account that is out it goes back to the queue at the next look
                # (Remove-Claims); for this worker's own record it stays this worker's.
                Write-Log "#$($job.Ticket) did not start"
            } elseif ((Test-Path $stopFile) -or (Get-Control) -eq 'stop' -or -not (Test-Enabled $Id)) {
                # Disabled from the queue app, or its run ended by a hard stop: not a failure. The ticket or PR starts
                # fresh when the owner resumes, or goes to another worker when this one is disabled.
                Remove-Item $stopFile -ErrorAction SilentlyContinue
                Write-Log "stopped #$($job.Ticket)"
            } else {
                Remove-Item $pausedFile -ErrorAction SilentlyContinue
                # A stop note the owner withdrew may have ended the run already: its ticket resumes, it is not parked.
                if (-not $script:stopNoted) {
                    Test-Outcome $job $log
                }
                Write-Log "done #$($job.Ticket)"
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
    # A force from the queue app since this poll began, or changed code, wakes the next one early.
    $wake = (Get-Now) + $PollSeconds
    while ((Get-Now) -lt $wake -and -not (Test-CodeChanged) -and
        -not ((Test-Path $forceFile) -and (Get-Item $forceFile).LastWriteTime -gt $polledAt)) {
        Start-Sleep 5
    }
}
