# Checks plugins.ps1, the plugin seam: powershell -NoProfile -File tests/plugins.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'project.ps1')
. (Join-Path $baseDir 'plugins.ps1')

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
    GetRun = { param($ctx) @{ McpServers = @{ Shared = @{ command = 'one' }; First = @{ command = 'a' } }; Commands = @('dotnet', 'unity command'); AllowedTools = @('rule-a'); Prompt = "Word $(Get-Word)."; Env = @{ SHARED = 'one'; FIRST = 'a' } } }
    EndRun = { param($ctx) throw 'the server did not stop' }
    Close = { param($ctx) if ($ctx.Copy -eq 'D:/o-w1') { throw 'no editor' }; & $ctx.Log "one $($ctx.Copy)" }
}
'@
    $two = New-Plugin $root 'two' @'
function Get-Word { 'two' }
@{
    GetRun = { param($ctx) @{ McpServers = @{ Shared = @{ command = 'two' } }; Commands = @('dotnet'); AllowedTools = @('rule-a', 'rule-b'); Prompt = "Word $(Get-Word) at $($ctx.Settings.level)."; Env = @{ SHARED = 'two' } } }
    Close = { param($ctx) & $ctx.Log "two $($ctx.Copy)" }
}
'@
    $config = "{ `"name`": `"App`", `"commands`": [`"npm`"], `"allowedTools`": [`"rule-own`"], `"plugins`": { `"one`": { `"source`": `"$($one.Replace('\', '/'))`" }, `"two`": { `"source`": `"$($two.Replace('\', '/'))`", `"level`": 1 } } }" | ConvertFrom-Json
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
    Assert-Equal "$($run.Env.FIRST) $($run.Env.SHARED) $($run.Env.Count)" 'a two 2' 'environment variables by name, a later plugin''s wins'
    Assert-Equal ((Get-RunCommands $config $run) -join ',') 'git,gh,npm,dotnet,unity command' 'commands as a union: of the base, the project and the plugins'
    Assert-Equal ((Get-RunTools $config $run) -join ',') 'rule-own,rule-a,rule-b' 'the provider''s own tool rules as a union'

    # Report and Log reach the caller; a hook only one plugin has calls only that one.
    Invoke-Hooks $plugins 'Start' 'D:/p' 'D:/p-w1' 1 'D:/q' $null $report $report | Out-Null
    Assert-Equal ($said -join '|') 'start one in D:/p-w1' 'the report of a hook'
    Assert-Equal (Invoke-Hooks $plugins 'Setup' 'D:/p' 'D:/p' $null $null $null).Count 0 'no plugin has Setup'

    # A hook that throws names the plugin and the hook.
    $message = ''
    try { Invoke-Hooks $plugins 'EndRun' 'D:/p' 'D:/p-w1' 1 'D:/q' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal $message 'plugin one, EndRun: the server did not stop' 'a hook that throws'

    # Close: every plugin in every checkout; a hook that throws is logged, and the next plugin still closes.
    $said.Clear()
    Close-Checkouts $plugins @('D:/p-w1', 'D:/o-w1') 'D:/p' 1 'D:/q' $null $report
    Assert-Equal ($said -join '|') 'one D:/p-w1|two D:/p-w1|plugin one, Close: no editor|two D:/o-w1' 'the close of a disabled worker'

    # A plugin for another contract version is refused with both numbers.
    $old = New-Plugin $root 'old' '@{}' 2
    $message = ''
    try { Import-Plugin $old 'old' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal $message 'plugin old: written for contract version 2, and Scriptorium has version 1' 'a wrong api'
    $message = ''
    try { Import-Plugin (Join-Path $root 'none') 'none' $null | Out-Null } catch { $message = "$_" }
    Assert-Equal ($message -like 'plugin none: no plugin.json and plugin.ps1 in *') $true 'a plugin not installed'
    $plugins = Join-Path (Join-Path $root 'S') 'plugins'
    Assert-Equal (Get-PluginDir (Join-Path $root 'S') 'unity' ('{ "source": "https://github.com/x/y" }' | ConvertFrom-Json)) (Join-Path $plugins 'unity') 'a git source lives in the install'
    Assert-Equal (Get-PluginDir (Join-Path $root 'S') 'unity' $null) (Join-Path $plugins 'unity') 'a listed plugin lives in the install'
    Assert-Equal (Get-PluginDir (Join-Path $root 'S') 'one' ('{ "source": "' + $one.Replace('\', '/') + '" }' | ConvertFrom-Json)) $one 'a folder source stays where it is'

    # A plugin loaded inside Start-Job works as in the script.
    $job = Start-Job -ArgumentList $baseDir, $one -ScriptBlock {
        param($base, $dir)
        . (Join-Path $base 'project.ps1')
        . (Join-Path $base 'plugins.ps1')
        $plugin = Import-Plugin $dir 'one' $null
        (Merge-RunAnswers (Invoke-Hooks @($plugin) 'GetRun' 'D:/p' 'D:/p' $null $null $null)).Prompt
    }
    $null = Wait-Job $job -Timeout 60
    Assert-Equal (Receive-Job $job) 'Word one.' 'a plugin inside Start-Job'
    Remove-Job $job -Force

    # No plugin: a plain git repo. The run gets no server, the base's commands and no prompt.
    $plain = '{ "name": "App", "plugins": {} }' | ConvertFrom-Json
    $none = Import-Plugins $root $plain
    Assert-Equal @($none).Count 0 'no plugin'
    Assert-Equal (Invoke-Hooks $none 'Start' 'D:/p' 'D:/p-w1' 1 'D:/q' $null).Count 0 'Start does nothing'
    $run = Merge-RunAnswers (Invoke-Hooks $none 'GetRun' 'D:/p' 'D:/p-w1' 1 'D:/q' $null)
    Assert-Equal "$($run.McpServers.Count) $((Get-RunCommands $plain $run) -join ',') $(@(Get-RunTools $plain $run).Count)" '0 git,gh 0' 'no server, the base''s commands only, no tool rule'
    Assert-Equal $run.Prompt '' 'no prompt'
    Assert-Equal (Import-Plugins $root ('{ "name": "App" }' | ConvertFrom-Json)).Count 0 'no plugins key'

    # The provider (docs/PLUGINS.md, A provider): the first plugin whose manifest says so. Its hooks get the scope's
    # fields with the call's over them, and the PC's settings of the plugin.
    Assert-Equal "$([bool](Get-Provider $plugins)) $([bool](Get-Provider $none))" 'False False' 'no provider among plain plugins'
    $test = Import-Plugin (Join-Path $PSScriptRoot 'provider') 'test' ('{ "level": 3 }' | ConvertFrom-Json)
    $found = Get-Provider (@($plugins) + @($test))
    Assert-Equal "$($found.Name) $($found.Provider) $($found.Skills)" 'test True .test/skills' 'the provider and its skills folder'
    Set-Provider $found @{ Project = 'D:/p'; Copy = 'D:/p-w1'; Worker = 4; QueueDir = 'D:/p-w1/.queue'; Machine = { '{ "plugins": { "test": { "level": 5 } } }' | ConvertFrom-Json } }
    Assert-Equal (Read-Models).advisor.model 'deep-1' 'the models are the provider''s'
    $seen = Invoke-Provider 'GetCommand' @{ Copy = 'D:/other'; Run = @{ Model = 'main-1'; Prompt = 'Do it.'; Session = 's1'; Login = 'C:/l'; Commands = @('git', 'unity command') } }
    Assert-Equal "$($seen.FilePath) $($seen.Arguments -join '|') $($seen.Env.TEST_LOGIN)" 'test-tool resume|s1|run|--model|main-1|--allow=git|--allow=unity command|Do it. C:/l' 'the command of a run'
    $provider = $found
    $provider.Hooks.Peek = { param($ctx) "$($ctx.Project) $($ctx.Copy) $($ctx.Worker) $($ctx.QueueDir) $($ctx.Settings.level) $($ctx.Extra)" }
    Assert-Equal (Invoke-Provider 'Peek' @{ Extra = 'x' }) 'D:/p D:/p-w1 4 D:/p-w1/.queue 5 x' 'the context of a provider''s hook'
    Assert-Equal (Invoke-Provider 'Peek' @{ Copy = 'D:/job' }).Split(' ')[1] 'D:/job' 'a call''s field goes over the scope''s'
    $provider.Hooks.Fail = { param($ctx) throw 'no tool' }
    $threw = ''
    try { Invoke-Provider 'Fail' | Out-Null } catch { $threw = "$_" }
    Assert-Equal $threw 'plugin test, Fail: no tool' 'a hook that throws names its plugin'
    # What the test provider reads from a log of its tool: the usage, the run's end and its numbers.
    $log = "session s9`nusage short=0.1@100 long=0.2@900`nstep one`nstep two`nusage short=0.4@100 long=0.3@900 refused=deep@950`nend window:deep The deep model is used up"
    $first = Invoke-Provider 'ReadUsage' @{ Text = $log; First = $true }
    $last = Invoke-Provider 'ReadUsage' @{ Text = $log }
    Assert-Equal "$($first.Windows.short.Used) $($last.Windows.short.Used) $($last.Windows.long.ResetsAt) '$($first.Refused)' $($last.Refused) $($last.RefusedResetsAt)" "0.1 0.4 900 '' deep 950" 'the first and the last reading'
    $end = Invoke-Provider 'ReadRun' @{ Text = $log }
    Assert-Equal "$($end.Session) $($end.Ended) $($end.Error) $($end.Kind) $($end.Window) $($end.Worked) $($end.Numbers.requests)" 's9 True True window deep True 2' 'the end of a run'
    Assert-Equal (Invoke-Provider 'ReadRun' @{ Text = 'step one' }).Ended $false 'a log with no end'
    # A provider with only the hooks it must have: every other hook is a feature that is off.
    Set-Provider (Import-Plugin (Join-Path $PSScriptRoot 'bare') 'bare' $null)
    Assert-Equal "$(Test-ProviderHook 'GetCommand') $(Test-ProviderHook 'ReadRun') $(Test-ProviderHook 'Probe') $(Test-ProviderHook 'Compact')" 'True True False False' 'the hooks of a bare provider'
    Assert-Equal "$($null -eq (Invoke-Provider 'ReadUsage' @{ Text = 'x' })) $($null -eq (Invoke-Provider 'GetLogin' @{ Login = '' }))" 'True True' 'a hook it does not have answers nothing'
    Assert-Equal "'$((Read-Models).advisor.model)' '$((Split-Pick (Read-Models) 'only').effort)'" "'' ''" 'no advisor and no effort'
    # No provider: no hook, and a model list with no model.
    Set-Provider $null
    Assert-Equal "$(Test-ProviderHook 'GetCommand') $($null -eq (Invoke-Provider 'GetCommand')) $(@((Read-Models).models.PSObject.Properties).Count)" 'False True 0' 'no provider'

    # A worker runs on its account's coding tool, in any project (docs/QUEUE.md, Accounts). The providers of a
    # project's scripts: its own, the default first, then each in the install's plugins folder that it does not name.
    $install = Join-Path $root 'install'
    New-Item -ItemType Directory -Force (Join-Path $install 'plugins/empty') | Out-Null
    foreach ($name in @('bare', 'provider')) {
        Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $install "plugins/$name") -Recurse
    }
    New-Plugin (Join-Path $install 'plugins') 'tool' '@{}' | Out-Null
    $mine = Import-Plugin (Join-Path $PSScriptRoot 'provider') 'provider' $null
    $found = Get-Providers $install @($mine)
    Assert-Equal (($found | ForEach-Object { $_.Name }) -join ',') 'provider,bare' 'the project''s own first, then the install''s; a plugin that is no provider and a folder with no plugin are none'
    Assert-Equal (((Get-Providers $install @()) | ForEach-Object { $_.Name }) -join ',') 'bare,provider' 'a project that names none has the install''s'
    Assert-Equal (Get-Providers (Join-Path $root 'nowhere') @()).Count 0 'no plugins folder, no provider'
    # The provider of an account, and of a worker: its account's.
    $register = '{"accounts":{"main":{"provider":"bare","uses":["worker:1","personal"]},"own":{"provider":"provider","configDir":"C:/o","uses":["worker:2"]},"old":{"configDir":"C:/x","uses":["worker:4"]},"far":{"provider":"other","configDir":"C:/f","uses":["worker:5"]}}}' | ConvertFrom-Json
    Assert-Equal "$((Get-AccountProvider $register.accounts.main $found).Name) $((Get-AccountProvider $register.accounts.old $found).Name) $((Get-AccountProvider $null $found).Name) $($null -eq (Get-AccountProvider $register.accounts.far $found))" 'bare provider provider True' 'an account''s provider; the default for one that names none; none for a tool with no plugin'
    Assert-Equal ((@('1', '2', '3', '4', '5') | ForEach-Object { "$((Get-WorkerProvider $register $_ $found).Name)" }) -join ',') 'bare,provider,bare,provider,' 'a worker runs on its account''s tool; worker 3, in no entry, on the command-line login''s'
    Assert-Equal (Get-WorkerProvider ('{"accounts":{"a":{"provider":"bare","configDir":"C:/a","uses":[]}}}' | ConvertFrom-Json) '3' $found).Name 'provider' 'in no entry on a PC with no entry of the command-line login: the default'
    Assert-Equal (Get-WorkerProvider $null '3' $found).Name 'provider' 'no settings: the default'
    # A script that serves several providers: one is set for a block, and the one from before comes back.
    Set-Providers $found @{ Project = 'D:/p' }
    Assert-Equal "$($script:Provider.Name) $((Get-KnownProviders).Count)" 'provider 2' 'the first of the list is set'
    Assert-Equal "$(Use-Provider $found[1] { $script:Provider.Name }) $($script:Provider.Name) $($script:ProviderScope.Project)" 'bare provider D:/p' 'another provider for a block, with the same scope'
    try { Use-Provider $found[1] { throw 'no' } } catch { }
    Assert-Equal "$($script:Provider.Name) $(Use-Provider $null { $script:Provider.Name })" 'provider provider' 'the one from before comes back after an error; no provider to use changes nothing'
    Select-Provider $found[1]
    Assert-Equal (Invoke-Provider 'Peek') $null 'the selected provider answers: the bare one has no such hook'
    $script:Providers = @()
    Assert-Equal "$(((Get-KnownProviders) | ForEach-Object { $_.Name }) -join ',') $((Get-KnownProviders).Count)" 'bare 1' 'a script with one provider serves that one, as a list'
    Set-Provider $null
    Assert-Equal (Get-KnownProviders).Count 0 'no provider, none served'
} finally {
    Remove-Item $root -Recurse -Force
}

Write-Output 'ok'
