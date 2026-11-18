# Sets up the work queue (docs/QUEUE.md): a clone per worker beside this checkout, Unity's YAML merge in every
# checkout, the GitHub labels, and logon tasks for the workers and the merger. Safe to run again.
param(
    # The project's main checkout.
    [Parameter(Mandatory = $true)] [string] $Project,
    [int] $Workers = 3,
    [string] $UnityEditors = 'C:\Program Files\Unity\Hub\Editor',
    [switch] $Start
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tasks.ps1')
$main = Resolve-Project $Project
$config = Read-Project $main
# The owner's other repos tickets may name with a `repo:<Name>` label (PLAYBOOK.md, Another repository).
$Repos = @($config.repos)
$url = (& git -C $main remote get-url origin)

$clones = @()
for ($i = 1; $i -le $Workers; $i++) {
    $clone = "$main-w$i"
    if (-not (Test-Path $clone)) {
        & git clone $url $clone
    }
    Copy-AssetStorePackages $main $clone
    $clones += $clone
}

foreach ($checkout in @($main) + $clones) {
    Set-YamlMerge $checkout $main $UnityEditors
}

$labels = [ordered]@{
    'P0' = @('b60205', 'Queued, urgent: before anything else')
    'P1' = @('d93f0b', 'Queued')
    'P2' = @('fbca04', 'Queued, when nothing else waits')
    'needs-owner' = @('5319e7', 'A worker waits on the owner; remove the label once answered')
    'needs-rebase' = @('e99695', 'PR conflicts with main; its worker rebases it')
    'answered' = @('1d76db', 'PR held for questions, now answered; its worker applies the answers')
    'follow-up' = @('0052cc', 'A worker''s leftover with questions; waits for the owner to queue, park or drop it')
    'open-question' = @('0e8a8a', 'A design question merged on its default; waits in Q&A for the owner to keep or change it')
    'size:S' = @('bfdadc', 'Small usage: little to read and change')
    'size:M' = @('bfdadc', 'Medium usage: a feature''s worth of reading, changing and testing')
    'size:L' = @('bfdadc', 'Large usage: many files, long play-checks; goes to an account with much 5-hour room')
    'complexity:low' = @('d4c5f9', 'Clear what to do: picks a cheaper model')
    'complexity:medium' = @('d4c5f9', 'Judgement within known patterns: the default model')
    'complexity:high' = @('d4c5f9', 'Hard to get right: core rules, cross-system design, tricky bugs: the strongest model')
    'complexity:design' = @('d4c5f9', 'Decides more than how to build it, and it stays (rules, final looks, lasting code): runs on Fable')
}
for ($i = 1; $i -le $Workers; $i++) {
    $labels["worker:$i"] = @('0e8a16', "Claimed by worker $i")
}
$prLabels = @('needs-owner', 'needs-rebase', 'answered') + @($labels.Keys | Where-Object { $_ -like 'worker:*' })
foreach ($other in $Repos) {
    $labels["repo:$other"] = @('006b75', "The work happens in the $other repo; its PR is opened there")
}
$slug = (& gh repo view $url --json nameWithOwner -q .nameWithOwner)
foreach ($name in $labels.Keys) {
    & gh label create $name --color $labels[$name][0] --description $labels[$name][1] --force -R $slug | Out-Null
}
# The labels a worker PR carries, in each other repo.
foreach ($other in $Repos) {
    foreach ($name in $prLabels) {
        & gh label create $name --color $labels[$name][0] --description $labels[$name][1] --force -R "$($slug.Split('/')[0])/$other" | Out-Null
    }
}

$tasks = @{
    (Get-TaskName $config.name 'merger') = "-File `"$PSScriptRoot\merge.ps1`" $(Get-ProjectArg $main)"
    (Get-TaskName $config.name 'app') = "-File `"$PSScriptRoot\app\server.ps1`" $(Get-ProjectArg $main)"
}
for ($i = 1; $i -le $Workers; $i++) {
    $tasks[(Get-WorkerTaskName $config.name $i)] = Get-WorkerArguments $main $i $clones[$i - 1] $UnityEditors
}
foreach ($name in $tasks.Keys) {
    Register-QueueTask $name $tasks[$name] $main
    if ($Start) {
        Start-ScheduledTask -TaskName $name
    }
}
Write-Output "Queue set up: $($clones -join ', '); tasks: $($tasks.Keys -join ', ')."

# The bots get no GitHub notifications from the queue's repos: their mail reaches the owner's inbox, and the queue
# app tells the owner what matters.
$queueSettings = if (Test-Path (Join-Path $main '.queue\settings.json')) { Get-Content (Join-Path $main '.queue\settings.json') -Raw | ConvertFrom-Json } else { $null }
$botDirs = @()
if ($queueSettings) {
    $botDirs += @($queueSettings.workers.PSObject.Properties | ForEach-Object { $_.Value.ghConfigDir })
    $botDirs += @($queueSettings.merger.ghConfigDir)
}
foreach ($dir in @($botDirs | Where-Object { $_ } | Sort-Object -Unique)) {
    foreach ($repoName in @($slug.Split('/')[1]) + $Repos) {
        $env:GH_CONFIG_DIR = $dir
        & gh api -X PUT "repos/$($slug.Split('/')[0])/$repoName/subscription" -F ignored=true -F subscribed=false | Out-Null
    }
}
Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue

# The queue app (docs/APP.md): a private ntfy topic in the settings, and the page on the owner's Tailscale devices.
$settingsFile = Join-Path $main '.queue\settings.json'
$json = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $json.ntfy -or -not $json.ntfy.topic) {
    $topic = "$($config.name.ToLowerInvariant())-" + (-join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }))
    $json | Add-Member -NotePropertyName ntfy -NotePropertyValue ([pscustomobject]@{ topic = $topic }) -Force
    $json | ConvertTo-Json -Depth 8 | Set-Content $settingsFile -Encoding utf8
}
Write-Output "ntfy topic (subscribe to it in the ntfy app): $($json.ntfy.topic)"
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
if ($tailscale) {
    & $tailscale.Source serve --bg $config.port
} else {
    Write-Output "Tailscale is not installed: the page is only at http://127.0.0.1:$($config.port) on this PC.\"
}
