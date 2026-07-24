$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot "selibs.ps1")

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

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $parent = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 20) + "`n"),
        $script:Utf8NoBom
    )
}

function New-TestPackageRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogRoot,

        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string[]]$Folders,

        [Parameter(Mandatory = $true)]
        [hashtable]$Dependencies,

        [string]$FileText = "// test source"
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $releaseRoot = Join-Path $CatalogRoot "$Id\$Version"
    $archiveInput = Join-Path $releaseRoot "archive"
    $archiveLibraries = Join-Path $archiveInput "Libraries"

    foreach ($folder in $Folders) {
        $folderPath = Join-Path $archiveLibraries $folder
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null

        [System.IO.File]::WriteAllText(
            (Join-Path $folderPath "$folder.cs"),
            "$FileText`n",
            $script:Utf8NoBom
        )
    }

    $componentName = "$Id-$Version-component.zip"
    $componentPath = Join-Path $releaseRoot $componentName

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $archiveInput,
        $componentPath
    )

    $hash = (
        Get-FileHash `
            -LiteralPath $componentPath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $dependencyObject = [ordered]@{}

    foreach ($dependencyId in @($Dependencies.Keys | Sort-Object)) {
        $dependencyObject[$dependencyId] = $Dependencies[$dependencyId]
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        id = $Id
        version = $Version
        dependencies = $dependencyObject
        folders = $Folders
        component = [ordered]@{
            asset = $componentName
            sha256 = $hash
        }
    }

    Write-TestJson `
        -Path (Join-Path $releaseRoot "$Id-$Version-package.json") `
        -Value $manifest

    Remove-Item -LiteralPath $archiveInput -Recurse -Force

    return $releaseRoot
}

$testRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("selibs-package-tests-" + [Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $catalog = Join-Path $testRoot "catalog"

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Dependency" `
        -Version "1.0.0" `
        -Folders @("Test.Dependency") `
        -Dependencies @{} `
        -FileText "// dependency" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Dependency" `
        -Version "2.0.0" `
        -Folders @("Test.Dependency") `
        -Dependencies @{} `
        -FileText "// dependency v2" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Root" `
        -Version "2.0.0" `
        -Folders @("Test.Root.Core", "Test.Root.Game") `
        -Dependencies @{
            "Test.Dependency" = "1.0.0"
        } `
        -FileText "// root" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Root" `
        -Version "3.0.0" `
        -Folders @("Test.Root.Core", "Test.Root.Game") `
        -Dependencies @{
            "Test.Dependency" = "2.0.0"
        } `
        -FileText "// root v3" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Second" `
        -Version "1.0.0" `
        -Folders @("Test.Second") `
        -Dependencies @{
            "Test.Dependency" = "1.0.0"
        } `
        -FileText "// second" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.BadHash" `
        -Version "1.0.0" `
        -Folders @("Test.BadHash") `
        -Dependencies @{} |
        Out-Null

    $badManifestPath = Join-Path `
        $catalog `
        "Test.BadHash\1.0.0\Test.BadHash-1.0.0-package.json"

    $badManifest = Get-Content -LiteralPath $badManifestPath -Raw |
        ConvertFrom-Json

    $badManifest.component.sha256 = "0" * 64
    Write-TestJson -Path $badManifestPath -Value $badManifest

    $registryPath = Join-Path $testRoot "registry.json"

    Write-TestJson `
        -Path $registryPath `
        -Value ([ordered]@{
            schemaVersion = 1
            packages = [ordered]@{
                "Test.Dependency" = [ordered]@{
                    provider = "filesystem"
                    location = (Join-Path $catalog "Test.Dependency")
                }
                "Test.Root" = [ordered]@{
                    provider = "filesystem"
                    location = (Join-Path $catalog "Test.Root")
                }
                "Test.Second" = [ordered]@{
                    provider = "filesystem"
                    location = (Join-Path $catalog "Test.Second")
                }
                "Test.BadHash" = [ordered]@{
                    provider = "filesystem"
                    location = (Join-Path $catalog "Test.BadHash")
                }
            }
        })

    $modRoot = Join-Path $testRoot "PackageMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $modRoot "Data\Scripts\PackageMod") `
        -Force |
        Out-Null

    Push-Location $modRoot

    try {
        & (Join-Path $repoRoot "selibs.cmd") init | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "SELibs init failed with exit code $LASTEXITCODE."
        }

        $output = @(
            & (Join-Path $repoRoot "selibs.cmd") `
                add `
                "Test.Root@2.0.0" `
                -RegistryUrl $registryPath
        )

        if ($LASTEXITCODE -ne 0) {
            throw "SELibs add failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    Assert-True `
        -Condition ($output -contains "Added Test.Root 2.0.0.") `
        -Message "The add command did not report the direct package."

    Assert-True `
        -Condition (
            $output -contains "Installed dependency Test.Dependency 1.0.0."
        ) `
        -Message "The add command did not report the dependency."

    $libraries = Join-Path `
        $modRoot `
        "Data\Scripts\PackageMod\Libraries"

    foreach ($folder in @(
        "Test.Dependency",
        "Test.Root.Core",
        "Test.Root.Game"
    )) {
        Assert-True `
            -Condition (Test-Path -LiteralPath (
                Join-Path $libraries $folder
            ) -PathType Container) `
            -Message "Expected installed folder '$folder'."
    }

    Assert-Equal `
        -Expected "// dependency`n" `
        -Actual ([System.IO.File]::ReadAllText(
            (Join-Path $libraries "Test.Dependency\Test.Dependency.cs")
        )) `
        -Message "Dependency source content was not installed."

    $manifest = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$manifest.dependencies."Test.Root") `
        -Message "Direct dependency was not written to selibs.json."

    $lock = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 2 `
        -Actual @($lock.packages.PSObject.Properties).Count `
        -Message "Lock file did not contain the complete dependency graph."

    Assert-True `
        -Condition ([bool]$lock.packages."Test.Root".direct) `
        -Message "Root package was not marked direct."

    Assert-True `
        -Condition (-not [bool]$lock.packages."Test.Dependency".direct) `
        -Message "Dependency was incorrectly marked direct."

    Assert-Equal `
        -Expected "1.0.0" `
        -Actual (
            [string]$lock.packages."Test.Root".dependencies."Test.Dependency"
        ) `
        -Message "Locked dependency edge is incorrect."

    Assert-True `
        -Condition (
            @(
                $lock.packages."Test.Root".files.PSObject.Properties
            ).Count -eq 2
        ) `
        -Message "Owned root-package files were not recorded."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (
            Join-Path $modRoot ".selibs\tmp"
        ))) `
        -Message "Transaction files were not cleaned."

    $secondOutput = @(
        Invoke-SELibsAdd `
            -ModRoot $modRoot `
            -PackageSpec "Test.Second@1.0.0" `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition ($secondOutput -contains "Added Test.Second 1.0.0.") `
        -Message "The second direct package was not reported."

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $libraries "Test.Second"
        ) -PathType Container) `
        -Message "The second direct package was not installed."

    $manifest = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 2 `
        -Actual @($manifest.dependencies.PSObject.Properties).Count `
        -Message "The manifest did not retain both direct packages."

    $lock = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 3 `
        -Actual @($lock.packages.PSObject.Properties).Count `
        -Message "The reconciled lock did not contain three packages."

    $removeRootOutput = @(
        Invoke-SELibsRemove `
            -ModRoot $modRoot `
            -PackageId "Test.Root"
    )

    Assert-True `
        -Condition ($removeRootOutput -contains "Removed Test.Root 2.0.0.") `
        -Message "Removing the first direct package was not reported."

    foreach ($folder in @("Test.Root.Core", "Test.Root.Game")) {
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath (
                Join-Path $libraries $folder
            ))) `
            -Message "Removed package folder '$folder' remains installed."
    }

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $libraries "Test.Dependency"
        ) -PathType Container) `
        -Message "A still-required shared dependency was removed."

    Assert-True `
        -Condition (Test-Path -LiteralPath (
            Join-Path $libraries "Test.Second"
        ) -PathType Container) `
        -Message "The remaining direct package was removed."

    $lockAfterFirstRemove = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 2 `
        -Actual @($lockAfterFirstRemove.packages.PSObject.Properties).Count `
        -Message "The first removal produced the wrong lock graph."

    $removeSecondOutput = @(
        Invoke-SELibsRemove `
            -ModRoot $modRoot `
            -PackageId "Test.Second"
    )

    Assert-True `
        -Condition (
            $removeSecondOutput -contains "Removed Test.Second 1.0.0."
        ) `
        -Message "Removing the final direct package was not reported."

    Assert-True `
        -Condition (
            $removeSecondOutput -contains (
                "Removed unused dependency Test.Dependency 1.0.0."
            )
        ) `
        -Message "The orphaned dependency was not reported."

    foreach ($folder in @("Test.Second", "Test.Dependency")) {
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath (
                Join-Path $libraries $folder
            ))) `
            -Message "Orphaned folder '$folder' remains installed."
    }

    $emptyManifest = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 0 `
        -Actual @($emptyManifest.dependencies.PSObject.Properties).Count `
        -Message "The final direct dependency was not removed."

    $emptyLock = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 0 `
        -Actual @($emptyLock.packages.PSObject.Properties).Count `
        -Message "Unused packages remain in the lock."

    $updateRoot = Join-Path $testRoot "UpdateMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $updateRoot "Data\Scripts\UpdateMod") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $updateRoot | Out-Null

    Invoke-SELibsAdd `
        -ModRoot $updateRoot `
        -PackageSpec "Test.Root@2.0.0" `
        -RegistryUrl $registryPath |
        Out-Null

    $updateOutput = @(
        Invoke-SELibsUpdate `
            -ModRoot $updateRoot `
            -PackageSpec "Test.Root" `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition (
            $updateOutput -contains "Updated Test.Root 2.0.0 -> 3.0.0."
        ) `
        -Message "Updating to the latest stable release was not reported."

    $updatedLibraries = Join-Path `
        $updateRoot `
        "Data\Scripts\UpdateMod\Libraries"

    Assert-Equal `
        -Expected "// root v3`n" `
        -Actual ([System.IO.File]::ReadAllText(
            (Join-Path $updatedLibraries "Test.Root.Core\Test.Root.Core.cs")
        )) `
        -Message "The root package source was not updated."

    Assert-Equal `
        -Expected "// dependency v2`n" `
        -Actual ([System.IO.File]::ReadAllText(
            (Join-Path `
                $updatedLibraries `
                "Test.Dependency\Test.Dependency.cs")
        )) `
        -Message "The transitive dependency source was not updated."

    $updatedManifest = Get-Content `
        -LiteralPath (Join-Path $updateRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "3.0.0" `
        -Actual ([string]$updatedManifest.dependencies."Test.Root") `
        -Message "The updated direct version was not written to the manifest."

    $updatedLock = Get-Content `
        -LiteralPath (Join-Path $updateRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "3.0.0" `
        -Actual ([string]$updatedLock.packages."Test.Root".version) `
        -Message "The updated root version was not locked."

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$updatedLock.packages."Test.Dependency".version) `
        -Message "The updated dependency version was not locked."

    $updateModifiedRoot = Join-Path $testRoot "UpdateModifiedMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path `
            $updateModifiedRoot `
            "Data\Scripts\UpdateModifiedMod") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $updateModifiedRoot | Out-Null

    Invoke-SELibsAdd `
        -ModRoot $updateModifiedRoot `
        -PackageSpec "Test.Root@2.0.0" `
        -RegistryUrl $registryPath |
        Out-Null

    $updateModifiedFile = Join-Path `
        $updateModifiedRoot `
        "Data\Scripts\UpdateModifiedMod\Libraries\Test.Root.Core\Test.Root.Core.cs"

    [System.IO.File]::AppendAllText(
        $updateModifiedFile,
        "// local update edit`n",
        $script:Utf8NoBom
    )

    Assert-Throws `
        -Action {
            Invoke-SELibsUpdate `
                -ModRoot $updateModifiedRoot `
                -PackageSpec "Test.Root@3.0.0" `
                -RegistryUrl $registryPath |
                Out-Null
        } `
        -ExpectedMessagePart "has modified file"

    $unchangedUpdateManifest = Get-Content `
        -LiteralPath (Join-Path $updateModifiedRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual (
            [string]$unchangedUpdateManifest.dependencies."Test.Root"
        ) `
        -Message "A rejected update changed the manifest version."

    Assert-True `
        -Condition (
            [System.IO.File]::ReadAllText($updateModifiedFile) -like
            "*// local update edit*"
        ) `
        -Message "A rejected update lost the local source modification."

    $badRoot = Join-Path $testRoot "BadHashMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $badRoot "Data\Scripts\BadHashMod") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $badRoot | Out-Null

    Assert-Throws `
        -Action {
            Invoke-SELibsAdd `
                -ModRoot $badRoot `
                -PackageSpec "Test.BadHash@1.0.0" `
                -RegistryUrl $registryPath |
                Out-Null
        } `
        -ExpectedMessagePart "checksum mismatch"

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (
            Join-Path `
                $badRoot `
                "Data\Scripts\BadHashMod\Libraries\Test.BadHash"
        ))) `
        -Message "A failed checksum left package files installed."

    $badResultManifest = Get-Content `
        -LiteralPath (Join-Path $badRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected 0 `
        -Actual @($badResultManifest.dependencies.PSObject.Properties).Count `
        -Message "A failed add changed the project manifest."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (
            Join-Path $badRoot "selibs.lock.json"
        ))) `
        -Message "A failed add created a lock file."

    Assert-Throws `
        -Action {
            Invoke-SELibsAdd `
                -ModRoot $badRoot `
                -PackageSpec "Missing.Package@1.0.0" `
                -RegistryUrl $registryPath |
                Out-Null
        } `
        -ExpectedMessagePart "Package 'Missing.Package' was not found"

    $modifiedRoot = Join-Path $testRoot "ModifiedMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $modifiedRoot "Data\Scripts\ModifiedMod") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $modifiedRoot | Out-Null

    Invoke-SELibsAdd `
        -ModRoot $modifiedRoot `
        -PackageSpec "Test.Dependency@1.0.0" `
        -RegistryUrl $registryPath |
        Out-Null

    $modifiedFile = Join-Path `
        $modifiedRoot `
        "Data\Scripts\ModifiedMod\Libraries\Test.Dependency\Test.Dependency.cs"

    [System.IO.File]::AppendAllText(
        $modifiedFile,
        "// local edit`n",
        $script:Utf8NoBom
    )

    Assert-Throws `
        -Action {
            Invoke-SELibsRemove `
                -ModRoot $modifiedRoot `
                -PackageId "Test.Dependency" |
                Out-Null
        } `
        -ExpectedMessagePart "has modified file"

    Assert-True `
        -Condition (Test-Path -LiteralPath $modifiedFile -PathType Leaf) `
        -Message "A failed safe removal deleted the modified file."

    $modifiedManifest = Get-Content `
        -LiteralPath (Join-Path $modifiedRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "1.0.0" `
        -Actual ([string]$modifiedManifest.dependencies."Test.Dependency") `
        -Message "A failed safe removal changed the manifest."

    Write-Output (
        "OK SELibs package tests passed: " +
        "$script:Passed assertions"
    )
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
