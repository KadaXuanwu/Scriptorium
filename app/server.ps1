# The queue app's server (docs/APP.md): serves the page and its state snapshot on localhost (Tailscale serve puts
# it on the owner's devices), does the owner's actions, and sends ntfy notifications. No model, no tokens, except an account's Ping.
# Started at logon by setup.ps1's task; loops until stopped.
param(
    # The project's main checkout.
    [Parameter(Mandatory = $true)] [string] $Project,
    # The page's port: `port` in scriptorium.json when left out.
    [int] $Port
)

$ErrorActionPreference = 'Stop'
# gh writes UTF-8; Windows PowerShell would read it in the console's old code page and garble titles.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot '../restart.ps1')
. (Join-Path $PSScriptRoot '../tasks.ps1')

$Main = Resolve-Project $Project
$config = Read-Project $Main
# The project's plugins, for the Details tab; the page runs on without them when one does not load.
$plugins = @()
# The providers (docs/PLUGINS.md, A provider), each with its models and windows, its logins, and what a run's log
# says: the project's, the default first, and each other one of the install (plugins.ps1, Get-Providers). A worker
# runs on its account's coding tool, so the page serves the accounts and the workers of each. The page runs on
# without one.
$providers = @()
# A plugin the file names that is not installed yet (plugins.ps1, Get-MissingPlugins): the page runs on with the
# others, and the server starts again when setup.ps1 has cloned it. Each worker's card says which one.
$missing = Get-MissingPlugins (Split-Path $PSScriptRoot -Parent) $config
if ($missing.Count) {
    Add-Content (Join-Path $Main '.queue/app.log') "$(Get-Date -Format s) $(Get-MissingText $missing)" -Encoding utf8
}
try {
    $plugins = Import-Plugins (Split-Path $PSScriptRoot -Parent) $config -Installed
    $providers = Get-Providers (Split-Path $PSScriptRoot -Parent) $plugins
} catch {
    Add-Content (Join-Path $Main '.queue/app.log') "$(Get-Date -Format s) plugins: $_" -Encoding utf8
}
Start-CodeWatch (@((Join-Path $Main 'scriptorium.json')) + @(@($plugins) + @($providers) | ForEach-Object { $_.Dir }) +
    @($providers | ForEach-Object { Join-Path $_.Dir 'models.json' }) + @($missing | ForEach-Object { $_.Watch }))
# The default is set. A provider's calls get the settings as the snapshot last read them.
Set-Providers $providers @{ Project = $Main; Copy = $Main; Machine = { $script:saved } }
# The project's default provider: each snapshot and each action starts from it (plugins.ps1, Select-Provider).
$defaultProvider = $script:Provider
if (-not $Port) {
    $Port = [int]$config.port
}

# One server per project: stopping the task ends only its console host, so an older loop may still run. End it.
Get-CommandLines -Shells |
    Where-Object { $_.ProcessId -ne $PID -and (Test-ProjectProcess $_.CommandLine 'server.ps1' $Main) } |
    ForEach-Object { Stop-ProcessTree $_.ProcessId }

$mainQueue = Join-Path $Main '.queue'
# A PC from before an account had a provider: the accounts this project's workers are on become its default provider's.
# Not while a plugin is missing: it may be the default provider, and the one set here another tool's.
if ($script:Provider -and -not $missing.Count) {
    Update-AccountProviders $Main @(Get-ChildItem (Join-Path $mainQueue 'worker-*.json') -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName.Substring(7) }) $script:Provider.Name
}
$web = Join-Path $PSScriptRoot 'web'
$logFile = Join-Path $mainQueue 'app.log'
Set-Location $Main
Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
function Write-AppLog([string] $text) {
    Add-Content $logFile "$(Get-Date -Format s) $text" -Encoding utf8
}

# An error the main loop doesn't catch ends the server: say why, or the task ends it silently.
trap {
    Write-AppLog "server stopped: $_"
    break
}

# Nothing of the PC's stays in the project: account keys and records from before the PC's files move there (pc.ps1).
try {
    Initialize-Pc $Main
} catch {
    Write-AppLog "the PC's files: $_"
}

# From the remote, not GitHub: a GitHub timeout at the start ended the restart silently.
$slug = [regex]::Match((& git remote get-url origin), 'github\.com[:/](.+?)(\.git)?$').Groups[1].Value
$owner = $slug.Split('/')[0]

function Get-Now {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# The PC's projects with their pages' addresses (state.ps1, Get-ProjectViews), for the page's project switch, the
# pages that may ask here and the pushes; and this page's own address on the owner's devices ($appUrl): the one that
# Tailscale Serve gives its port, else localhost. Read at the start and every five minutes: the lookup of the logon
# tasks takes half a second, and setup can add a project or an address while this server runs.
function Update-Projects {
    $found = @(Get-PcProjects | Where-Object { $_.name -ne $config.name }) + [pscustomobject]@{ name = [string]$config.name; port = $Port }
    $script:projects = @(Get-ProjectViews $found (Read-Serve))
    $own = $script:projects | Where-Object { $_.name -eq $config.name }
    $script:appUrl = if ($own.url) { $own.url } else { $own.local }
}
Update-Projects

# GitHub, fetched in a background job so the page never waits on it: open tickets, worker PRs in every repo a ticket
# names, recent merges, titles of closed tickets, and each held ticket's last worker question. All as the owner.
$fetch = {
    param([string] $Main, [string] $slug)
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Set-Location $Main
    Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    # Windows PowerShell's ConvertFrom-Json passes a JSON list on as one object; returning it from a variable unrolls it.
    function Get-Gh([string[]] $ghArgs) {
        $json = ((& gh @ghArgs) -join "`n") | ConvertFrom-Json
        return $json
    }
    $issues = @(Get-Gh @('issue', 'list', '--state', 'open', '--limit', '500', '--json', 'number,title,labels,body,createdAt,url', '-R', $slug))
    $repos = @(@($slug) + @($issues | ForEach-Object { $_.labels } | Where-Object { $_.name -like 'repo:*' } |
        ForEach-Object { "$($slug.Split('/')[0])/$($_.name.Substring(5))" }) | Sort-Object -Unique)
    $prs = @()
    $merged = @()
    foreach ($repo in $repos) {
        $prs += @(Get-Gh @('pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,headRefName,labels,body,url', '-R', $repo) |
            ForEach-Object { $_ | Add-Member -NotePropertyName repo -NotePropertyValue $repo -PassThru })
        $merged += @(Get-Gh @('pr', 'list', '--state', 'merged', '--limit', '8', '--json', 'number,title,mergedAt,url', '-R', $repo) |
            ForEach-Object { $_ | Add-Member -NotePropertyName repo -NotePropertyValue $repo -PassThru })
    }
    $titles = @{}
    foreach ($issue in Get-Gh @('issue', 'list', '--state', 'all', '--limit', '200', '--json', 'number,title', '-R', $slug)) {
        $titles["$($issue.number)"] = $issue.title
    }
    $questions = @{}
    foreach ($issue in $issues | Where-Object { @($_.labels | ForEach-Object { $_.name }) -contains 'needs-owner' }) {
        $comments = @((Get-Gh @('issue', 'view', "$($issue.number)", '--json', 'comments', '-R', $slug)).comments |
            Where-Object { $_.body.StartsWith('**Worker') })
        if ($comments.Count -gt 0) {
            $questions["$($issue.number)"] = $comments[-1].body
        }
    }
    @{ issues = $issues; prs = $prs; merged = $merged; titles = $titles; questions = $questions } | ConvertTo-Json -Depth 10 -Compress
}

# A worker's clone; a state written before clones were recorded means the one beside this checkout.
function Get-Clone([string] $id, $state) {
    if ($state -and $state.clone) {
        return $state.clone
    }
    return "$Main-w$id"
}

# Read again only when the file changed: parsing its last 300 lines was the snapshot's second biggest cost.
$script:runs = @()
$script:runsStamp = ''
function Read-Runs {
    $file = Get-Item (Join-Path $mainQueue 'history.jsonl') -ErrorAction SilentlyContinue
    if (-not $file) {
        return @()
    }
    $stamp = "$($file.LastWriteTimeUtc.Ticks) $($file.Length)"
    if ($stamp -ne $script:runsStamp) {
        $script:runs = @(Get-Content $file.FullName -Tail 300 -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
        $script:runsStamp = $stamp
    }
    return $script:runs
}

# A login's state as the provider reads it, no process started (docs/PLUGINS.md, GetLogin): signed in, its plan and
# its email. With a provider that cannot tell: signed in.
function Get-LoginInfo([string] $configDir) {
    try {
        $login = Invoke-Provider 'GetLogin' @{ Login = [string]$configDir }
    } catch {
        return @{ signedIn = $false }
    }
    if (-not $login) {
        return @{ signedIn = [bool]$script:Provider }
    }
    $info = @{ signedIn = [bool]$login.SignedIn }
    if ($info.signedIn) {
        $info.plan = [string]$login.Plan
        if ($login.Email) {
            $info.email = [string]$login.Email
        }
    }
    return $info
}

# The sign-in started from the page (docs/APP.md, Accounts): one at a time, the provider's sign-in command for an
# account's login folder (docs/PLUGINS.md, SignIn). The page shows its sign-in link and passes it the code; on a PC
# with a browser it may finish alone.
$script:login = $null
function Start-Login([string] $name, [string] $configDir, [string] $email) {
    Stop-Login
    $start = Invoke-Provider 'SignIn' @{ Login = $configDir; Email = $email }
    if (-not $start -or -not $start.Command) {
        throw 'the provider has no sign-in from the page: sign the account in from a terminal'
    }
    $out = Join-Path $mainQueue 'login.txt'
    Remove-Item $out -ErrorAction SilentlyContinue
    $info = New-Object System.Diagnostics.ProcessStartInfo
    if ($OnWindows) {
        $info.FileName = $env:ComSpec
        $info.Arguments = "/c $($start.Command) > `"$out`" 2>&1"
    } else {
        $info.FileName = '/bin/sh'
        $info.ArgumentList.Add('-c')
        $info.ArgumentList.Add("$($start.Command) > '$out' 2>&1")
    }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    # The provider's variables, its login folder among them. One with no value is taken away.
    if ($start.Env) {
        foreach ($key in @($start.Env.Keys)) {
            if ($null -ne $start.Env[$key]) {
                $info.EnvironmentVariables[$key] = [string]$start.Env[$key]
            } else {
                $info.EnvironmentVariables.Remove($key)
            }
        }
    }
    # Its provider reads the sign-in's output until it ends (Get-LoginView).
    $script:login = @{ account = $name; configDir = $configDir; out = $out; at = Get-Now; ended = $null
        provider = $script:Provider; process = [System.Diagnostics.Process]::Start($info) }
}

function Stop-Login {
    if ($script:login -and -not $script:login.process.HasExited) {
        Stop-ProcessTree $script:login.process.Id
    }
    $script:login = $null
}

# The sign-in as the page shows it: starting, waiting (its link), done or failed (the tool's last line), as the
# provider reads its output (docs/PLUGINS.md, ReadSignIn). A finished one
# stays two minutes; one waiting 15 minutes is ended.
function Get-LoginView {
    $login = $script:login
    if (-not $login) {
        return $null
    }
    $text = ''
    if (Test-Path $login.out) {
        $stream = [System.IO.File]::Open($login.out, 'Open', 'Read', 'ReadWrite')
        try {
            $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        } finally {
            $stream.Dispose()
        }
    }
    $view = @{ account = $login.account; state = 'starting' }
    $read = $null
    try {
        $read = Use-Provider $login.provider { Invoke-Provider 'ReadSignIn' @{ Text = $text } }
    } catch {
    }
    $url = if ($read) { [string]$read.Url } else { '' }
    if ($url) {
        $view.url = $url
        $view.state = 'waiting'
    }
    if ($login.process.HasExited) {
        if (-not $login.ended) {
            $login.ended = Get-Now
            if ($login.process.ExitCode -eq 0) {
                Write-AppLog "signed in: $($login.account)"
            } else {
                Write-AppLog "sign-in failed: $($login.account)"
            }
        }
        if ($login.process.ExitCode -eq 0) {
            $view.state = 'done'
        } else {
            $view.state = 'failed'
            $view.message = if ($read -and $read.Message) { [string]$read.Message } else { 'The sign-in ended.' }
        }
        if ((Get-Now) - $login.ended -gt 120) {
            $script:login = $null
        }
    } elseif ((Get-Now) - $login.at -gt 900) {
        Stop-Login
        return $null
    }
    return $view
}

# The settings for an edit, the project's own with the PC's (pc.ps1): never overwritten when missing, and a file that
# does not parse throws. The caller holds the PC's lock from here to its save: an action (Invoke-Request) or
# Set-Enabled.
function Read-SettingsToEdit {
    $settings = Read-ProjectSettings $Main
    if (-not $settings) {
        throw 'settings.json is missing'
    }
    if (-not $settings.accounts) {
        $settings | Add-Member -NotePropertyName accounts -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $settings
}

function Save-Settings($settings) {
    Save-ProjectSettings $Main $settings
}

# This project's control, or the control of the project in $queue (a worker's move).
function Save-Control($control, [string] $queue = $mainQueue) {
    $control | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $queue 'control.json') -Encoding utf8
}

# The worker's `enabled` in the settings (docs/QUEUE.md, Settings); written only when it changes.
function Set-Enabled([string] $worker, [bool] $enabled) {
    $lock = Enter-PcLock 'Settings'
    try {
        $settings = Read-SettingsToEdit
        $entry = Get-WorkerSettings $settings $worker
        if (($entry.enabled -ne $false) -eq $enabled) {
            return
        }
        $entry | Add-Member -NotePropertyName enabled -NotePropertyValue $enabled -Force
        Save-Settings $settings
    } finally {
        Exit-PcLock $lock
    }
}

# Ends a worker's run now: the process its script started (the `pid` of its running state) and that one's children.
# Only the process that started when the state says (`pidStarted`): a state gone stale may name a number that
# another process has now. Work since the run's last checkpoint push is lost.
function Stop-Run([string] $worker, $state) {
    $id = if ($state -and $state.state -eq 'running') { [int]$state.pid } else { 0 }
    $process = if ($id) { Get-Process -Id $id -ErrorAction SilentlyContinue } else { $null }
    $started = ''
    try {
        $started = [string]$process.StartTime.ToUniversalTime().Ticks
    } catch {
    }
    if (-not $process -or -not $started -or $started -ne [string]$state.pidStarted) {
        return 0
    }
    Stop-ProcessTree $id
    return 1
}

# A worker the owner added (docs/APP.md, Workers): its state file until its script writes one, 'setup' while
# the server sets it up, 'setup-failed' with the reason after that failed (state.ps1, New-Snapshot).
function Write-Setup([string] $id, [string] $state, [string] $reason) {
    @{ state = $state; at = Get-Now; clone = "$Main-w$id"; error = $reason } | ConvertTo-Json -Compress |
        Set-Content (Join-Path $mainQueue "worker-$id.json") -Encoding utf8
}

# A new worker's setup (tasks.ps1, Install-Worker) in a background job: the clone takes minutes, and the page goes on.
# Cmdlets stop at an error; a native command's error is its exit code, which Install-Worker checks.
$installWorker = {
    param([string] $tasks, [string] $Main, [string] $name, [string] $slug, [string] $id)
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Set-Location $Main
    Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    # No window to sign in: git fails at once instead of waiting for a prompt nobody sees.
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    . $tasks
    Install-Worker $Main $name $slug $id
}
# Whether a worker's GitHub bot ($ghConfigDir) may push to this project's repo: also yes for no bot, or a folder that
# is not signed in, as the worker then writes as the owner (worker.ps1, Set-GitHubIdentity). 'Continue': under 'Stop',
# Windows PowerShell turns a program's error text into a stop. The server runs without GH_CONFIG_DIR again after.
function Test-BotPush([string] $ghConfigDir) {
    if (-not $ghConfigDir) {
        return $true
    }
    $ErrorActionPreference = 'Continue'
    $env:GH_CONFIG_DIR = $ghConfigDir
    try {
        & gh auth token 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return $true
        }
        $push = "$(& gh api "repos/$slug" --jq .permissions.push 2>$null)".Trim()
        return $LASTEXITCODE -eq 0 -and $push -eq 'true'
    } finally {
        Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    }
}

# Worker id -> its setup job and when it started. A setup longer than this is ended and fails.
$script:setups = @{}
$SetupSeconds = 3600

# The deletes of worker copies that run, each a background job and its folder: a copy of a large project takes minutes.
$script:deletes = @()
# What an action did not do though it went through (a copy that stays): the page shows it to the owner.
$script:note = ''

function Start-CopyDelete([string] $folder) {
    $job = Start-Job -ArgumentList (Join-Path $PSScriptRoot '../tasks.ps1'), $folder -ScriptBlock {
        param([string] $tasks, [string] $folder)
        . $tasks
        Remove-Tree $folder
    }
    $script:deletes += @{ job = $job; folder = $folder }
}

# The owner's tick in the Remove and move dialogs (docs/APP.md, Add and remove): worker $id's copy of the project $main
# goes for good. Call it after Uninstall-Worker, which ends what runs from the copy. A copy that a program still uses
# stays as it is, and the page says so. Never the worker's checkouts of other repos. Returns the words for the log.
function Remove-Copy([string] $main, [string] $id) {
    $trash = Rename-CopyToDelete $main $id
    if ($trash) {
        Start-CopyDelete $trash
        return '; its copy goes'
    }
    if (Test-Path -LiteralPath "$main-w$id") {
        $script:note = "A program still uses a file in $(Split-Path "$main-w$id" -Leaf), so this copy stays on the PC. The rest is done."
        return '; its copy stays, a program uses it'
    }
    return ''
}

$script:gh = $null
$script:snapshot = $null
$script:json = '{}'
function Update-Snapshot {
    Select-Provider $defaultProvider
    $workers = @()
    foreach ($file in Get-ChildItem (Join-Path $mainQueue 'worker-*.json') -ErrorAction SilentlyContinue) {
        $state = Read-Json $file.FullName
        if (-not $state) {
            continue
        }
        $id = $file.BaseName.Substring(7)
        $clone = Get-Clone $id $state
        $workers += @{
            id = $id; state = $state; forced = Test-Path (Join-Path $mainQueue "force-$id.json")
            now = Read-Now (Join-Path $mainQueue "force-$id.json")
            progress = Read-Json (Join-Path $clone '.queue/progress.json')
        }
    }
    # A worker marked to disable after its ticket, whose run has ended: disable it now.
    $control = Read-Json (Join-Path $mainQueue 'control.json')
    $states = @{}
    foreach ($worker in $workers) {
        $states[$worker.id] = [string]$worker.state.state
    }
    foreach ($id in Get-DueDisables $control $states) {
        Save-Control (Set-WorkerStatus $control $id 'disabled' 'now' $false).control
        Set-Enabled $id $false
        Write-AppLog "disabled after its ticket: worker $id"
        $control = Read-Json (Join-Path $mainQueue 'control.json')
    }
    # The settings as last read: a file that does not parse must not empty the page. Its error goes to the log once.
    try {
        $script:saved = Read-ProjectSettings $Main
        $script:savedError = ''
    } catch {
        if ("$_" -ne $script:savedError) {
            $script:savedError = "$_"
            Write-AppLog "settings: $_"
        }
    }
    $saved = $script:saved
    $data = @{
        now = Get-Now; slug = $slug; workers = $workers; control = $control
        usage = Read-Json (Join-Path $PcDir 'usage.json'); out = Read-Json (Join-Path $PcDir 'out.json'); settings = $saved
        runs = Read-Runs; gh = $script:gh; appUrl = $appUrl; dispatch = Read-Json (Join-Path $mainQueue 'dispatch.json')
        name = $config.name; projects = $script:projects
        logins = @{}; login = Get-LoginView; complexities = Get-Complexities (Read-Models) $config $saved; plugins = $plugins
        config = $config
    }
    if ($data.settings -and $data.settings.accounts) {
        foreach ($property in $data.settings.accounts.PSObject.Properties) {
            # Only the provider of an account's coding tool can read its login.
            if (-not (Test-KnownAccount $property.Value)) {
                continue
            }
            $key = if ($property.Value.configDir) { $property.Value.configDir } else { 'default' }
            $data.logins[$key] = Use-Provider (Get-AccountProvider $property.Value (Get-KnownProviders)) { Get-LoginInfo $property.Value.configDir }
        }
    }
    if ($script:snapshot -and $data.now - [long]$script:snapshot.now -gt $StaleSeconds) {
        $script:awake = $data.now
    }
    $data.awake = $script:awake
    $new = New-Snapshot $data
    foreach ($note in Get-Events $script:snapshot $new) {
        Send-Notification $note $data.settings
    }
    $script:snapshot = $new
    $script:json = $new | ConvertTo-Json -Depth 10 -Compress
}

# ntfy, when `ntfy.topic` is set in .queue/settings.json (setup.ps1 makes one).
function Send-Notification($note, $settings) {
    if (-not $settings -or -not $settings.ntfy -or -not $settings.ntfy.topic) {
        return
    }
    $server = if ($settings.ntfy.server) { $settings.ntfy.server.TrimEnd('/') } else { 'https://ntfy.sh' }
    try {
        Invoke-RestMethod -Method Post -Uri "$server/$($settings.ntfy.topic)" -Body ([System.Text.Encoding]::UTF8.GetBytes($note.message)) -Headers @{
            Title = $note.title; Priority = "$($note.priority)"; Tags = $note.tags; Click = Get-PushUrl $script:projects $appUrl $note.click
        } | Out-Null
        Write-AppLog "notified: $($note.title): $($note.message)"
    } catch {
        Write-AppLog "notify failed: $_"
    }
}

# A comment as the owner, through a file so quotes and line breaks arrive as written; $ghWrite deletes the file.
function New-CommentCall([string] $kind, [int] $number, [string] $repo, [string] $text) {
    $file = Join-Path $mainQueue "app-comment-$([guid]::NewGuid().ToString('N')).md"
    [System.IO.File]::WriteAllText($file, $text)
    $verb = if ($kind -eq 'pr') { 'pr' } else { 'issue' }
    return , @($verb, 'comment', "$number", '--body-file', $file, '-R', $repo)
}

# An action's GitHub writes, in order, in a background job: a slow GitHub then holds only that action's answer, and
# the page's other requests go on (one label edit took minutes and the page showed the PC unreachable).
$ghWrite = {
    param([string] $Main, [string] $callsJson)
    Set-Location $Main
    Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue
    $calls = $callsJson | ConvertFrom-Json
    try {
        foreach ($call in $calls) {
            & gh @call | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "gh $($call[0]) $($call[1]) failed"
            }
        }
    } finally {
        foreach ($call in $calls) {
            $at = [array]::IndexOf($call, '--body-file')
            if ($at -ge 0) {
                Remove-Item $call[$at + 1] -ErrorAction SilentlyContinue
            }
        }
    }
}
$script:writes = @()

# Account $name's entry (state.ps1, Get-KnownAccount), with the provider of its coding tool set for the rest of the
# action: its windows, its sign-in, its Ping.
function Select-Account($settings, [string] $name) {
    $entry = Get-KnownAccount $settings $name
    Select-Provider (Get-AccountProvider $entry (Get-KnownProviders))
    return $entry
}

# The owner's actions (docs/APP.md). One that writes to GitHub returns its calls. Each starts with the project's
# default provider set: Details sets its models. An account's action sets the account's own (Select-Account).
function Invoke-Action($request) {
    Select-Provider $defaultProvider
    $worker = [string]$request.worker
    switch ($request.action) {
        'status' {
            # The worker's status (docs/APP.md, Worker status): active, paused or disabled, and how its run ends.
            if (@('', 'now', 'checkpoint', 'finish') -notcontains [string]$request.how) {
                throw "unknown way to end the run: $($request.how)"
            }
            $ids = if ($worker -eq 'all') {
                @(Get-ChildItem (Join-Path $mainQueue 'worker-*.json') | ForEach-Object { $_.BaseName.Substring(7) })
            } else {
                @($worker)
            }
            $ended = 0
            foreach ($id in $ids) {
                $state = Read-Json (Join-Path $mainQueue "worker-$id.json")
                if (-not $state) {
                    throw "no worker $id"
                }
                # A run in flight: working, or waiting in paused.json for a limit reset.
                $inFlight = $state.state -eq 'running' -or [bool]($state.ticket -and $state.resetsAt)
                $result = Set-WorkerStatus (Read-Json (Join-Path $mainQueue 'control.json')) $id ([string]$request.to) ([string]$request.how) $inFlight
                Save-Control $result.control
                Set-Enabled $id $result.enabled
                # A Now that waits for this worker ends with its pause or disable: else its ticket waits with the worker.
                $force = Join-Path $mainQueue "force-$id.json"
                $now = Read-Now $force
                if ([string]$request.to -ne 'active' -and $now -and $now -ne [int]$state.ticket) {
                    Remove-Item $force -ErrorAction SilentlyContinue
                }
                if ($result.kill) {
                    $ended += Stop-Run $id $state
                }
            }
            return "$($request.to) ($($request.how)): worker $worker$(if ($ended) { ", $ended process(es) ended" })"
        }
        { @('force', 'unforce') -contains $_ } {
            # The worker's force file (worker.ps1, $forceFile): its next job starts past the area, room and ceiling checks.
            # It names the ticket the page shows as the worker's next, so the worker takes that one.
            if (-not (Test-Path (Join-Path $mainQueue "worker-$worker.json"))) {
                throw "no worker $worker"
            }
            $file = Join-Path $mainQueue "force-$worker.json"
            if ($request.action -eq 'force') {
                $next = ($script:snapshot.workers | Where-Object { $_.id -eq $worker } | Select-Object -First 1).next
                Set-Content $file (@{ ticket = $(if ($next) { [int]$next.number } else { 0 }) } | ConvertTo-Json -Compress) -Encoding utf8
            } else {
                Remove-Item $file -ErrorAction SilentlyContinue
            }
            return "$($request.action): worker $worker"
        }
        'now' {
            # Now (docs/QUEUE.md, Now): the queued ticket goes into the force file of the worker that the page showed
            # for it (Select-NowWorker), with `now`. That worker takes it before every other job. Its run in progress
            # ends at its next checkpoint, and that run's ticket goes back to the queue.
            $number = [int]$request.number
            $row = $script:snapshot.queued | Where-Object { [int]$_.number -eq $number } | Select-Object -First 1
            if (-not $row -or -not $row.now) {
                throw "ticket $number is not a queued ticket that can run now"
            }
            if (-not $row.now.worker) {
                throw [string]$row.now.why
            }
            $file = Join-Path $mainQueue "force-$($row.now.worker).json"
            if (Test-Path $file) {
                throw "worker $($row.now.worker) has a forced ticket already"
            }
            Set-Content $file (@{ ticket = $number; now = $true } | ConvertTo-Json -Compress) -Encoding utf8
            return "now: #$number on worker $($row.now.worker)"
        }
        'rename-worker' {
            # The worker's name on the page (docs/APP.md, Worker status): the PC's, so it stays with a move.
            if (-not (Test-Path (Join-Path $mainQueue "worker-$worker.json"))) {
                throw "no worker $worker"
            }
            Save-Settings (Set-WorkerName (Read-SettingsToEdit) $worker ([string]$request.name))
            return "worker $worker named '$(([string]$request.name).Trim())'"
        }
        'order' {
            # The owner's order of the worker or account cards (docs/APP.md, Order): the PC's, so every device shows it.
            Save-Settings (Set-CardOrder (Read-SettingsToEdit) ([string]$request.kind) $request.list)
            return "order: $($request.kind)"
        }
        'rename-account' {
            # An account's name (docs/APP.md, Accounts): only its key in the register; its folder and records stay.
            $old = [string]$request.account
            $new = [string]$request.name
            $settings = Read-SettingsToEdit
            [void](Get-KnownAccount $settings $old)
            Save-Settings (Rename-Account $settings $old $new)
            # A sign-in of it goes on in the same folder; only its box shows the name.
            if ($script:login -and $script:login.account -eq $old) {
                $script:login.account = $new
            }
            return "account $old renamed $new"
        }
        'assign' {
            if (-not (Test-Path (Join-Path $mainQueue "worker-$worker.json"))) {
                throw "no worker $worker"
            }
            # The worker runs on its account's coding tool, so an account of another tool changes its tool: not
            # while it has a run in flight (state.ps1, Get-ToolRefusal). A run that it holds counts by its file in
            # the worker's copy, as for a move to another project: a disabled worker's state does not name it.
            $settings = Read-SettingsToEdit
            $known = Get-KnownProviders
            $from = Get-WorkerProvider $settings $worker $known
            $settings = Set-WorkerAccount $settings $worker ([string]$request.account)
            $state = Read-Json (Join-Path $mainQueue "worker-$worker.json")
            $inFlight = $state.state -eq 'running' -or [bool]($state.ticket -and $state.resetsAt) -or
                (Test-Path (Join-Path (Get-Clone $worker $state) '.queue/paused.json'))
            $refusal = Get-ToolRefusal $from (Get-WorkerProvider $settings $worker $known) $inFlight
            if ($refusal) {
                throw "worker ${worker}: $refusal"
            }
            Save-Settings $settings
            return "worker $worker on $(if ($request.account) { $request.account } else { 'the command-line login' })"
        }
        'complexity' {
            # Whether a worker takes the tickets of a complexity (docs/QUEUE.md, Settings, `workers.<id>.complexity`).
            $worker = [string]$request.worker
            $name = [string]$request.complexity
            $settings = Read-SettingsToEdit
            # The complexities of the worker's own coding tool.
            $tool = Get-WorkerProvider $settings $worker (Get-KnownProviders)
            Select-Provider $tool
            $own = Get-ProviderConfig $config (-not $tool -or $tool.Name -eq $defaultProvider.Name)
            if ($worker -notmatch '^\d+$' -or @(Get-Complexities (Read-Models) $own | ForEach-Object { $_.name }) -cnotcontains $name) {
                throw "no worker $worker or no complexity $name"
            }
            $entry = Get-WorkerSettings $settings $worker
            if (-not $entry.complexity) {
                $entry | Add-Member -NotePropertyName complexity -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry.complexity | Add-Member -NotePropertyName $name -NotePropertyValue ([bool]$request.on) -Force
            Save-Settings $settings
            return "complexity: worker $worker $name $(if ($request.on) { 'on' } else { 'off' })"
        }
        'add-worker' {
            # One worker more (docs/APP.md, Workers): the lowest number that no worker of the PC has, active, on the
            # account the owner picked ('' for the command-line login). A number is the PC's, not the project's: the
            # worker tasks of every project count. Its card shows at once; its clone, label and task come from a job.
            $taken = @(Get-ChildItem (Join-Path $mainQueue 'worker-*.json') | ForEach-Object { $_.BaseName.Substring(7) }) +
                @(Get-QueueTasks (Get-WorkerTaskName '*' '*') | ForEach-Object { $_.TaskName.Split(' ')[-1] })
            $id = Get-FreeWorkerId $taken
            $account = [string]$request.account
            Save-Settings (Set-WorkerEntry (Read-SettingsToEdit) $id $true $account)
            # What a removed worker of this number left must not hold the new one: a pause, a disable to come, a Force.
            Save-Control (Set-WorkerStatus (Read-Json (Join-Path $mainQueue 'control.json')) $id 'active' '' $false).control
            Remove-Item (Join-Path $mainQueue "force-$id.json") -ErrorAction SilentlyContinue
            Write-Setup $id 'setup' ''
            $script:setups[$id] = @{ at = Get-Now
                job = Start-Job -ScriptBlock $installWorker -ArgumentList (Join-Path $PSScriptRoot '../tasks.ps1'), $Main, $config.name, $slug, $id }
            return "adding worker $id on $(if ($account) { $account } else { 'the command-line login' })"
        }
        'remove-worker' {
            # Only a disabled worker with no run in flight (Get-RemoveRefusal). Its task and loop end first, so nothing
            # writes its files again; then its files and entries go. Its clone stays: it may hold work no checkpoint
            # pushed, and a new worker of this number uses it again. Only the owner's tick (`deleteCopy`) deletes it,
            # last, when the worker is gone. Its `worker:N` claims pass to the other workers as a disabled worker's do
            # (worker.ps1, Get-NextJob).
            if ($worker -notmatch '^\d+$') {
                throw "no worker $worker"
            }
            $file = Join-Path $mainQueue "worker-$worker.json"
            $state = Read-Json $file
            if (-not $state) {
                throw "no worker $worker"
            }
            $settings = Read-SettingsToEdit
            $enabled = -not ($settings.workers -and $settings.workers.$worker -and $settings.workers.$worker.enabled -eq $false)
            # A state its script no longer refreshes (state.ps1, New-Snapshot): the script is gone, and so is its loop.
            $alive = (Get-Now) - [math]::Max([long]$state.at, [long]$script:awake) -le $StaleSeconds
            $refusal = Get-RemoveRefusal $state $enabled $script:setups.ContainsKey($worker) $alive
            if ($refusal) {
                throw "worker ${worker}: $refusal"
            }
            Uninstall-Worker $Main $config.name $worker
            # A run that its dead script left behind ends too.
            Stop-Run $worker $state | Out-Null
            Remove-Item $file
            Remove-Item (Join-Path $mainQueue "force-$worker.json") -ErrorAction SilentlyContinue
            Save-Settings (Set-WorkerEntry $settings $worker $false)
            Save-Control (Set-WorkerStatus (Read-Json (Join-Path $mainQueue 'control.json')) $worker 'active' '' $false).control
            return "removed: worker $worker$(if ($request.deleteCopy -eq $true) { Remove-Copy $Main $worker })"
        }
        'move-worker' {
            # A worker of another project of the PC comes to this one with its number (docs/APP.md, Workers): the page
            # sends the move here, and this server does all of it. Every refusal comes before the first change. Its
            # settings entry, its account and its `enabled` are the PC's and stay as they are.
            if ($worker -notmatch '^\d+$') {
                throw "no worker $worker"
            }
            $from = [string]$request.from
            # The old project by its name, from the PC's logon tasks: nothing from the request becomes a path.
            $old = Get-PcProjects | Where-Object { $_.name -ceq $from -and $_.name -ne $config.name } |
                Select-Object -First 1
            if (-not $old) {
                throw "no project $from"
            }
            if ((Test-Path (Join-Path $mainQueue "worker-$worker.json")) -or $script:setups.ContainsKey($worker)) {
                throw "worker $worker is in $($config.name) already"
            }
            $oldQueue = Join-Path $old.main '.queue'
            $state = Read-Json (Join-Path $oldQueue "worker-$worker.json")
            if (-not $state) {
                throw "no worker $worker in $from"
            }
            $oldControl = Read-Json (Join-Path $oldQueue 'control.json')
            $copy = if ($state.clone) { [string]$state.clone } else { "$($old.main)-w$worker" }
            # As Remove counts a script alive: after the PC wakes, a state is old though its run goes on.
            $fresh = (Get-Now) - [math]::Max([long]$state.at, [long]$script:awake) -le $StaleSeconds
            $marked = [bool]($oldControl -and $oldControl.disable -and $oldControl.disable.$worker)
            $refusal = Get-MoveRefusal $state $fresh (Test-Path (Join-Path $copy '.queue/paused.json')) $marked
            if ($refusal) {
                throw "worker ${worker}: $refusal"
            }
            $settings = Read-SettingsToEdit
            $entry = if ($settings.workers) { $settings.workers.$worker }
            if (-not (Test-BotPush $(if ($entry) { [string]$entry.ghConfigDir }))) {
                throw "worker ${worker}: its GitHub bot cannot push to ${slug}: invite the bot to the repo first"
            }
            $status = Get-CarriedStatus $settings $oldControl $worker
            # Its control entry here comes first: its script reads it before its first job, so a paused worker never
            # arrives active.
            $control = Read-Json (Join-Path $mainQueue 'control.json')
            Save-Control (Set-WorkerStatus $control $worker $status '' $false).control
            Remove-Item (Join-Path $mainQueue "force-$worker.json") -ErrorAction SilentlyContinue
            Write-Setup $worker 'setup' ''
            try {
                Uninstall-Worker $old.main $old.name $worker
                Remove-Item (Join-Path $oldQueue "worker-$worker.json")
                Remove-Item (Join-Path $oldQueue "force-$worker.json") -ErrorAction SilentlyContinue
                # No entry of it stays in the old control. There a disable mark of a worker with no state file is
                # due (Get-DueDisables), and the old project's server would write `enabled: false` for the worker
                # here.
                Save-Control (Set-WorkerStatus $oldControl $worker 'active' '' $false).control $oldQueue
            } catch {
                # The worker did not leave its old project: no card of it stays here, where no setup job runs. The
                # owner moves it again.
                Remove-Item (Join-Path $mainQueue "worker-$worker.json") -ErrorAction SilentlyContinue
                throw
            }
            $script:setups[$worker] = @{ at = Get-Now; job = Start-Job -ScriptBlock $installWorker `
                -ArgumentList (Join-Path $PSScriptRoot '../tasks.ps1'), $Main, $config.name, $slug, $worker }
            # The owner's tick: its copy of the old project goes, now that the worker has left it.
            return "worker $worker comes from $from, $status$(if ($request.deleteCopy -eq $true) { Remove-Copy $old.main $worker })"
        }
        'keep' {
            # The share of a whole week that a human use's usage guard holds (docs/QUEUE.md, Settings, `keep`).
            $use = [string]$request.use
            $value = [math]::Round([double]$request.value, 2)
            if (-not $DefaultKeep.ContainsKey($use) -or $value -lt 0 -or $value -gt 0.5) {
                throw 'a guard keeps a share between 0 % and 50 % of the week'
            }
            $settings = Read-SettingsToEdit
            if (-not $settings.keep) {
                $settings | Add-Member -NotePropertyName keep -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $settings.keep | Add-Member -NotePropertyName $use -NotePropertyValue $value -Force
            Save-Settings $settings
            return "keep: $use $value"
        }
        'compact-at' {
            # The compact size of a complexity's runs on this PC (docs/QUEUE.md, Settings,
            # `complexities.<name>.compactAt`).
            $name = [string]$request.complexity
            if (@(Get-Complexities (Read-Models) $config | ForEach-Object { $_.name }) -cnotcontains $name) {
                throw "no complexity $name"
            }
            $at = ConvertTo-CompactAt $request.value 'compactAt'
            $settings = Read-SettingsToEdit
            Get-ComplexitySettings $settings $name | Add-Member -NotePropertyName compactAt -NotePropertyValue $at -Force
            Save-Settings $settings
            return "compact at: $name $at"
        }
        'model' {
            # The model and effort of a complexity's runs on this PC (state.ps1, Set-ComplexityModel).
            $settings = Read-SettingsToEdit
            $list = Read-Models
            Save-Settings (Set-ComplexityModel $settings $list (Get-Complexities $list $config $settings) ([string]$request.complexity) ([string]$request.model) ([string]$request.effort))
            return "model: $($request.complexity) $($request.model)@$($request.effort)"
        }
        'advisor' {
            # Whether a complexity's runs get the advisor, and their effort without it (state.ps1,
            # Set-ComplexityAdvisor).
            $settings = Read-SettingsToEdit
            $list = Read-Models
            $complexities = Get-Complexities $list $config $settings
            $name = [string]$request.complexity
            Save-Settings (Set-ComplexityAdvisor $settings $list $complexities $name ([bool]$request.on) ([string]$request.fallback))
            return "advisor: $($request.complexity) $(if ($request.on) { 'on' } else { 'off' }) $($request.fallback)"
        }
        'advisor-model' {
            # The advisor's model for this project (state.ps1, Set-AdvisorModel).
            Save-Settings (Set-AdvisorModel (Read-SettingsToEdit) (Read-Models) ([string]$request.model))
            return "advisor model: $($request.model)"
        }
        'away' {
            # The owner is away (docs/QUEUE.md, No blocking): the PC's switch, so it counts for every project. Left out when off.
            $settings = Read-SettingsToEdit
            $settings.PSObject.Properties.Remove('away')
            if ($request.on) {
                Set-JsonProperty $settings 'away' $true
            }
            Save-Settings $settings
            # The merger hands back what waits on the owner at its next pass: now.
            Send-Wake (Join-Path $mainQueue 'wake-merger')
            return "away: $(if ($request.on) { 'on' } else { 'off' })"
        }
        'color' {
            # The project's colour on the page (state.ps1, Set-ProjectColor).
            Save-Settings (Set-ProjectColor (Read-SettingsToEdit) ([string]$request.value))
            return "color: $($request.value)"
        }
        'login' {
            # An account new to the register gets its own login folder (state.ps1, Get-NewAccountDir).
            $name = [string]$request.account
            $email = [string]$request.email
            if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
                throw 'the name takes lower-case letters, digits and dashes'
            }
            if ($email -and $email -notmatch '^[^\s"&|<>^%]+@[^\s"&|<>^%]+$') {
                throw 'not an email address'
            }
            $settings = Read-SettingsToEdit
            $entry = $settings.accounts.$name
            # Add an account: a name in use would sign that account in again, maybe as someone else.
            if ($request.new -and $entry) {
                throw "an account named $name exists: pick another name, or remove that account first"
            }
            # The coding tool that signs in: the account's own; for a new account the one the page names
            # (`provider`, a plugin's name), else the project's default.
            if ($entry) {
                $entry = Select-Account $settings $name
            } elseif ($request.provider) {
                $tool = Get-AccountProvider ([pscustomobject]@{ provider = [string]$request.provider }) (Get-KnownProviders)
                if (-not $tool) {
                    throw "no coding tool $($request.provider) here"
                }
                Select-Provider $tool
            }
            $signsIn = Test-ProviderHook 'SignIn'
            if ($entry -and -not $signsIn) {
                throw 'the provider has no sign-in from the page: sign the account in from a terminal'
            }
            if (-not $entry) {
                $entry = [pscustomobject]@{ configDir = (Get-NewAccountDir $settings $name $HOME); uses = [object[]]@()
                    provider = [string]$script:Provider.Name }
                $settings.accounts | Add-Member -NotePropertyName $name -NotePropertyValue $entry
                Save-Settings $settings
            }
            # A new account of a coding tool with no sign-in from the page: it is in the register, for a worker to
            # go on, and the owner signs the tool in from a terminal.
            if (-not $signsIn) {
                return "added: $name (its coding tool has no sign-in from the page)"
            }
            if ($entry.configDir) {
                New-Item -ItemType Directory -Force $entry.configDir | Out-Null
            }
            Start-Login $name $entry.configDir $email
            return "signing in: $name"
        }
        'login-code' {
            $code = ([string]$request.code).Trim()
            if (-not $script:login -or $script:login.process.HasExited) {
                throw 'no sign-in waits for a code'
            }
            if ($code -notmatch '^\S{1,2000}$') {
                throw 'paste the code from the sign-in page'
            }
            $script:login.process.StandardInput.WriteLine($code)
            $script:login.process.StandardInput.Flush()
            return 'code sent'
        }
        'login-cancel' {
            Stop-Login
            return 'sign-in cancelled'
        }
        'ping' {
            # The provider's cheapest request (docs/PLUGINS.md, Probe): it starts the account's windows.
            $name = [string]$request.account
            $entry = Select-Account (Read-SettingsToEdit) $name
            if (-not (Test-ProviderHook 'Probe')) {
                throw 'the provider has no ping'
            }
            # The temp folder holds no project for the tool to read.
            $reply = Invoke-Provider 'Probe' @{ Login = [string]$entry.configDir; Dir = [IO.Path]::GetTempPath() }
            if (-not $reply -or -not $reply.Answered -or $reply.Kind) {
                throw "the ping failed: $(if ($reply -and $reply.Text) { $reply.Text } else { 'is the account signed in?' })"
            }
            return "pinged: $name"
        }
        'remove-account' {
            # Only an account nothing runs on; its login is signed out, its folder kept (the queue's history names it).
            $name = [string]$request.account
            $settings = Read-SettingsToEdit
            $entry = Select-Account $settings $name
            if (@($entry.uses | Where-Object { $_ }).Count) {
                throw "move $(@($entry.uses) -join ', ') to another account first"
            }
            if ($script:login -and $script:login.account -eq $name) {
                Stop-Login
            }
            if ($entry.configDir) {
                try {
                    Invoke-Provider 'SignOut' @{ Login = [string]$entry.configDir } | Out-Null
                } catch {
                    Write-AppLog "sign-out of ${name}: $_"
                }
            }
            $settings.accounts.PSObject.Properties.Remove($name)
            Save-Settings $settings
            return "removed: $name"
        }
        'answer' {
            # The owner's word on a question: an answer in text, or no text to take the default. The script decides
            # what the queue does with it (Get-AnswerRoute); the answer goes on GitHub as the owner's comment, which
            # the worker reads with the ticket and which overrides its defaults (PLAYBOOK.md, Comments).
            $item = $script:snapshot.questions | Where-Object { $_.key -eq [string]$request.key } | Select-Object -First 1
            if (-not $item) {
                throw 'it no longer waits on you'
            }
            $text = ([string]$request.text).Trim()
            $route = Get-AnswerRoute $item $text
            $n = "$([int]$item.number)"
            $repo = [string]$item.repo
            $calls = @()
            switch ($route) {
                'answered' {
                    $calls += , (New-CommentCall 'pr' $item.number $repo $text)
                    $calls += , @('pr', 'edit', $n, '--remove-label', 'needs-owner', '--add-label', 'answered', '-R', $repo)
                }
                'merge' { $calls += , @('pr', 'edit', $n, '--remove-label', 'needs-owner', '-R', $repo) }
                'back' {
                    $calls += , (New-CommentCall 'ticket' $item.number $repo $(if ($text) { $text } else { 'The owner takes your default.' }))
                    $calls += , @('issue', 'edit', $n, '--remove-label', 'needs-owner', '-R', $repo)
                }
                'change' {
                    $calls += , (New-CommentCall 'ticket' $item.number $repo $text)
                    $calls += , @('issue', 'edit', $n, '--remove-label', 'open-question', '--add-label', 'P1', '-R', $repo)
                }
                'keep' {
                    $calls += , (New-CommentCall 'ticket' $item.number $repo 'The owner keeps the default.')
                    $calls += , @('issue', 'edit', $n, '--remove-label', 'open-question', '-R', $repo)
                    $calls += , @('issue', 'close', $n, '--reason', 'completed', '-R', $repo)
                }
                'queue' {
                    if ($text) {
                        $calls += , (New-CommentCall 'ticket' $item.number $repo $text)
                    }
                    $calls += , @('issue', 'edit', $n, '--remove-label', 'follow-up', '--add-label', 'P1', '-R', $repo)
                }
                'drop' {
                    $calls += , (New-CommentCall 'ticket' $item.number $repo $(if ($text) { "Dropped by the owner: $text" } else { 'Dropped: the owner takes the default.' }))
                    $calls += , @('issue', 'edit', $n, '--remove-label', 'follow-up', '-R', $repo)
                    $calls += , @('issue', 'close', $n, '--reason', 'not planned', '-R', $repo)
                }
            }
            return @{ message = "question $($item.key): $route"; calls = $calls }
        }
        'retry' {
            # A stuck ticket or PR goes back to its worker.
            $item = $script:snapshot.stuck | Where-Object { $_.key -eq [string]$request.key } | Select-Object -First 1
            if (-not $item) {
                throw 'it is no longer stuck'
            }
            $verb = if ($item.kind -eq 'pr') { 'pr' } else { 'issue' }
            return @{ message = "retry $($item.key)"; calls = @(, @($verb, 'edit', "$([int]$item.number)", '--remove-label', 'needs-owner', '-R', [string]$item.repo)) }
        }
        'stop-at' {
            # The account's stop line for one window (docs/QUEUE.md, Settings, `stopAt`): the share where its workers stop,
            # or in a window of some models where no run gets one of them as its advisor (limits.ps1, Get-ModelLines).
            $name = [string]$request.account
            $window = [string]$request.window
            $value = [math]::Round([double]$request.value, 2)
            # The windows are the ones of the account's coding tool.
            $settings = Read-SettingsToEdit
            $entry = Select-Account $settings $name
            if (-not $DefaultStopAt.ContainsKey($window) -or $value -lt 0.1 -or $value -gt 1) {
                throw 'the stop line is a share between 10 % and 100 % of a window'
            }
            if (-not $entry.stopAt) {
                $entry | Add-Member -NotePropertyName stopAt -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry.stopAt | Add-Member -NotePropertyName $window -NotePropertyValue $value -Force
            Save-Settings $settings
            return "stop line: $name $window $value"
        }
        'pick-up' {
            # The account's pick-up limit of one ticket size in a window that has them (docs/QUEUE.md, Settings,
            # `pickUp`): from this share its workers take no new ticket of that size. In a window of some models, the
            # line from which no run starts on them.
            $name = [string]$request.account
            $window = [string]$request.window
            $size = [string]$request.size
            $value = [math]::Round([double]$request.value, 2)
            $settings = Read-SettingsToEdit
            $entry = Select-Account $settings $name
            if (-not $DefaultPickUp.ContainsKey($window) -or @($DefaultPickUp[$window].Keys) -cnotcontains $size -or $value -lt 0 -or $value -gt 1) {
                throw 'a pick-up limit is a share between 0 % and 100 %, of a window that has that limit'
            }
            if (-not $entry.pickUp) {
                $entry | Add-Member -NotePropertyName pickUp -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            if (-not $entry.pickUp.$window) {
                $entry.pickUp | Add-Member -NotePropertyName $window -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry.pickUp.$window | Add-Member -NotePropertyName $size -NotePropertyValue $value -Force
            Save-Settings $settings
            return "pick-up limit: $name $window $size $value"
        }
        'priority' {
            $issue = $script:gh.issues | Where-Object { $_.number -eq [int]$request.number } | Select-Object -First 1
            if (-not $issue -or @('P0', 'P1', 'P2', 'park') -notcontains $request.priority) {
                throw 'unknown ticket or priority'
            }
            $editArgs = @('issue', 'edit', "$($issue.number)", '-R', $slug)
            foreach ($label in Get-Names $issue | Where-Object { $_ -match '^P[0-2]$' }) {
                $editArgs += @('--remove-label', $label)
            }
            if ($request.priority -ne 'park') {
                $editArgs += @('--add-label', $request.priority)
            }
            return @{ message = "priority: $($request.priority)"; calls = @(, $editArgs) }
        }
        'drop' {
            # A parked ticket closes as not planned; a reopen on GitHub parks it again. A stale page never closes a
            # ticket that was queued or claimed since.
            $item = $script:snapshot.parked | Where-Object { $_.number -eq [int]$request.number } | Select-Object -First 1
            if (-not $item) {
                throw 'it is no longer parked'
            }
            $n = "$([int]$item.number)"
            return @{ message = "drop: #$n"; calls = @(
                (New-CommentCall 'ticket' $item.number $slug 'Dropped by the owner.'),
                @('issue', 'close', $n, '--reason', 'not planned', '-R', $slug)
            ) }
        }
        default {
            throw "unknown action $($request.action)"
        }
    }
}

$types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.webmanifest' = 'application/manifest+json'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
}

# A question's picture (PLAYBOOK-pictures.md) from its branch shots-t<N> (shots.ps1): the repo is
# private, so the page cannot load it from GitHub itself. Fetched once with the owner's gh login, then kept in
# .queue/shots. shortcut: a run that replaces a picture under the same name shows the old one here; key the cache by the
# branch's commit if runs start to do that. The fetch runs in the request, so a first view waits for GitHub (15 s at most).
function Get-Shot([string] $branch, [string] $name) {
    $file = Join-Path $mainQueue "shots/$branch/$name"
    if (-not (Test-Path $file)) {
        if (-not $script:ghToken) {
            $script:ghToken = [string](& gh auth token)
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -OutFile "$file.part" -Uri "https://api.github.com/repos/$slug/contents/${name}?ref=$branch" -Headers @{
            Authorization = "Bearer $script:ghToken"; Accept = 'application/vnd.github.raw'; 'User-Agent' = 'scriptorium'
        }
        Move-Item -Force "$file.part" $file
    }
    return [System.IO.File]::ReadAllBytes($file)
}

function Send-Response($context, [int] $status, [string] $type, [byte[]] $bytes) {
    $response = $context.Response
    $response.StatusCode = $status
    $response.ContentType = $type
    $response.Headers['Cache-Control'] = 'no-store'
    # The page of another project of this PC may read and act here, and no other address's page (state.ps1,
    # Get-PageOrigin): the one app shows every project.
    $origin = Get-PageOrigin $script:projects ([string]$context.Request.Headers['Origin'])
    if ($origin) {
        $response.Headers['Access-Control-Allow-Origin'] = $origin
        $response.Headers['Access-Control-Allow-Headers'] = 'Content-Type, X-Queue'
        $response.Headers['Access-Control-Max-Age'] = '600'
        $response.Headers['Vary'] = 'Origin'
    }
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.Close()
}

function Send-Json($context, [int] $status, [string] $json) {
    Send-Response $context $status 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-Request($context) {
    $request = $context.Request
    $path = $request.Url.AbsolutePath
    if ($request.HttpMethod -eq 'OPTIONS') {
        # A browser asks this before another address's page acts here. Send-Response gives the yes to a page of
        # this PC's projects; without it the browser sends nothing more.
        Send-Response $context 204 'text/plain' ([byte[]]@())
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/state') {
        Send-Json $context 200 $script:json
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/shot') {
        # Only a shots branch and a picture's name: nothing else in the repo comes out through here.
        $branch = [string]$request.QueryString['branch']
        $name = [string]$request.QueryString['name']
        if ($branch -match '^shots-t\d+$' -and $name -match '^[\w.-]+\.(png|jpe?g)$') {
            try {
                Send-Response $context 200 $types[[System.IO.Path]::GetExtension($name).ToLower()] (Get-Shot $branch $name)
                return
            } catch {
                Write-AppLog "picture $branch/$name failed: $_"
            }
        }
        Send-Json $context 404 '{"error":"not found"}'
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/log') {
        # A worker's latest run, step by step.
        $id = [string]$request.QueryString['worker']
        $state = Read-Json (Join-Path $mainQueue "worker-$id.json")
        $log = if ($state -and $state.log) { $state.log } elseif ($state) {
            (Get-ChildItem (Join-Path (Get-Clone $id $state) '.queue/logs/*.jsonl') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1).FullName
        }
        # The provider of the worker's coding tool reads its log.
        $steps = @(Use-Provider (Get-WorkerProvider $script:saved $id (Get-KnownProviders)) { Get-Steps $log 40 })
        Send-Json $context 200 (@{ log = $log; steps = $steps } | ConvertTo-Json -Depth 4 -Compress)
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/copy') {
        # A worker's copy of this project, for the dialogs that can delete it (docs/APP.md, Add and remove): the
        # folder's name, '' when the worker has none here, and what it holds that GitHub does not have.
        $id = [string]$request.QueryString['worker']
        $copy = "$Main-w$id"
        $has = $id -match '^\d+$' -and (Test-Path -LiteralPath $copy -PathType Container)
        Send-Json $context 200 (@{ name = $(if ($has) { Split-Path $copy -Leaf } else { '' }); work = @(if ($has) { Get-CopyWork $copy }) } | ConvertTo-Json -Compress)
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/action') {
        # The custom header makes a browser ask first for another site's request, so no other page can act here.
        if ($request.Headers['X-Queue'] -ne '1') {
            Send-Json $context 403 '{"error":"forbidden"}'
            return
        }
        $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd() | ConvertFrom-Json
        try {
            # Under the PC's lock from an action's read of the settings to its save: the page's server of another
            # project saves the PC's part too.
            $lock = Enter-PcLock 'Settings'
            $script:note = ''
            try {
                $message = Invoke-Action $body
            } finally {
                Exit-PcLock $lock
            }
            if ($message -is [hashtable]) {
                # The main loop answers when the job ends.
                $job = Start-Job -ScriptBlock $ghWrite -ArgumentList $Main, (ConvertTo-Json -InputObject $message.calls -Compress)
                $script:writes += @{ job = $job; context = $context; message = $message.message }
                return
            }
            Write-AppLog "action: $message"
            $script:nextGh = 0
            $script:nextLocal = 0
            Send-Json $context 200 (@{ ok = $true; message = $message; note = $script:note } | ConvertTo-Json -Compress)
        } catch {
            Write-AppLog "action failed: $_"
            Send-Json $context 400 (@{ ok = $false; message = "$_" } | ConvertTo-Json -Compress)
        }
        return
    }
    if ($request.HttpMethod -eq 'GET') {
        $name = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $file = Join-Path $web $name
        if ($name -match '^[\w.-]+$' -and (Test-Path $file -PathType Leaf)) {
            $type = $types[[System.IO.Path]::GetExtension($name)]
            if (-not $type) {
                $type = 'application/octet-stream'
            }
            Send-Response $context 200 $type ([System.IO.File]::ReadAllBytes($file))
            return
        }
    }
    Send-Json $context 404 '{"error":"not found"}'
}

# A copy's delete that the server's end cut (a restart, a shutdown) goes on: only the folders beside the main checkout
# that have the name the rename gives.
Get-ChildItem -LiteralPath (Split-Path $Main -Parent) -Directory | Where-Object { Test-CopyToDelete $Main $_.Name } |
    ForEach-Object { Start-CopyDelete $_.FullName }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-AppLog "serving $appUrl (localhost:$Port)"
$pending = $listener.GetContextAsync()
$ghJob = $null
$script:nextGh = 0
$script:nextLocal = 0
$script:nextProjects = (Get-Now) + 300

# Restarts the server on new code (restart.ps1). Not while a sign-in waits for the owner, a GitHub write, a worker's
# setup or a copy's delete runs: the restart would end it.
function Restart-OnChange {
    if (-not ($script:login -and -not $script:login.process.HasExited) -and $script:writes.Count -eq 0 -and $script:setups.Count -eq 0 -and $script:deletes.Count -eq 0 -and (Test-CodeChanged)) {
        Write-AppLog 'script changed: restarting on the new code'
        $listener.Stop()
        Restart-OnNewCode (Get-TaskName $config.name 'app')
    }
}

while ($true) {
    try {
        if ($pending.Wait(500)) {
            $context = $pending.Result
            $pending = $listener.GetContextAsync()
            try {
                Invoke-Request $context
            } catch {
                Write-AppLog "request failed: $_"
                try {
                    Send-Json $context 500 '{"error":"server"}'
                } catch {
                }
            }
        }
        foreach ($write in @($script:writes | Where-Object { $_.job.State -ne 'Running' })) {
            $script:writes = @($script:writes | Where-Object { $_ -ne $write })
            $failed = $write.job.State -ne 'Completed'
            $reason = $write.job.ChildJobs[0].JobStateInfo.Reason.Message
            Remove-Job $write.job -Force
            Write-AppLog $(if ($failed) { "action failed: $($write.message): $reason" } else { "action: $($write.message)" })
            # The owner's answer, merge or queued ticket: the merger and the idle workers look now (docs/QUEUE.md, Wakes).
            Send-Wake (Join-Path $mainQueue 'wake-merger')
            Send-Wake (Join-Path $mainQueue 'wake-workers')
            $script:nextGh = 0
            $script:nextLocal = 0
            try {
                Send-Json $write.context $(if ($failed) { 400 } else { 200 }) (@{ ok = -not $failed; message = $(if ($failed) { $reason } else { $write.message }) } | ConvertTo-Json -Compress)
            } catch {
                # The page gave up waiting; the write still happened, and the next snapshot shows it.
            }
        }
        # A copy's delete that ended. Its worker has no card any more, so a failure goes to the log and to a push.
        foreach ($delete in @($script:deletes | Where-Object { $_.job.State -ne 'Running' })) {
            $script:deletes = @($script:deletes | Where-Object { $_ -ne $delete })
            $reason = if ($delete.job.State -ne 'Completed') { "$($delete.job.ChildJobs[0].JobStateInfo.Reason.Message)" }
            Remove-Job $delete.job -Force
            if ($delete.job.State -eq 'Completed') {
                Write-AppLog "deleted $($delete.folder)"
            } else {
                Write-AppLog "delete of $($delete.folder) failed: $reason"
                # No name of a project or a folder in the push: ntfy's server is public.
                Send-Notification @{ title = 'A copy is not deleted'; priority = 3; tags = 'warning'; click = 'workers'
                    message = 'The delete of a worker''s copy did not finish. Its folder has ".deleting" in its name: delete it by hand.' } (Read-ProjectSettings $Main)
            }
        }
        $now = Get-Now
        if ($now -ge $script:nextProjects) {
            Update-Projects
            $script:nextProjects = $now + 300
        }
        if (-not $ghJob -and $now -ge $script:nextGh) {
            $ghJob = Start-Job -ScriptBlock $fetch -ArgumentList $Main, $slug
            $script:nextGh = $now + 60
        }
        if ($ghJob -and $ghJob.State -ne 'Running') {
            if ($ghJob.State -eq 'Completed') {
                $read = (Receive-Job $ghJob) | ConvertFrom-Json
                # A ticket that the front desk filed, or an area that a held PR freed: no script saw it happen.
                if (Test-NewWork $script:gh $read) {
                    Send-Wake (Join-Path $mainQueue 'wake-workers')
                }
                $script:gh = $read
            } else {
                Write-AppLog "GitHub fetch $($ghJob.State): $($ghJob.ChildJobs[0].JobStateInfo.Reason)"
            }
            Remove-Job $ghJob -Force
            $ghJob = $null
            $script:nextLocal = 0
        }
        if ($now -ge $script:nextLocal) {
            # A worker's setup: its card says "Setting up" while the job runs (its state kept fresh, so it never reads
            # as a silent script), and the reason after a failure. A failed worker is disabled; the owner removes it.
            foreach ($id in @($script:setups.Keys)) {
                $job = $script:setups[$id].job
                $late = $job.State -eq 'Running' -and $now - $script:setups[$id].at -gt $SetupSeconds
                if ($late) {
                    Stop-Job $job
                }
                if ($job.State -eq 'Running') {
                    Write-Setup $id 'setup' ''
                    continue
                }
                $script:setups.Remove($id)
                $reason = if ($late) { "it took more than $($SetupSeconds / 60) minutes" } elseif ($job.State -ne 'Completed') {
                    [string]$job.ChildJobs[0].JobStateInfo.Reason.Message
                }
                if ($job.State -ne 'Completed' -and -not $reason) {
                    $reason = "its job ended $($job.State)"
                }
                Remove-Job $job -Force
                if ($reason) {
                    Write-Setup $id 'setup-failed' $reason
                    Set-Enabled $id $false
                    Write-AppLog "worker $id setup failed: $reason"
                } else {
                    Write-AppLog "worker $id set up"
                }
            }
            Update-Snapshot
            $script:nextLocal = $now + 5
            Restart-OnChange
        }
    } catch {
        Write-AppLog "error: $_"
        # After an error too: old code that fails on what a pull took away (a file it reads) never gets to the check
        # above. A check that fails itself (a file gone halfway through a pull) waits for the next round.
        try {
            Restart-OnChange
        } catch {
        }
        Start-Sleep 5
    }
}
