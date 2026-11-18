# Checks plugins.ps1, the plugin seam: powershell -NoProfile -File plugins.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project.ps1')
. (Join-Path $PSScriptRoot 'plugins.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A plugin folder: its manifest and its hooks file.
function New-Plugin([string] $root, [string] $name, [string] $code, $api = 1) {
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir 'plugin.json') (@{ name = $name; title = "The $name plugin"; version = '1.0.0'; api = $api
        description = "Tests $name." } | ConvertTo-Json) -Encoding utf8
    Set-Content (Join-Path $dir 'plugin.ps1') $code -Encoding utf8
    return $dir
}

$root = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-plugins-test-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
try {
    # Two plugins with a helper of the same name: each hook calls its own.
    $one = New-Plugin $root 'one' @'
function Get-Word { 'one' }
@{
    Start = { param($ctx) & $ctx.Report "start $(Get-Word) in $($ctx.Copy)" }
    GetRun = { param($ctx) @{ McpServers = @{ Shared = @{ command = 'one' }; First = @{ command = 'a' } }; AllowedTools = @('mcp__First', 'Bash(dotnet:*)'); Prompt = "Word $(Get-Word)." } }
    EndRun = { param($ctx) throw 'the server did not stop' }
}
'@
    $two = New-Plugin $root 'two' @'
function Get-Word { 'two' }
@{
    GetRun = { param($ctx) @{ McpServers = @{ Shared = @{ command = 'two' } }; AllowedTools = @('Bash(dotnet:*)', 'mcp__Shared'); Prompt = "Word $(Get-Word) at $($ctx.Settings.level)." } }
}
'@
    $config = "{ `"name`": `"App`", `"allowedTools`": [`"Bash(npm:*)`"], `"plugins`": { `"one`": { `"source`": `"$($one.Replace('\', '/'))`" }, `"two`": { `"source`": `"$($two.Replace('\', '/'))`", `"level`": 1 } } }" | ConvertFrom-Json
    $plugins = Import-Plugins $root $config
    Assert-Equal (($plugins | ForEach-Object { $_.Name }) -join ',') 'one,two' 'the plugins in the order the file gives them'
    Assert-Equal "$($plugins[1].Title) $($plugins[1].Version) $($plugins[1].Settings.level) $($plugins[1].Settings.ContainsKey('source'))" 'The two plugin 1.0.0 1 False' 'the manifest and the settings, without source'
    Assert-Equal (Get-Command Get-Word -ErrorAction SilentlyContinue) '' 'no helper reaches the caller'

    # The machine's settings go over the file's; each hook gets its own plugin's.
    $machine = '{ "plugins": { "two": { "level": 2 } } }' | ConvertFrom-Json
    $said = New-Object System.Collections.ArrayList
    $report = { param($text) [void]$said.Add($text) }
    $answers = Invoke-Hooks $plugins 'GetRun' 'D:/p' 'D:/p-w1' 1 'D:/p-w1/.queue' $machine $report $report
    $run = Merge-RunAnswers $answers
    Assert-Equal "$($run.Prompt)" 'Word one. Word two at 2.' 'prompts in order, each with its own helper and settings'
    Assert-Equal (($run.McpServers.Keys | Sort-Object) -join ',') 'First,Shared' 'servers by name'
    Assert-Equal $run.McpServers.Shared.command 'two' 'a later plugin''s server of the same name wins'
    Assert-Equal (Get-RunTools $config $run) 'Bash(git:*),Bash(gh:*),Bash(npm:*),mcp__First,Bash(dotnet:*),mcp__Shared' 'tools as a union'
    Assert-Equal ((ConvertTo-McpConfig $run.McpServers) -match '^\{"mcpServers":\{.*"First":\{"command":"a"\}') $true 'the MCP config'

    # Report and Log reach the caller; a hook only one plugin has calls only that one.
    Invoke-Hooks $plugins 'Start' 'D:/p' 'D:/p-w1' 1 'D:/q' $null $report $report | Out-Null
    Assert-Equal ($said -join '|') 'start one in D:/p-w1' 'the report of a hook'
    Assert-Equal (Invoke-Hooks $plugins 'Setup' 'D:/p' 'D:/p' $null $null $null).Count 0 'no plugin has Setup'

    # A hook that throws names the plugin and the hook.
    $message = ''
    try { Invoke-Hooks $plugins 'EndRun' 'D:/p' 'D:/p-w1' 1 'D:/q' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal $message 'plugin one, EndRun: the server did not stop' 'a hook that throws'

    # A plugin for another contract version is refused with both numbers.
    $old = New-Plugin $root 'old' '@{}' 2
    $message = ''
    try { Import-Plugin $old 'old' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal $message 'plugin old: written for contract version 2, and Scriptorium has version 1' 'a wrong api'
    $message = ''
    try { Import-Plugin (Join-Path $root 'none') 'none' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal ($message -like 'plugin none: no plugin.json and plugin.ps1 in *') $true 'a plugin not installed'
    Assert-Equal (Get-PluginDir 'C:\S' 'unity' ('{ "source": "https://github.com/x/y" }' | ConvertFrom-Json)) 'C:\S\plugins\unity' 'a git source lives in the install'
    Assert-Equal (Get-PluginDir 'C:\S' 'unity' $null) 'C:\S\plugins\unity' 'a listed plugin lives in the install'
    Assert-Equal (Get-PluginDir 'C:\S' 'one' ('{ "source": "' + $one.Replace('\', '/') + '" }' | ConvertFrom-Json)) $one 'a folder source stays where it is'

    # A plugin loaded inside Start-Job works as in the script.
    $job = Start-Job -ArgumentList $PSScriptRoot, $one -ScriptBlock {
        param($base, $dir)
        . (Join-Path $base 'project.ps1')
        . (Join-Path $base 'plugins.ps1')
        $plugin = Import-Plugin $dir 'one' $null
        (Merge-RunAnswers (Invoke-Hooks @($plugin) 'GetRun' 'D:/p' 'D:/p' $null $null $null)).Prompt
    }
    $null = Wait-Job $job -Timeout 60
    Assert-Equal (Receive-Job $job) 'Word one.' 'a plugin inside Start-Job'
    Remove-Job $job -Force

    # No plugin: a plain git repo. The run gets an MCP config with no server, the base's tools and no prompt.
    $plain = '{ "name": "App", "plugins": {} }' | ConvertFrom-Json
    $none = Import-Plugins $root $plain
    Assert-Equal @($none).Count 0 'no plugin'
    Assert-Equal (Invoke-Hooks $none 'Start' 'D:/p' 'D:/p-w1' 1 'D:/q' $null).Count 0 'Start does nothing'
    $run = Merge-RunAnswers (Invoke-Hooks $none 'GetRun' 'D:/p' 'D:/p-w1' 1 'D:/q' $null)
    Assert-Equal (ConvertTo-McpConfig $run.McpServers) '{"mcpServers":{}}' 'an MCP config with no server'
    Assert-Equal (Get-RunTools $plain $run) 'Bash(git:*),Bash(gh:*)' 'the base''s tools only'
    Assert-Equal $run.Prompt '' 'no prompt'
    Assert-Equal (Import-Plugins $root ('{ "name": "App" }' | ConvertFrom-Json)).Count 0 'no plugins key'
} finally {
    Remove-Item $root -Recurse -Force
}

Write-Output 'ok'
