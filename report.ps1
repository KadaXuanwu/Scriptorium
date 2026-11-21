# The runs' numbers (docs/QUEUE.md, History), printed:
#   powershell -NoProfile -File report.ps1 -Project <main checkout> [-Last <n>]
#   powershell -NoProfile -File report.ps1 -Logs <a worker's .queue\logs> [-Last <n>]
# Without -Logs: for each complexity and model, the medians of the whole-ticket runs in .queue/history.jsonl that have
# the numbers (usage.ps1), the last n of them with -Last; then the same for the parts of interrupted tickets, the
# resumed parts apart. With -Logs: the tools that the runs of those logs (the last n
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
$file = Join-Path $Project '.queue/history.jsonl'
$all = @(Get-Content $file -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
    Where-Object { $null -ne $_.requests })

# One row of medians for each group of the runs. $by: the fields that make a group, which are the first columns.
function Write-Medians($runs, [string[]] $by) {
    $runs | Group-Object $by | Sort-Object Name | ForEach-Object {
        $group = $_.Group
        $row = [ordered]@{}
        foreach ($name in $by) {
            $row[$name.Substring(0, 1).ToUpper() + $name.Substring(1)] = $group[0].$name
        }
        $row.Runs = $group.Count
        $row.Cost = [math]::Round((Get-Median ($group | ForEach-Object { [double]$_.cost })), 2)
        $row.Requests = Get-Median ($group | ForEach-Object { [long]$_.requests })
        $row.CallsPerRequest = [math]::Round((Get-Median ($group | Where-Object { $_.requests -gt 0 } |
            ForEach-Object { $_.toolCalls / $_.requests })), 2)
        $row.CtxMean = Get-Median ($group | ForEach-Object { [long]$_.ctxMean })
        $row.First = Get-Median ($group | ForEach-Object { [long]$_.first })
        $row.AdvisorShare = '{0:P1}' -f (Get-Median ($group | Where-Object { $_.cost -gt 0 } |
            ForEach-Object { $_.advisorCost / $_.cost }))
        [pscustomobject]$row
    } | Format-Table -AutoSize | Out-String -Width 200
}

$runs = @($all | Where-Object { $_.partial -eq $false })
if ($Last -gt 0) {
    $runs = @($runs | Select-Object -Last $Last)
}
Write-Output "$($runs.Count) whole-ticket runs with numbers in $file"
Write-Medians $runs 'complexity', 'model'

# The parts of an interrupted ticket. First of a resumed part: the tokens that the resume reads again at full price.
# A line from before the resumed field counts as not resumed.
$parts = @($all | Where-Object { $_.partial -and $_.kind -eq 'ticket' } | ForEach-Object {
    $_ | Add-Member -NotePropertyName resumed -NotePropertyValue ([bool]$_.resumed) -Force -PassThru
})
if ($Last -gt 0) {
    $parts = @($parts | Select-Object -Last $Last)
}
Write-Output "$($parts.Count) parts of interrupted tickets with numbers"
Write-Medians $parts 'resumed', 'model'
