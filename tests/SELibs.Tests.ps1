$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot "selibs.ps1")

$script:Passed = 0

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

function New-TestModRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $root = Join-Path $script:TestRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

$script:TestRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("selibs-tests-" + [Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

try {
    $explicitRoot = New-TestModRoot -Name "ExplicitMod"

    Invoke-SELibsInit `
        -ModRoot $explicitRoot `
        -LibrariesPath "Data/Scripts/Custom/Libraries" |
        Out-Null

    $explicitManifestPath = Join-Path $explicitRoot "selibs.json"
    $explicitManifest = Read-SELibsManifest -Path $explicitManifestPath

    Assert-Equal `
        -Expected "Data/Scripts/Custom/Libraries" `
        -Actual ([string]$explicitManifest.librariesPath) `
        -Message "Explicit librariesPath was not preserved."

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $explicitRoot "Data\Scripts\Custom\Libraries"
        )) `
        -Message "Explicit Libraries directory was not created."

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $explicitRoot ".selibs"
        )) `
        -Message "Local SELibs state directory was not created."

    $singleRoot = New-TestModRoot -Name "SingleFolderMod"
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $singleRoot "Data\Scripts\FlightControl") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $singleRoot | Out-Null
    $singleManifest = Read-SELibsManifest `
        -Path (Join-Path $singleRoot "selibs.json")

    Assert-Equal `
        -Expected "Data/Scripts/FlightControl/Libraries" `
        -Actual ([string]$singleManifest.librariesPath) `
        -Message "The sole script folder was not detected."

    $inferredRoot = New-TestModRoot -Name "InferredMod"
    Invoke-SELibsInit -ModRoot $inferredRoot | Out-Null
    $inferredManifest = Read-SELibsManifest `
        -Path (Join-Path $inferredRoot "selibs.json")

    Assert-Equal `
        -Expected "Data/Scripts/InferredMod/Libraries" `
        -Actual ([string]$inferredManifest.librariesPath) `
        -Message "The mod-root name was not used for an empty mod."

    $multipleRoot = New-TestModRoot -Name "MultipleFolderMod"

    foreach ($folder in @("Alpha", "Beta")) {
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $multipleRoot "Data\Scripts\$folder") `
            -Force |
            Out-Null
    }

    Assert-Throws `
        -Action {
            Invoke-SELibsInit -ModRoot $multipleRoot | Out-Null
        } `
        -ExpectedMessagePart "Several folders exist below Data\Scripts"

    $outsideRoot = New-TestModRoot -Name "OutsidePathMod"

    Assert-Throws `
        -Action {
            Invoke-SELibsInit `
                -ModRoot $outsideRoot `
                -LibrariesPath "..\Outside\Libraries" |
                Out-Null
        } `
        -ExpectedMessagePart "must be inside mod root"

    $wrongLeafRoot = New-TestModRoot -Name "WrongLeafMod"

    Assert-Throws `
        -Action {
            Invoke-SELibsInit `
                -ModRoot $wrongLeafRoot `
                -LibrariesPath "Data\Scripts\Wrong\NotLibraries" |
                Out-Null
        } `
        -ExpectedMessagePart "must end in a folder named 'Libraries'"

    $ignoreRoot = New-TestModRoot -Name "GitIgnoreMod"
    [System.IO.File]::WriteAllText(
        (Join-Path $ignoreRoot ".gitignore"),
        "# Existing project ignores`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    $recommendations = @(
        Get-SELibsGitIgnoreRecommendations -ModRoot $ignoreRoot
    )

    Assert-Equal `
        -Expected 1 `
        -Actual $recommendations.Count `
        -Message "Unexpected number of .gitignore recommendations."

    Assert-Equal `
        -Expected "/.selibs/" `
        -Actual $recommendations[0] `
        -Message "The missing local-state ignore was not recommended."

    $existingIgnoreRoot = New-TestModRoot -Name "ExistingIgnoreMod"
    [System.IO.File]::WriteAllText(
        (Join-Path $existingIgnoreRoot ".gitignore"),
        "/.selibs/`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    $existingRecommendations = @(
        Get-SELibsGitIgnoreRecommendations -ModRoot $existingIgnoreRoot
    )

    Assert-Equal `
        -Expected 0 `
        -Actual $existingRecommendations.Count `
        -Message "An existing SELibs ignore entry was recommended again."

    $cliRoot = New-TestModRoot -Name "GlobalCliMod"
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $cliRoot "Data\Scripts\GlobalCliMod") `
        -Force |
        Out-Null

    Push-Location $cliRoot

    try {
        & (Join-Path $repoRoot "selibs.cmd") init | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Global SELibs launcher exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $cliRoot "selibs.json"
        )) `
        -Message "The global launcher did not initialize the current mod."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (
            Join-Path $cliRoot "selibs.ps1"
        ))) `
        -Message "The global launcher copied itself into the mod."

    $idempotentRoot = New-TestModRoot -Name "IdempotentMod"
    Invoke-SELibsInit -ModRoot $idempotentRoot | Out-Null

    $manifestPath = Join-Path $idempotentRoot "selibs.json"
    $before = Get-Content -LiteralPath $manifestPath -Raw

    Invoke-SELibsInit -ModRoot $idempotentRoot | Out-Null

    $after = Get-Content -LiteralPath $manifestPath -Raw

    Assert-Equal `
        -Expected $before `
        -Actual $after `
        -Message "Repeated init unexpectedly rewrote the manifest."

    Write-Output "OK SELibs tests passed: $script:Passed assertions"
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}