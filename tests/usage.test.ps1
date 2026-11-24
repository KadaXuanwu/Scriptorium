# Checks usage.ps1: powershell -NoProfile -File tests/usage.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
$baseDir = Split-Path $PSScriptRoot
. (Join-Path $baseDir 'usage.ps1')

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# A run on Opus with the Fable advisor: request 1 on two lines (the last one's usage counts), a subagent's request,
# request 2 with the advisor and a read, a compaction, request 3 with text only, and two results, the last the
# session's whole, in the shape of Claude Code 2.1.323 (the result line does not start with its type).
$log = @(
    '{"type":"system","subtype":"init","model":"claude-opus-5-5","tools":["Bash","Read"]}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"parent_tool_use_id":null}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":30000,"cache_read_input_tokens":0}},"parent_tool_use_id":null}'
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"{\"type\":\"result\"}"}]},"parent_tool_use_id":null}'
    '{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"s1","content":[{"type":"tool_use","id":"t9","name":"Grep","input":{}}],"usage":{"input_tokens":9,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0}},"parent_tool_use_id":"t0"}'
    '{"type":"rate_limit_event","rate_limit_info":{}}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"server_tool_use","id":"a1","name":"advisor","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"advisor_tool_result","tool_use_id":"a1"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
    '{"duration_api_ms":1,"type":"result","subtype":"success","total_cost_usd":1.0,"modelUsage":{"claude-opus-5-5":{"costUSD":1.0}}}'
    '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto"}}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m3","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":10000,"cache_read_input_tokens":5000}},"parent_tool_use_id":null}'
    '{"duration_api_ms":2,"type":"result","subtype":"success","total_cost_usd":3.75,"modelUsage":{"claude-opus-5-5":{"costUSD":2.5},"claude-fable-5-2":{"costUSD":1.25}}}'
) -join "`n"

$numbers = Get-RunNumbers $log
Assert-Equal $numbers.requests 3 'requests: distinct message ids of the main session'
Assert-Equal $numbers.toolCalls 3 'tool calls: the advisor counts, a subagent call does not'
Assert-Equal $numbers.first 30002 'first request: the last line of its id'
Assert-Equal $numbers.ctxMean 25669 'mean context of 30002, 32001 and 15003'
Assert-Equal $numbers.ctxMax 32001 'largest context'
Assert-Equal $numbers.read 35000 'cache reads'
Assert-Equal $numbers.write 42000 'cache writes'
Assert-Equal $numbers.compactions 1 'compactions'
Assert-Equal $numbers.advisorCalls 1 'advisor calls'
Assert-Equal $numbers.advisorCost 1.25 "the last result's cost of the models other than the run's own"

# The init line names the run's own model as modelUsage does, a 1M context one too; without it no advisor cost.
$own = '{"type":"system","subtype":"init","model":"claude-opus-5-5[1m]"}' + "`n" +
    '{"type":"result","total_cost_usd":3.0,"modelUsage":{"claude-opus-5-5[1m]":{"costUSD":3.0}}}'
Assert-Equal (Get-RunNumbers $own).advisorCost 0 'a 1M context model is the run own'
Assert-Equal (Get-RunNumbers ($log -replace '"subtype":"init"', '"subtype":"other"')).advisorCost 0 'no init line'
Assert-Equal (Get-RunNumbers '').requests 0 'an empty log'

Write-Output 'ok'
