# Parses every .ps1 of Scriptorium and runs every *.test.ps1 in the PowerShell that runs this (Windows PowerShell 5.1,
# or pwsh 7 on macOS and Linux), each in a process of its own. Prints one line for each and exits 1 when one fails. CI
# runs it in both (.github/workflows/test.yml); run it before a PR:
#   powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1
#   pwsh -NoProfile -File check.ps1
$ErrorActionPreference = 'Stop'
$failed = 0
$files = @(Get-ChildItem $PSScriptRoot -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/](_source|plugins)[\\/]' })

foreach ($file in $files) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        $failed++
        Write-Output "parse FAILED $($file.FullName): $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))"
    }
    # Names ignore case: a local with the name of the function's own switch is that switch, and a value of another type
    # stops the script there, only when it runs.
    foreach ($function in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $switches = @($function.Parameters) + @($function.Body.ParamBlock.Parameters) | Where-Object { $_ -and $_.StaticType -eq [switch] }
        foreach ($name in $switches | ForEach-Object { $_.Name.VariablePath.UserPath }) {
            $hit = $function.Body.Find({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $args[0].Left.VariablePath.UserPath -eq $name }, $true)
            if ($hit) {
                $failed++
                Write-Output "switch FAILED $($file.Name): line $($hit.Extent.StartLineNumber) assigns to -$name, a switch of $($function.Name)"
            }
        }
    }
}
Write-Output "parsed $($files.Count) files"

$powershell = (Get-Process -Id $PID).Path
foreach ($test in $files | Where-Object { $_.Name -like '*.test.ps1' }) {
    $ErrorActionPreference = 'Continue'
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or @($output)[-1] -ne 'ok') {
        $failed++
        Write-Output "test FAILED $($test.Name):"
        $output | ForEach-Object { Write-Output "  $_" }
    } else {
        Write-Output "test ok $($test.Name)"
    }
}
exit $(if ($failed) { 1 } else { 0 })
