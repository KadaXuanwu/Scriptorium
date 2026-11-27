# Checks the usage reading while a run works (worker.ps1, Update-Usage): powershell -NoProfile -File
# tests/usage.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'budget.ps1')
# worker.ps1 loops when run, so only its functions under test are loaded; what they call is a stand-in below.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $baseDir 'worker.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Get-Account', 'Get-ConfigDir', 'Get-FreshUsage', 'Update-Usage') {
    . ([scriptblock]::Create($ast.Find({ $args[0].Name -eq $name }, $true).Extent.Text))
}

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

$hooks = @{ Probe = $true; ReadUsage = $false }
$now = 1000000
$stored = @{}
$probes = 0
$probed = 0.5
$logReads = 0
$windows = @('w')
$WindowTitles = @{ w = 'W' }
$running = @{ ticket = 1 }
$forceFile = Join-Path ([IO.Path]::GetTempPath()) "usage-test-$PID.force"
$warnFile = Join-Path ([IO.Path]::GetTempPath()) "usage-test-$PID.warn"
function Test-ProviderHook([string] $hook) { return [bool]$hooks[$hook] }
function Get-Now { return $script:now }
function Read-AllUsage { return $script:stored }
function Get-LoginEmail { return 'a@b' }
function Read-Out { return @{} }
function Write-Log { }
function Format-Share($share) { return "$share" }
function Format-Time($time) { return "$time" }
function Read-Log { return '' }
function Get-Usage { $script:logReads++ }
function Invoke-Probe {
    $script:probes++
    if ($null -eq $script:probed) {
        return $null
    }
    return @{ usage = @{ at = $script:now; w = @{ used = $script:probed } }; answered = $true; kind = ''; text = '' }
}
function Save-Usage([string] $account, $usage) {
    $usage.email = 'a@b'
    $script:stored[$account] = $usage
}
function Get-Budget([string] $account, $usage) { return @{ w = @{ used = $usage.w.used; ceiling = 0.9; left = 60 } } }
function Save-Budget($budget) { $script:shown = $budget.w.used }

try {
    # The first look of a run probes, saves the reading for the account and shows it on the worker's card.
    Update-Usage 'log' 'default'
    Assert-Equal "$probes $($stored.default.w.used) $shown" '1 0.5 0.5' 'the first look probes'
    # The watch looks more often than a probe is due.
    $now += 30
    Update-Usage 'log' 'default'
    Assert-Equal $probes 1 'no probe before it is due'
    # A reading over the workers' limit leaves the run its note.
    $now += $RunProbeSeconds
    $probed = 0.95
    Update-Usage 'log' 'default'
    Assert-Equal "$probes $shown $(Test-Path $warnFile)" '2 0.95 True' 'the stop line ends such a run'
    # A newer reading of the page's Ping counts with no probe; under the limit, it withdraws the note.
    $now += $RunProbeSeconds
    $stored.default = @{ at = $now - 10; email = 'a@b'; w = @{ used = 0.2 } }
    Update-Usage 'log' 'default'
    Assert-Equal "$probes $shown $(Test-Path $warnFile)" '2 0.2 False' 'a Ping''s reading counts'
    # A probe that failed is not sent again at the next look, and the card keeps the last reading.
    $now += $RunProbeSeconds
    $probed = $null
    Update-Usage 'log' 'default'
    $now += 30
    Update-Usage 'log' 'default'
    Assert-Equal "$probes $shown" '3 0.2' 'a failed probe waits for the next one'
    # A provider that reads the run's log is read from the log, never with a probe.
    $hooks.ReadUsage = $true
    $now += $RunProbeSeconds
    Update-Usage 'log' 'default'
    Assert-Equal "$probes $logReads" '3 1' 'a log with usage needs no probe'
} finally {
    Remove-Item $warnFile, $forceFile -ErrorAction SilentlyContinue
}
'ok'
