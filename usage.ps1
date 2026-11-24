# A run's numbers from its stream-json log (docs/QUEUE.md, History): requests, tool calls, commands, context sizes,
# cache reads and writes, compactions and the advisor. Pure, dot-sourced by worker.ps1 and report.ps1, checked by
# usage.test.ps1.

# The commands that one Bash call chains: its parts between `;`, `&&`, `||` and line ends, at least 1. A pipeline is one
# command. A here-document's body and what stands in quotes are left out first. `cd` and the words of a loop or an if
# are no command. A run batches its work this way, so tool calls for each request cannot show it (PLAYBOOK.md, Turns).
# shortcut: no shell parser, so a quote in a comment or a `;` inside $( ) miscounts; parse when one run's count matters.
function Get-CommandCount([string] $command) {
    # One pass for both quotes: the one that opens first wins, so an apostrophe inside double quotes opens nothing.
    $bare = $command -replace '(?s)<<-?\s*[''"]?(\w+)[''"]?.*?\n\s*\1\b', '' `
        -replace '''[^'']*''|"(?:[^"\\]|\\.)*"', 'Q'
    $parts = @($bare -split '&&|\|\||;|\n' |
        Where-Object { $_.Trim() -and $_ -notmatch '^\s*(cd\s.*|do|done|then|else|fi|[{}])\s*$' })
    return [math]::Max(1, $parts.Count)
}

# The numbers of one run log's text. A request comes as several assistant lines, one for each content block, under one
# message id; its usage is on each, the last one's counts. A subagent's lines (parent_tool_use_id) are not the run's.
# The user lines are never parsed: they hold the tool results, the large part of a log. A result line starts with
# another key in newer Claude Code ({"duration_api_ms"...), so it is found by its type. advisorCost is the result's cost
# of each model other than the run's own (the init line's model): the whole session's, the part before a pause too.
# An advisor of the run's own model has no cost of its own in the result: advisorCost is then 0.
# A line Windows PowerShell cannot parse (keys that differ only in case) is left out. commands: the tool calls, a Bash
# call counted as the commands it chains (Get-CommandCount).
function Get-RunNumbers([string] $text) {
    $context = [ordered]@{}
    $read = @{}
    $write = @{}
    $toolCalls = 0
    $commands = 0
    $advisorCalls = 0
    $compactions = 0
    $model = ''
    $result = $null
    foreach ($line in $text -split "`n") {
        if ($line.StartsWith('{"type":"user"')) {
            continue
        }
        if ($line.StartsWith('{"type":"system"')) {
            if ($line -like '*"subtype":"compact_boundary"*') {
                $compactions++
            } elseif (-not $model -and $line -like '*"subtype":"init"*') {
                try { $model = [string]($line | ConvertFrom-Json).model } catch { }
            }
            continue
        }
        $isAssistant = $line.StartsWith('{"type":"assistant"')
        if (-not $isAssistant -and $line -notlike '*"type":"result"*') {
            continue
        }
        try {
            $parsed = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not $isAssistant) {
            if ($parsed.type -eq 'result') {
                $result = $parsed
            }
            continue
        }
        if ($parsed.parent_tool_use_id -or -not $parsed.message.id) {
            continue
        }
        $id = $parsed.message.id
        $usage = $parsed.message.usage
        $read[$id] = [long]$usage.cache_read_input_tokens
        $write[$id] = [long]$usage.cache_creation_input_tokens
        $context[$id] = [long]$usage.input_tokens + $read[$id] + $write[$id]
        foreach ($block in @($parsed.message.content)) {
            if ($block.type -eq 'tool_use' -or $block.type -eq 'server_tool_use') {
                $toolCalls++
                $commands += if ($block.name -eq 'Bash') { Get-CommandCount ([string]$block.input.command) } else { 1 }
                if ($block.name -eq 'advisor') {
                    $advisorCalls++
                }
            }
        }
    }
    $sizes = @($context.Values)
    $advisorCost = 0.0
    if ($result -and $model) {
        foreach ($entry in @($result.modelUsage.PSObject.Properties)) {
            if ($entry.Name -ne $model) {
                $advisorCost += [double]$entry.Value.costUSD
            }
        }
    }
    return [ordered]@{
        requests = $sizes.Count
        toolCalls = $toolCalls
        commands = $commands
        first = $(if ($sizes.Count) { $sizes[0] } else { 0 })
        ctxMean = $(if ($sizes.Count) { [long][math]::Round(($sizes | Measure-Object -Sum).Sum / $sizes.Count) } else { 0 })
        ctxMax = $(if ($sizes.Count) { [long]($sizes | Measure-Object -Maximum).Maximum } else { 0 })
        read = [long]($read.Values | Measure-Object -Sum).Sum
        write = [long]($write.Values | Measure-Object -Sum).Sum
        compactions = $compactions
        advisorCalls = $advisorCalls
        advisorCost = $advisorCost
    }
}
