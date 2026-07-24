$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$tests = @(
    "tests\SELibs.Tests.ps1",
    "tests\SELibs.Package.Tests.ps1",
    "tests\SELibs.Install.Tests.ps1"
)

foreach ($relativePath in $tests) {
    $testPath = Join-Path $repoRoot $relativePath

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $testPath

    if ($LASTEXITCODE -ne 0) {
        throw (
            "SELibs test '$relativePath' failed with " +
            "exit code $LASTEXITCODE."
        )
    }
}
