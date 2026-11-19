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
. (Join-Path $PSScriptRoot '..\restart.ps1')
. (Join-Path $PSScriptRoot '..\tasks.ps1')

$Main = Resolve-Project $Project
$config = Read-Project $Main
# The project's plugins, for the Details tab; the page runs on without them when one does not load.
$plugins = @()
try {
    $plugins = Import-Plugins (Split-Path $PSScriptRoot -Parent) $config
} catch {
    Add-Content (Join-Path $Main '.queue\app.log') "$(Get-Date -Format s) plugins: $_" -Encoding utf8
}
Start-CodeWatch (@((Join-Path $Main 'scriptorium.json')) + @($plugins | ForEach-Object { $_.Dir }))
if (-not $Port) {
    $Port = [int]$config.port
}

# One server per project: stopping the task ends only its console host, so an older loop may still run. End it.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and (Test-ProjectProcess $_.CommandLine 'server.ps1' $Main) } |
    ForEach-Object { & taskkill /T /F /PID $_.ProcessId | Out-Null }

$mainQueue = Join-Path $Main '.queue'
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

function Read-Runs {
    $file = Join-Path $mainQueue 'history.jsonl'
    if (-not (Test-Path $file)) {
        return @()
    }
    return @(Get-Content $file -Tail 300 -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}

# A login's state from its files, no process started: signed in (a refresh token), its plan and its email.
function Get-LoginInfo([string] $configDir) {
    $dir = if ($configDir) { $configDir } else { Join-Path $HOME '.claude' }
    $profileFile = if ($configDir) { Join-Path $configDir '.claude.json' } else { Join-Path $HOME '.claude.json' }
    $credentials = Read-Json (Join-Path $dir '.credentials.json')
    $info = @{ signedIn = [bool]($credentials -and $credentials.claudeAiOauth -and $credentials.claudeAiOauth.refreshToken) }
    if ($info.signedIn) {
        $info.plan = Get-PlanName $credentials
        # A regex, not ConvertFrom-Json: the file can hold keys differing only in case, which Windows PowerShell refuses.
        if (Test-Path $profileFile) {
            $match = [regex]::Match((Get-Content $profileFile -Raw -Encoding UTF8), '"emailAddress"\s*:\s*"([^"]+)"')
            if ($match.Success) {
                $info.email = $match.Groups[1].Value
            }
        }
    }
    return $info
}

# The sign-in started from the page (docs/APP.md, Accounts): one at a time, `claude auth login` for an account's
# config folder. The page shows its sign-in link and passes it the code; on a PC with a browser it may finish alone.
$script:login = $null
function Start-Login([string] $name, [string] $configDir, [string] $email) {
    Stop-Login
    $out = Join-Path $mainQueue 'login.txt'
    Remove-Item $out -ErrorAction SilentlyContinue
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $emailArg = if ($email) { " --email `"$email`"" } else { '' }
    $info.Arguments = "/c claude auth login$emailArg > `"$out`" 2>&1"
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    # No folder: the command-line login (~/.claude).
    if ($configDir) {
        $info.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $configDir
    } else {
        $info.EnvironmentVariables.Remove('CLAUDE_CONFIG_DIR')
    }
    $script:login = @{ account = $name; configDir = $configDir; out = $out; at = Get-Now; ended = $null
        process = [System.Diagnostics.Process]::Start($info) }
}

function Stop-Login {
    if ($script:login -and -not $script:login.process.HasExited) {
        & taskkill /T /F /PID $script:login.process.Id | Out-Null
    }
    $script:login = $null
}

# The sign-in as the page shows it: starting, waiting (its link), done or failed (the CLI's last line). A finished one
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
    $url = [regex]::Match($text, 'https://\S*oauth/authorize\S*').Value
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
            $last = @($text -split "`n" | ForEach-Object { ($_ -replace '^.*prompted >', '').Trim() } | Where-Object { $_ })
            $view.message = if ($last) { $last[-1] } else { 'The sign-in ended.' }
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

# Ends a worker's run now: the process started with its clone's MCP config, and its children. Work since the run's
# last checkpoint push is lost.
function Stop-Run([string] $worker, $state) {
    $mcp = (Join-Path (Get-Clone $worker $state) '.queue\mcp.json').ToLowerInvariant()
    $runs = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($mcp) })
    foreach ($run in $runs) {
        & taskkill /T /F /PID $run.ProcessId | Out-Null
    }
    return $runs.Count
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

$script:gh = $null
$script:snapshot = $null
$script:json = '{}'
function Update-Snapshot {
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
            progress = Read-Json (Join-Path $clone '.queue\progress.json')
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
    }
    if ($data.settings -and $data.settings.accounts) {
        foreach ($property in $data.settings.accounts.PSObject.Properties) {
            $key = if ($property.Value.configDir) { $property.Value.configDir } else { 'default' }
            $data.logins[$key] = Get-LoginInfo $property.Value.configDir
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

# The owner's actions (docs/APP.md). One that writes to GitHub returns its calls.
function Invoke-Action($request) {
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
        'assign' {
            if (-not (Test-Path (Join-Path $mainQueue "worker-$worker.json"))) {
                throw "no worker $worker"
            }
            Save-Settings (Set-WorkerAccount (Read-SettingsToEdit) $worker ([string]$request.account))
            return "worker $worker on $(if ($request.account) { $request.account } else { 'the command-line login' })"
        }
        'complexity' {
            # Whether a worker takes the tickets of a complexity (docs/QUEUE.md, Settings, `workers.<id>.complexity`).
            $worker = [string]$request.worker
            $name = [string]$request.complexity
            if ($worker -notmatch '^\d+$' -or @(Get-Complexities (Read-Models) $config | ForEach-Object { $_.name }) -cnotcontains $name) {
                throw "no worker $worker or no complexity $name"
            }
            $settings = Read-SettingsToEdit
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
                @(Get-ScheduledTask -TaskName (Get-WorkerTaskName '*' '*') -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName.Split(' ')[-1] })
            $id = Get-FreeWorkerId $taken
            $account = [string]$request.account
            Save-Settings (Set-WorkerEntry (Read-SettingsToEdit) $id $true $account)
            # What a removed worker of this number left must not hold the new one: a pause, a disable to come, a Force.
            Save-Control (Set-WorkerStatus (Read-Json (Join-Path $mainQueue 'control.json')) $id 'active' '' $false).control
            Remove-Item (Join-Path $mainQueue "force-$id.json") -ErrorAction SilentlyContinue
            Write-Setup $id 'setup' ''
            $script:setups[$id] = @{ at = Get-Now
                job = Start-Job -ScriptBlock $installWorker -ArgumentList (Join-Path $PSScriptRoot '..\tasks.ps1'), $Main, $config.name, $slug, $id }
            return "adding worker $id on $(if ($account) { $account } else { 'the command-line login' })"
        }
        'remove-worker' {
            # Only a disabled worker with no run in flight (Get-RemoveRefusal). Its task and loop end first, so nothing
            # writes its files again; then its files and entries go. Its clone stays: it may hold work no checkpoint
            # pushed, and a new worker of this number uses it again. Its `worker:N` claims pass to the other workers as
            # a disabled worker's do (worker.ps1, Get-NextJob).
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
            return "removed: worker $worker"
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
            $refusal = Get-MoveRefusal $state $fresh (Test-Path (Join-Path $copy '.queue\paused.json')) $marked
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
                -ArgumentList (Join-Path $PSScriptRoot '..\tasks.ps1'), $Main, $config.name, $slug, $worker }
            return "worker $worker comes from $from, $status"
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
        'color' {
            # The project's colour on the page (state.ps1, Set-ProjectColor).
            Save-Settings (Set-ProjectColor (Read-SettingsToEdit) ([string]$request.value))
            return "color: $($request.value)"
        }
        'login' {
            # An account new to the register gets its own config folder, ~/.claude-<name>.
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
            if (-not $entry) {
                $entry = [pscustomobject]@{ configDir = "$($HOME.Replace('\', '/'))/.claude-$name"; uses = [object[]]@() }
                $settings.accounts | Add-Member -NotePropertyName $name -NotePropertyValue $entry
                Save-Settings $settings
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
            # One Haiku reply with no tools, settings, plugins or CLAUDE.md (about 770 tokens): it starts the 5-hour window.
            $name = [string]$request.account
            $entry = (Read-SettingsToEdit).accounts.$name
            if (-not $entry) {
                throw "no account $name"
            }
            $previous = $env:CLAUDE_CONFIG_DIR
            if ($entry.configDir) {
                $env:CLAUDE_CONFIG_DIR = $entry.configDir
            } else {
                Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
            }
            # The temp folder has no CLAUDE.md for the CLI to find.
            Push-Location $env:TEMP
            try {
                & claude -p . --model haiku --tools= --system-prompt 'Reply with one dot.' --setting-sources=local `
                    --strict-mcp-config --disable-slash-commands --max-turns 1 | Out-Null
                if ($LASTEXITCODE) {
                    throw "the ping failed (exit $LASTEXITCODE): is the account signed in?"
                }
            } finally {
                Pop-Location
                $env:CLAUDE_CONFIG_DIR = $previous
            }
            return "pinged: $name"
        }
        'remove-account' {
            # Only an account nothing runs on; its login is signed out, its folder kept (the queue's history names it).
            $name = [string]$request.account
            $settings = Read-SettingsToEdit
            $entry = $settings.accounts.$name
            if (-not $entry) {
                throw "no account $name"
            }
            if (@($entry.uses | Where-Object { $_ }).Count) {
                throw "move $(@($entry.uses) -join ', ') to another account first"
            }
            if ($script:login -and $script:login.account -eq $name) {
                Stop-Login
            }
            if ($entry.configDir) {
                $previous = $env:CLAUDE_CONFIG_DIR
                $env:CLAUDE_CONFIG_DIR = $entry.configDir
                try {
                    & claude auth logout | Out-Null
                } finally {
                    $env:CLAUDE_CONFIG_DIR = $previous
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
            # or in the Fable week where they stop Fable (limits.ps1, Test-FableOut).
            $name = [string]$request.account
            $window = [string]$request.window
            $value = [math]::Round([double]$request.value, 2)
            if (@('five_hour', 'seven_day', $FableWindow) -notcontains $window -or $value -lt 0.1 -or $value -gt 1) {
                throw 'the stop line is a share between 10 % and 100 % of a window'
            }
            $settings = Read-SettingsToEdit
            $entry = $settings.accounts.$name
            if (-not $entry) {
                throw "no account $name"
            }
            if (-not $entry.stopAt) {
                $entry | Add-Member -NotePropertyName stopAt -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry.stopAt | Add-Member -NotePropertyName $window -NotePropertyValue $value -Force
            Save-Settings $settings
            return "stop line: $name $window $value"
        }
        'pick-up' {
            # The account's pick-up limit of one ticket size in the 5-hour window (docs/QUEUE.md, Settings, `pickUp`):
            # from this share its workers take no new ticket of that size. In the Fable week, its design line.
            $name = [string]$request.account
            $window = [string]$request.window
            $size = [string]$request.size
            $value = [math]::Round([double]$request.value, 2)
            if (-not $DefaultPickUp.ContainsKey($window) -or @($DefaultPickUp[$window].Keys) -cnotcontains $size -or $value -lt 0 -or $value -gt 1) {
                throw 'a pick-up limit is a share between 0 % and 100 %: of the 5-hour window for size S, M or L, of the Fable week for design'
            }
            $settings = Read-SettingsToEdit
            $entry = $settings.accounts.$name
            if (-not $entry) {
                throw "no account $name"
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
        default {
            throw "unknown action $($request.action)"
        }
    }
}

$types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.webmanifest' = 'application/manifest+json'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
}

# A question's picture (PLAYBOOK.md, Pictures) from its branch shots-t<N> (shots.ps1): the repo is
# private, so the page cannot load it from GitHub itself. Fetched once with the owner's gh login, then kept in
# .queue/shots. shortcut: a run that replaces a picture under the same name shows the old one here; key the cache by the
# branch's commit if runs start to do that. The fetch runs in the request, so a first view waits for GitHub (15 s at most).
function Get-Shot([string] $branch, [string] $name) {
    $file = Join-Path $mainQueue "shots\$branch\$name"
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
            (Get-ChildItem (Join-Path (Get-Clone $id $state) '.queue\logs\*.jsonl') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1).FullName
        }
        Send-Json $context 200 (@{ log = $log; steps = @(Get-Steps $log 40) } | ConvertTo-Json -Depth 4 -Compress)
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
            Send-Json $context 200 (@{ ok = $true; message = $message } | ConvertTo-Json -Compress)
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

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-AppLog "serving $appUrl (localhost:$Port)"
$pending = $listener.GetContextAsync()
$ghJob = $null
$script:nextGh = 0
$script:nextLocal = 0
$script:nextProjects = (Get-Now) + 300
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
            $script:nextGh = 0
            $script:nextLocal = 0
            try {
                Send-Json $write.context $(if ($failed) { 400 } else { 200 }) (@{ ok = -not $failed; message = $(if ($failed) { $reason } else { $write.message }) } | ConvertTo-Json -Compress)
            } catch {
                # The page gave up waiting; the write still happened, and the next snapshot shows it.
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
                $script:gh = (Receive-Job $ghJob) | ConvertFrom-Json
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
            $script:nextLocal = $now + 10
            # Not while a sign-in waits for the owner, a GitHub write or a worker's setup runs: the restart would
            # end it.
            if (-not ($script:login -and -not $script:login.process.HasExited) -and $script:writes.Count -eq 0 -and $script:setups.Count -eq 0 -and (Test-CodeChanged)) {
                Write-AppLog 'script changed: restarting on the new code'
                $listener.Stop()
                Restart-OnNewCode (Get-TaskName $config.name 'app')
            }
        }
    } catch {
        Write-AppLog "error: $_"
        Start-Sleep 5
    }
}
