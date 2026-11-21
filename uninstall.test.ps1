# Checks uninstall.ps1 on a project of its own in a temp folder, with a PC folder of its own, so this PC's settings stay
# as they are: powershell -NoProfile -File uninstall.test.ps1 (prints ok or throws). It needs git, not GitHub or
# Tailscale.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "uninstall-test-$PID"
# pc.ps1 keeps a folder that is set before it loads, here and in uninstall.ps1.
$PcDir = Join-Path $root 'pc'
. (Join-Path $PSScriptRoot 'tasks.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A project with worker 9 (a clean copy) and a copy -w8 that a removed worker left with a file not committed.
$main = Join-Path $root 'App'
New-Item -ItemType Directory -Force (Join-Path $main '.queue') | Out-Null
Set-Content (Join-Path $main 'scriptorium.json') "{ `"name`": `"UninstallTest$PID`", `"port`": 18999 }" -Encoding utf8
& git -C $main init -q
& git -C $main add scriptorium.json
& git -C $main -c user.name=test -c user.email=test@example.com commit -q -m init
& git clone -q $main "$main-w9"
& git clone -q $main "$main-w8"
Set-Content (Join-Path "$main-w8" 'draft.txt') 'not committed'
Set-Content (Join-Path $main '.queue/worker-9.json') '{}'
New-Item -ItemType Directory -Force $PcDir | Out-Null
Set-Content (Join-Path $PcDir 'settings.json') ('{ "accounts": { "main": { "uses": ["worker:9", "worker:1"] } }, ' +
    '"workers": { "9": { "enabled": true }, "1": { "enabled": true } } }') -Encoding utf8

try {
    $output = @(& (Join-Path $PSScriptRoot 'uninstall.ps1') -Project $main) -join "`n"
    Assert-Equal (Test-Path (Join-Path $main '.queue')) $false 'the queue folder goes'
    Assert-Equal (Test-Path "$main-w9") $false 'a clean copy goes'
    Assert-Equal (Test-Path (Join-Path "$main-w8" 'draft.txt')) $true 'a copy with work stays'
    Assert-Equal ($output -match 'Stays, it holds work .*App-w8') $true 'and uninstall names it'
    Assert-Equal @(Get-ChildItem $root -Directory -Filter '*.deleting-*').Count 0 'no half-deleted copy'
    Assert-Equal (Test-Path (Join-Path $main 'scriptorium.json')) $true 'the repo''s files stay without -Repo'
    $pc = Read-JsonFile (Join-Path $PcDir 'settings.json')
    Assert-Equal "$(@($pc.workers.PSObject.Properties | ForEach-Object { $_.Name }) -join ',')" '1' 'worker 9 leaves the register'
    Assert-Equal "$($pc.accounts.main.uses -join ',')" 'worker:1' 'and its account''s uses'

    # Safe to run again.
    & (Join-Path $PSScriptRoot 'uninstall.ps1') -Project $main | Out-Null
    Assert-Equal (Test-Path (Join-Path "$main-w8" 'draft.txt')) $true 'a second run keeps the copy with work'
} finally {
    Remove-Tree $root
}

Write-Output 'ok'
