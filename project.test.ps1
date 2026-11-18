# Checks project.ps1: powershell -NoProfile -File project.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A process is this project's only by its -Project argument with the closing quote: never another project, a path
# that starts with this one, or a queue from before -Project.
$line = 'powershell.exe -NoProfile -File "C:\S\worker.ps1" -Project "D:\Work\App" -Id 2 -Clone "D:\Work\App-w2"'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'D:\Work\App') $true 'this project''s worker'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'd:\work\app') $true 'the path in another case'
Assert-Equal (Test-ProjectProcess $line 'worker.ps1' 'D:\Work\Ap') $false 'a path that this one starts with'
Assert-Equal (Test-ProjectProcess $line 'merge.ps1' 'D:\Work\App') $false 'another script'
$longer = 'powershell.exe -File "C:\S\worker.ps1" -Project "D:\Work\App2" -Id 2'
Assert-Equal (Test-ProjectProcess $longer 'worker.ps1' 'D:\Work\App') $false 'a project whose path starts with this one'
$old = 'powershell.exe -File "D:\Work\App\Tools\Queue\worker.ps1" -Id 2 -Clone "D:\Work\App-w2"'
Assert-Equal (Test-ProjectProcess $old 'worker.ps1' 'D:\Work\App') $false 'a queue from before -Project'
Assert-Equal (Test-ProjectProcess $null 'worker.ps1' 'D:\Work\App') $false 'no command line'
Assert-Equal (Get-TaskName 'App' 'worker 3') 'Scriptorium App worker 3' 'a task name'

# The config: the defaults fill what the file leaves out; a bad name stops.
$dir = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-project-test-$PID"
New-Item -ItemType Directory -Force $dir | Out-Null
try {
    Set-Content (Join-Path $dir 'scriptorium.json') '{ "name": "My-App2" }' -Encoding utf8
    $config = Read-Project $dir
    Assert-Equal "$($config.name) $($config.port) $(@($config.repos).Count) $(@($config.allowedTools).Count)" 'My-App2 8770 0 0' 'defaults'
    Set-Content (Join-Path $dir 'scriptorium.json') '{ "name": "My App", "port": 9000 }' -Encoding utf8
    $threw = $false
    try { Read-Project $dir | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'a name with a space'
    Remove-Item (Join-Path $dir 'scriptorium.json')
    $threw = $false
    try { Read-Project $dir | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'no scriptorium.json'
} finally {
    Remove-Item $dir -Recurse -Force
}

Write-Output 'ok'
