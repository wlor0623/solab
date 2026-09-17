[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestArguments
)

if (-not $TestArguments -or $TestArguments.Count -eq 0) {
    throw 'Provide at least one targeted test file or flutter test argument.'
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDirectory
$testExitCode = 1

Push-Location $projectRoot
try {
    & flutter test @TestArguments
    $testExitCode = $LASTEXITCODE
}
finally {
    & flutter clean
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "flutter clean failed with exit code $LASTEXITCODE."
    }
    Pop-Location
}

exit $testExitCode
