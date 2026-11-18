# Parses every .ps1 of Scriptorium and runs every *.test.ps1 in Windows PowerShell, each in a process of its own.
# Prints one line for each and exits 1 when one fails. CI runs it (.github/workflows/test.yml); run it before a PR:
#   powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1
$ErrorActionPreference = 'Stop'
$failed = 0
$files = @(Get-ChildItem $PSScriptRoot -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\(_source|plugins)\\' })

foreach ($file in $files) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors) {
        $failed++
        Write-Output "parse FAILED $($file.FullName): $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))"
    }
}
Write-Output "parsed $($files.Count) files"

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
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
