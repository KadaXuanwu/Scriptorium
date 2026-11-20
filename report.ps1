# The runs' numbers (docs/QUEUE.md, History), printed:
#   powershell -NoProfile -File report.ps1 -Project <main checkout> [-Last <n>]
#   powershell -NoProfile -File report.ps1 -Logs <a worker's .queue\logs> [-Last <n>]
# Without -Logs: for each complexity and model, the medians of the whole-ticket runs in .queue/history.jsonl that have
# the numbers (usage.ps1), the last n of them with -Last. With -Logs: the tools that the runs of those logs (the last n
# with -Last) were given and how often they called each, so the block list ($UnusedTools in worker.ps1) stays right
# after a Claude Code update.
param(
    [string] $Project,
    [int] $Last = 0,
    [string] $Logs
)
$ErrorActionPreference = 'Stop'

# The lower middle value, as the page's typical ones (app/state.ps1, Get-Typical).
function Get-Median($values) {
    $sorted = @($values | Sort-Object)
    return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

if ($Logs) {
    $files = @(Get-ChildItem $Logs -File | Where-Object { $_.Extension -eq '.jsonl' } | Sort-Object Name)
    if ($Last -gt 0) {
        $files = @($files | Select-Object -Last $Last)
    }
    $given = @{}
    $called = @{}
    foreach ($file in $files) {
        $tools = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            if ($line.StartsWith('{"type":"system","subtype":"init"')) {
                foreach ($name in [regex]::Match($line, '"tools":\[([^\]]*)\]').Groups[1].Value -split ',') {
                    $tools[$name.Trim('"')] = $true
                }
            } elseif ($line.StartsWith('{"type":"assistant"')) {
                foreach ($match in [regex]::Matches($line, '"type":"(?:server_)?tool_use","id":"[^"]*","name":"([^"]+)"')) {
                    $called[$match.Groups[1].Value] += 1
                }
            }
        }
        foreach ($name in $tools.Keys | Where-Object { $_ }) {
            $given[$name] += 1
        }
    }
    Write-Output "$($files.Count) logs in $Logs"
    @($given.Keys) + @($called.Keys) | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Tool = $_; Given = [int]$given[$_]; Calls = [int]$called[$_] }
    } | Sort-Object @{ Expression = 'Calls'; Descending = $true }, Tool | Format-Table -AutoSize | Out-String -Width 200
    return
}

if (-not $Project) {
    throw 'report.ps1 takes -Project <main checkout> or -Logs <folder>'
}
$file = Join-Path $Project '.queue\history.jsonl'
$runs = @(Get-Content $file -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
    Where-Object { $_.partial -eq $false -and $null -ne $_.requests })
if ($Last -gt 0) {
    $runs = @($runs | Select-Object -Last $Last)
}
Write-Output "$($runs.Count) whole-ticket runs with numbers in $file"
$runs | Group-Object complexity, model | Sort-Object Name | ForEach-Object {
    $group = $_.Group
    [pscustomobject]@{
        Complexity = $group[0].complexity
        Model = $group[0].model
        Runs = $group.Count
        Cost = [math]::Round((Get-Median ($group | ForEach-Object { [double]$_.cost })), 2)
        Requests = Get-Median ($group | ForEach-Object { [long]$_.requests })
        CallsPerRequest = [math]::Round((Get-Median ($group | Where-Object { $_.requests -gt 0 } |
            ForEach-Object { $_.toolCalls / $_.requests })), 2)
        CtxMean = Get-Median ($group | ForEach-Object { [long]$_.ctxMean })
        First = Get-Median ($group | ForEach-Object { [long]$_.first })
        AdvisorShare = '{0:P1}' -f (Get-Median ($group | Where-Object { $_.cost -gt 0 } |
            ForEach-Object { $_.advisorCost / $_.cost }))
    }
} | Format-Table -AutoSize | Out-String -Width 200
