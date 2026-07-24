$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot "lib\SELibs.Install.ps1")

$script:Passed = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Expected,

        [Parameter(Mandatory = $true)]
        $Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw (
            "$Message`n" +
            "Expected: '$Expected'`n" +
            "Actual:   '$Actual'"
        )
    }

    $script:Passed++
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }

    $script:Passed++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedMessagePart
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessagePart*") {
            throw (
                "Expected error containing '$ExpectedMessagePart', " +
                "but received '$($_.Exception.Message)'."
            )
        }

        $script:Passed++
        return
    }

    throw "Expected an exception containing '$ExpectedMessagePart'."
}

$testRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("selibs-install-tests-" + [Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $targetEntry = Join-Path $testRoot "SELibs\bin"
    $otherOne = Join-Path $testRoot "OtherOne"
    $otherTwo = Join-Path $testRoot "OtherTwo"

    $addedPath = Add-SELibsPathEntry `
        -PathValue "$otherOne;$otherTwo" `
        -Entry $targetEntry

    Assert-Equal `
        -Expected "$otherOne;$otherTwo;$targetEntry" `
        -Actual $addedPath `
        -Message "The installer did not append its PATH entry."

    $deduplicatedPath = Add-SELibsPathEntry `
        -PathValue (
            "$otherOne;$targetEntry;$($targetEntry.ToUpperInvariant())\;" +
            $otherTwo
        ) `
        -Entry $targetEntry

    Assert-Equal `
        -Expected "$otherOne;$otherTwo;$targetEntry" `
        -Actual $deduplicatedPath `
        -Message "Equivalent SELibs PATH entries were not deduplicated."

    $removedPath = Remove-SELibsPathEntry `
        -PathValue "$otherOne;$targetEntry;$otherTwo" `
        -Entry "$targetEntry\"

    Assert-Equal `
        -Expected "$otherOne;$otherTwo" `
        -Actual $removedPath `
        -Message "Uninstall did not preserve unrelated PATH entries."

    $installRoot = Join-Path $testRoot "InstalledSELibs"

    $installOutput = @(
        Invoke-SELibsInstall `
            -SourceRoot $repoRoot `
            -InstallRoot $installRoot `
            -SkipPathUpdate
    )

    Assert-True `
        -Condition ($installOutput -contains "Installed SELibs.") `
        -Message "Installation success was not reported."

    foreach ($relativePath in @(
        "install.json",
        "uninstall.ps1",
        "lib\SELibs.Install.ps1",
        "bin\selibs.cmd",
        "bin\selibs.ps1",
        "bin\lib\SELibs.Package.ps1"
    )) {
        Assert-True `
            -Condition (Test-Path -LiteralPath (
                Join-Path $installRoot $relativePath
            ) -PathType Leaf) `
            -Message "Installed file '$relativePath' is missing."
    }

    $marker = Read-SELibsInstallMarker -InstallRoot $installRoot

    Assert-Equal `
        -Expected "SELibs" `
        -Actual ([string]$marker.product) `
        -Message "The installation marker has the wrong product."

    $helpOutput = @(
        & (Join-Path $installRoot "bin\selibs.cmd") help
    )

    if ($LASTEXITCODE -ne 0) {
        throw (
            "The installed launcher failed with exit code " +
            "$LASTEXITCODE."
        )
    }

    Assert-True `
        -Condition (
            $helpOutput -contains (
                "SELibs - source-library manager for Space Engineers mods"
            )
        ) `
        -Message "The installed launcher did not execute SELibs."

    $installedManager = Join-Path $installRoot "bin\selibs.ps1"

    [System.IO.File]::WriteAllText(
        $installedManager,
        "broken",
        $script:Utf8NoBom
    )

    Invoke-SELibsInstall `
        -SourceRoot $repoRoot `
        -InstallRoot $installRoot `
        -SkipPathUpdate |
        Out-Null

    $sourceHash = (
        Get-FileHash `
            -LiteralPath (Join-Path $repoRoot "selibs.ps1") `
            -Algorithm SHA256
    ).Hash

    $installedHash = (
        Get-FileHash `
            -LiteralPath $installedManager `
            -Algorithm SHA256
    ).Hash

    Assert-Equal `
        -Expected $sourceHash `
        -Actual $installedHash `
        -Message "Reinstall did not replace the managed runtime."

    $foreignRoot = Join-Path $testRoot "ForeignDirectory"
    New-Item -ItemType Directory -Path $foreignRoot | Out-Null

    Assert-Throws `
        -Action {
            Invoke-SELibsInstall `
                -SourceRoot $repoRoot `
                -InstallRoot $foreignRoot `
                -SkipPathUpdate |
                Out-Null
        } `
        -ExpectedMessagePart "is not managed by SELibs"

    Assert-True `
        -Condition (Test-Path -LiteralPath $foreignRoot -PathType Container) `
        -Message "Installer removed an unmanaged destination."

    $uninstallOutput = @(
        Invoke-SELibsUninstall `
            -InstallRoot $installRoot `
            -SkipPathUpdate
    )

    Assert-True `
        -Condition ($uninstallOutput -contains "Uninstalled SELibs.") `
        -Message "Uninstall success was not reported."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $installRoot)) `
        -Message "The managed installation root was not removed."

    $secondUninstall = @(
        Invoke-SELibsUninstall `
            -InstallRoot $installRoot `
            -SkipPathUpdate
    )

    Assert-True `
        -Condition (
            $secondUninstall -contains "SELibs is already uninstalled."
        ) `
        -Message "Repeated uninstall was not idempotent."

    Assert-Throws `
        -Action {
            Invoke-SELibsUninstall `
                -InstallRoot $foreignRoot `
                -SkipPathUpdate |
                Out-Null
        } `
        -ExpectedMessagePart "is not managed by SELibs"

    Write-Output (
        "OK SELibs installer tests passed: " +
        "$script:Passed assertions"
    )
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
