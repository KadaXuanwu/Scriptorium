# The test provider (docs/PLUGINS.md, A provider): every hook, the older Probe and Compact too, for a tool whose log is plain lines:
#   session <id>
#   usage <window>=<share>@<reset> ... [refused=<window>@<reset>]
#   step <words>
#   end ok <words> | end error <words> | end error(<detail>) <words> | end <kind> <words> (a refusal: login, limit ...)

function Read-Lines([string] $text, [string] $word) {
    return @($text -split "`r?`n" | Where-Object { $_ -like "$word *" } | ForEach-Object { $_.Substring($word.Length + 1) })
}

function Read-UsageLine([string] $line) {
    $read = @{ Windows = @{}; Refused = ''; RefusedResetsAt = 0 }
    foreach ($part in $line -split ' ') {
        $name, $value = $part -split '='
        $share, $reset = $value -split '@'
        if ($name -eq 'refused') {
            $read.Refused = $share
            $read.RefusedResetsAt = [long]$reset
        } else {
            $read.Windows[$name] = @{ Used = [double]$share; ResetsAt = [long]$reset }
        }
    }
    return $read
}

function Read-EndLine([string] $text) {
    $line = Read-Lines $text 'end' | Select-Object -Last 1
    if (-not $line) {
        return $null
    }
    $kind, $words = $line -split ' ', 2
    $detail = ''
    if ($kind -match '^error\((.+)\)$') {
        $detail = $Matches[1]
        $kind = 'error'
    }
    return @{ Kind = $kind; Detail = $detail; Text = [string]$words }
}

@{
    GetLogin = {
        param($ctx)
        $file = Join-Path $ctx.Login 'login.txt'
        if (-not $ctx.Login -or -not (Test-Path $file)) {
            return @{ SignedIn = $false; Email = ''; Plan = ''; PlanSize = 1.0; Stamp = '0' }
        }
        $email, $plan, $size = (Get-Content $file -Raw).Trim() -split ' '
        return @{ SignedIn = $true; Email = $email; Plan = $plan; PlanSize = [double]$size; Stamp = [string](Get-Item $file).LastWriteTimeUtc.Ticks }
    }
    SignIn = { param($ctx) @{ Command = "test-tool login $($ctx.Email)"; Env = @{ TEST_LOGIN = $ctx.Login } } }
    ReadSignIn = { param($ctx) @{ Url = [regex]::Match($ctx.Text, 'https://\S+').Value; Message = (@($ctx.Text -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1) } }
    SignOut = { param($ctx) Remove-Item (Join-Path $ctx.Login 'login.txt') -ErrorAction SilentlyContinue }
    # A probe in both forms, with the same reading. GetProbe's tool is the shell that runs the base.
    GetProbe = {
        param($ctx)
        @{ FilePath = (Get-Process -Id $PID).Path; Arguments = @('-NoProfile', '-Command', "Write-Output 'usage short=0.5@100'"); Env = @{ TEST_LOGIN = $(if ($ctx.Login) { $ctx.Login }) } }
    }
    ReadProbe = { param($ctx) @{ Usage = Read-UsageLine (Read-Lines $ctx.Text 'usage' | Select-Object -Last 1); Answered = $true; Kind = ''; Text = 'ok' } }
    Probe = { param($ctx) @{ Usage = Read-UsageLine 'short=0.5@100'; Answered = $true; Kind = ''; Text = 'ok' } }
    GetCommand = {
        param($ctx)
        $run = $ctx.Run
        $arguments = @('run', '--model', $run.Model) + @($run.Commands | ForEach-Object { "--allow=$_" }) + @($run.Prompt)
        if ($run.Session) {
            $arguments = @('resume', $run.Session) + $arguments
        }
        return @{ FilePath = 'test-tool'; Arguments = $arguments; Env = @{ TEST_LOGIN = $(if ($run.Login) { $run.Login }) } }
    }
    # A compaction in both forms, with the same line. GetCompact's tool is the shell that runs the base: session 'fail'
    # prints no compaction, session 'hang' never ends.
    GetCompact = {
        param($ctx)
        $say = switch ($ctx.Run.Session) { 'fail' { "Write-Output 'no'" } 'hang' { 'Start-Sleep 600' } default { "Write-Output 'compacted $($ctx.Run.Session)'" } }
        @{ FilePath = (Get-Process -Id $PID).Path; Arguments = @('-NoProfile', '-Command', $say) }
    }
    ReadCompact = { param($ctx) Read-Lines $ctx.Text 'compacted' | Select-Object -Last 1 | ForEach-Object { "compacted $_" } }
    Compact = { param($ctx) "compacted $($ctx.Run.Session)" }
    ReadUsage = {
        param($ctx)
        $lines = @(Read-Lines $ctx.Text 'usage')
        if (-not $lines.Count) {
            return $null
        }
        return Read-UsageLine $(if ($ctx.First) { $lines[0] } else { $lines[-1] })
    }
    ReadRun = {
        param($ctx)
        $end = Read-EndLine $ctx.Text
        $steps = @(Read-Lines $ctx.Text 'step')
        $run = @{
            Session = [string](Read-Lines $ctx.Text 'session' | Select-Object -Last 1); Ended = [bool]$end; Error = $false; Kind = ''
            Window = ''; Capped = $false; Text = ''; Worked = $steps.Count -gt 0; Numbers = [ordered]@{ requests = $steps.Count }
        }
        if ($end) {
            $run.Text = $end.Text
            $run.Error = $end.Kind -ne 'ok'
            if ($end.Kind -eq 'cap') {
                $run.Capped = $true
            } elseif ($end.Kind -like 'window:*') {
                $run.Kind = 'window'
                $run.Window = $end.Kind.Substring(7)
            } elseif (@('ok', 'error') -notcontains $end.Kind) {
                $run.Kind = $end.Kind
            }
        }
        return $run
    }
    ReadStep = { param($ctx) if ($ctx.Line -like 'step *') { $ctx.Line.Substring(5) } }
    ReadEnd = {
        param($ctx)
        $end = Read-EndLine $ctx.Text
        if (-not $end) {
            return $null
        }
        return @{ Error = $end.Kind -ne 'ok'; Detail = $end.Detail; Text = $end.Text }
    }
}
