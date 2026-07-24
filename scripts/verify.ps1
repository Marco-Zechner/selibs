$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$tests = Join-Path $repoRoot "tests\SELibs.Tests.ps1"

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $tests

if ($LASTEXITCODE -ne 0) {
    throw "SELibs tests failed with exit code $LASTEXITCODE."
}