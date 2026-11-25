# The bare provider (docs/PLUGINS.md, A provider): only the two hooks a provider must have. It reads no usage, knows
# no login and cannot compact, probe or sign in, so the base runs with each of those features off.
@{
    GetCommand = { param($ctx) @{ FilePath = 'bare-tool'; Arguments = @($ctx.Run.Prompt) } }
    ReadRun = { param($ctx) @{ Session = ''; Ended = $ctx.Text -like '*done*'; Error = $false; Kind = ''; Worked = $true } }
}
