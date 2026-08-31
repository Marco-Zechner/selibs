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

$byteJson = [System.Text.Encoding]::UTF8.GetBytes(
    '{"schemaVersion":1,"id":"Byte.Package"}'
)

$byteJsonResult = ConvertFrom-SELibsJsonContent `
    -Content $byteJson `
    -Source "byte-content-test"

Assert-Equal `
    -Expected 1 `
    -Actual $byteJsonResult.schemaVersion `
    -Message "Byte-backed JSON should preserve schemaVersion."

Assert-Equal `
    -Expected "Byte.Package" `
    -Actual $byteJsonResult.id `
    -Message "Byte-backed JSON should decode as UTF-8."

$originalProgressPreference = $ProgressPreference
$ProgressPreference = "Continue"

$observedProgressPreference = Invoke-SELibsWithoutProgress -Action {
    return $ProgressPreference
}

Assert-Equal `
    -Expected "SilentlyContinue" `
    -Actual $observedProgressPreference `
    -Message "Web operations did not suppress transient progress output."

Assert-Equal `
    -Expected "Continue" `
    -Actual $ProgressPreference `
    -Message "The progress preference was not restored."

$ProgressPreference = $originalProgressPreference
$originalGitHubApi = ${function:Invoke-SELibsGitHubApi}

try {
    Set-Item `
        -Path Function:\Invoke-SELibsGitHubApi `
        -Value {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Uri
            )

            return ,@(
                [pscustomobject]@{
                    tag_name = "other/v9.0.0"
                    draft = $false
                    prerelease = $false
                    assets = @()
                }
                [pscustomobject]@{
                    tag_name = "test/v1.0.0"
                    draft = $false
                    prerelease = $false
                    assets = @(
                        [pscustomobject]@{
                            name = "Test.Package-1.0.0-package.json"
                            browser_download_url = "https://example/1.0.0.json"
                        }
                    )
                }
                [pscustomobject]@{
                    tag_name = "test/v2.0.0"
                    draft = $false
                    prerelease = $false
                    assets = @(
                        [pscustomobject]@{
                            name = "Test.Package-2.0.0-package.json"
                            browser_download_url = "https://example/2.0.0.json"
                        }
                    )
                }
                [pscustomobject]@{
                    tag_name = "test/v3.0.0"
                    draft = $false
                    prerelease = $true
                    assets = @()
                }
            )
        }

    $nestedRelease = Get-SELibsGitHubRelease `
        -PackageId "Test.Package" `
        -Route ([pscustomobject]@{
            repository = "owner/repository"
            releasePrefix = "test/v"
        })

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$nestedRelease.Version) `
        -Message (
            "GitHub release discovery did not flatten a nested " +
            "Windows PowerShell response."
        )

    Assert-Equal `
        -Expected "https://example/2.0.0.json" `
        -Actual ([string]$nestedRelease.ManifestSource) `
        -Message "GitHub release discovery selected the wrong manifest."
}
finally {
    Set-Item `
        -Path Function:\Invoke-SELibsGitHubApi `
        -Value $originalGitHubApi
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

        [object[]]$Changelog,

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

    $changelogEntries = if ($null -eq $Changelog) {
        @(
            [ordered]@{
                version = $Version
                changes = @(
                    "Published test release $Version."
                )
            }
        )
    }
    else {
        @($Changelog)
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        id = $Id
        version = $Version
        changelog = $changelogEntries
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
    $discoveryRegistryPath = Join-Path $testRoot "registry-v2.json"

    Write-TestJson `
        -Path $discoveryRegistryPath `
        -Value ([ordered]@{
            schemaVersion = 2
            repositories = @(
                [ordered]@{
                    provider = "github"
                    repository = "owner/discovery"
                }
            )
        })

    $script:DiscoveryApiUris = New-Object System.Collections.ArrayList

    try {
        Set-Item `
            -Path Function:\Invoke-SELibsGitHubApi `
            -Value {
                param(
                    [Parameter(Mandatory = $true)]
                    [string]$Uri
                )

                [void]$script:DiscoveryApiUris.Add($Uri)

                if ($Uri -eq "https://api.github.com/repos/owner/discovery/releases?per_page=100&page=1") {
                    $page = New-Object System.Collections.ArrayList

                    [void]$page.Add([pscustomobject]@{
                        tag_name = "release/Test.One/1.0.0"
                        draft = $false
                        prerelease = $false
                        assets = @(
                            [pscustomobject]@{
                                name = "Test.One-1.0.0-package.json"
                                browser_download_url = "https://example/Test.One-1.0.0.json"
                            }
                        )
                    })

                    [void]$page.Add([pscustomobject]@{
                        tag_name = "release/Test.Other/1.5.0"
                        draft = $false
                        prerelease = $false
                        assets = @(
                            [pscustomobject]@{
                                name = "Test.Other-1.5.0-package.json"
                                browser_download_url = "https://example/Test.Other-1.5.0.json"
                            }
                        )
                    })

                    [void]$page.Add([pscustomobject]@{
                        tag_name = "release/Test.Hidden/9.0.0"
                        draft = $false
                        prerelease = $true
                        assets = @()
                    })

                    [void]$page.Add([pscustomobject]@{
                        tag_name = "release/Test.Draft/9.0.0"
                        draft = $true
                        prerelease = $false
                        assets = @()
                    })

                    [void]$page.Add([pscustomobject]@{
                        tag_name = "release/Test.NoManifest/1.0.0"
                        draft = $false
                        prerelease = $false
                        assets = @()
                    })

                    for ($index = 0; $index -lt 95; $index++) {
                        [void]$page.Add([pscustomobject]@{
                            tag_name = "unrelated/$index"
                            draft = $false
                            prerelease = $false
                            assets = @()
                        })
                    }

                    return ,@($page)
                }

                if ($Uri -eq "https://api.github.com/repos/owner/discovery/releases?per_page=100&page=2") {
                    return ,@(
                        [pscustomobject]@{
                            tag_name = "release/Test.PageTwo/2.0.0"
                            draft = $false
                            prerelease = $false
                            assets = @(
                                [pscustomobject]@{
                                    name = "Test.PageTwo-2.0.0-package.json"
                                    browser_download_url = "https://example/Test.PageTwo-2.0.0.json"
                                }
                            )
                        }
                    )
                }

                if ($Uri -eq "https://api.github.com/repos/owner/first/releases?per_page=100&page=1") {
                    return ,@(
                        [pscustomobject]@{
                            tag_name = "release/Test.Duplicate/1.0.0"
                            draft = $false
                            prerelease = $false
                            assets = @(
                                [pscustomobject]@{
                                    name = "Test.Duplicate-1.0.0-package.json"
                                    browser_download_url = "https://example/Test.Duplicate-1.0.0.json"
                                }
                            )
                        }
                    )
                }

                if ($Uri -eq "https://api.github.com/repos/owner/second/releases?per_page=100&page=1") {
                    return ,@(
                        [pscustomobject]@{
                            tag_name = "release/test.duplicate/2.0.0"
                            draft = $false
                            prerelease = $false
                            assets = @(
                                [pscustomobject]@{
                                    name = "test.duplicate-2.0.0-package.json"
                                    browser_download_url = "https://example/test.duplicate-2.0.0.json"
                                }
                            )
                        }
                    )
                }

                throw "Unexpected GitHub test URI '$Uri'."
            }

        $discoveredRegistry = Read-SELibsRegistry `
            -RegistryUrl $discoveryRegistryPath

        Assert-Equal `
            -Expected 2 `
            -Actual $discoveredRegistry.Value.schemaVersion `
            -Message "Repository registry did not preserve schema version 2."

        Assert-Equal `
            -Expected 3 `
            -Actual @(
                $discoveredRegistry.Value.packages.PSObject.Properties
            ).Count `
            -Message "Repository discovery produced the wrong package count."

        $oneRoute = Get-SELibsPackageRoute `
            -Registry $discoveredRegistry `
            -PackageId "test.one"

        Assert-Equal `
            -Expected "github" `
            -Actual ([string]$oneRoute.provider) `
            -Message "Discovered route uses the wrong provider."

        Assert-Equal `
            -Expected "owner/discovery" `
            -Actual ([string]$oneRoute.repository) `
            -Message "Discovered route uses the wrong repository."

        Assert-Equal `
            -Expected "release/Test.One/" `
            -Actual ([string]$oneRoute.releasePrefix) `
            -Message "Discovered route uses the wrong release prefix."

        $pageTwoRoute = Get-SELibsPackageRoute `
            -Registry $discoveredRegistry `
            -PackageId "Test.PageTwo"

        Assert-Equal `
            -Expected "owner/discovery" `
            -Actual ([string]$pageTwoRoute.repository) `
            -Message "Repository discovery did not read the second release page."

        $latestOne = Get-SELibsGitHubRelease `
            -PackageId "Test.One" `
            -Route $oneRoute

        Assert-Equal `
            -Expected "1.0.0" `
            -Actual ([string]$latestOne.Version) `
            -Message "Cached discovery releases selected the wrong package version."

        Assert-Equal `
            -Expected "https://example/Test.One-1.0.0.json" `
            -Actual ([string]$latestOne.ManifestSource) `
            -Message "Cached discovery releases selected the wrong manifest."

        Assert-Equal `
            -Expected 2 `
            -Actual $script:DiscoveryApiUris.Count `
            -Message "Latest resolution queried a repository already cached by discovery."

        $collisionRegistryPath = Join-Path $testRoot "registry-v2-collision.json"

        Write-TestJson `
            -Path $collisionRegistryPath `
            -Value ([ordered]@{
                schemaVersion = 2
                repositories = @(
                    [ordered]@{
                        provider = "github"
                        repository = "owner/first"
                    }
                    [ordered]@{
                        provider = "github"
                        repository = "owner/second"
                    }
                )
            })

        Assert-Throws `
            -Action {
                Read-SELibsRegistry `
                    -RegistryUrl $collisionRegistryPath |
                    Out-Null
            } `
            -ExpectedMessagePart "discovered from more than one repository"
    }
    finally {
        Set-Item `
            -Path Function:\Invoke-SELibsGitHubApi `
            -Value $originalGitHubApi
    }

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
        -Changelog @(
            [ordered]@{
                version = "3.0.0"
                changes = @(
                    "Improved root package."
                    "Updated dependency integration."
                )
            }
            [ordered]@{
                version = "2.0.0"
                changes = @(
                    "Published the root package."
                )
            }
        ) `
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
        -Id "Test.Second" `
        -Version "2.0.0" `
        -Folders @("Test.Second") `
        -Dependencies @{
            "Test.Dependency" = "2.0.0"
        } `
        -FileText "// second v2" |
        Out-Null

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Conflict" `
        -Version "1.0.0" `
        -Folders @("Test.Conflict") `
        -Dependencies @{
            "Test.Dependency" = "2.0.0"
        } `
        -FileText "// conflict" |
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
                "Test.Conflict" = [ordered]@{
                    provider = "filesystem"
                    location = (Join-Path $catalog "Test.Conflict")
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

    $statusOutput = @(
        & (Join-Path $repoRoot "selibs.ps1") `
            status `
            -ModRoot $modRoot `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition (
            $statusOutput -contains (
                "  Test.Dependency  transitive  1.0.0      " +
                "2.0.0   update available"
            )
        ) `
        -Message "Status did not report the aligned transitive package."

    Assert-True `
        -Condition (
            $statusOutput -contains (
                "  Test.Root        direct      2.0.0      " +
                "3.0.0   update available"
            )
        ) `
        -Message "Status did not report the aligned direct package."

    Assert-True `
        -Condition (
            $statusOutput -contains (
                "  ---------------  ----------  ---------  " +
                "------  ----------------"
            )
        ) `
        -Message "Status did not render an aligned table separator."

    Assert-True `
        -Condition (
            $statusOutput -contains (
                "Summary: 2 packages installed; " +
                "2 updates available; 0 modified."
            )
        ) `
        -Message "Status produced the wrong initial summary."

    $listOutput = @(
        Invoke-SELibsList -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition (
            $listOutput -contains (
                "  Package          Latest  Provider"
            )
        ) `
        -Message "List did not render the aligned package header."

    Assert-True `
        -Condition (
            $listOutput -contains (
                "  ---------------  ------  ----------"
            )
        ) `
        -Message "List did not render the aligned table separator."

    Assert-True `
        -Condition (
            $listOutput -contains (
                "  Test.Dependency  2.0.0   filesystem"
            )
        ) `
        -Message "List did not report the newest dependency release."

    Assert-True `
        -Condition (
            $listOutput -contains (
                "  Test.Root        3.0.0   filesystem"
            )
        ) `
        -Message "List did not report the newest root release."

    Assert-True `
        -Condition (
            $listOutput -contains (
                "Summary: 5 packages found; 0 unavailable."
            )
        ) `
        -Message "List produced the wrong package summary."

    $changelogOutput = @(
        & (Join-Path $repoRoot "selibs.ps1") `
            changelog `
            "Test.Root" `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition ($changelogOutput -contains "Package: Test.Root") `
        -Message "Changelog did not report the package ID."

    Assert-True `
        -Condition (
            $changelogOutput -contains "Selected release: 3.0.0"
        ) `
        -Message "Changelog did not select the newest stable release."

    Assert-True `
        -Condition (
            $changelogOutput -contains "    - Improved root package."
        ) `
        -Message "Changelog did not print current changes."

    Assert-True `
        -Condition (
            $changelogOutput -contains "    - Published the root package."
        ) `
        -Message "Changelog did not print previous changes."

    $latestIndex = [Array]::IndexOf($changelogOutput, "  3.0.0")
    $previousIndex = [Array]::IndexOf($changelogOutput, "  2.0.0")

    Assert-True `
        -Condition (
            $latestIndex -ge 0 -and
            $previousIndex -gt $latestIndex
        ) `
        -Message "Changelog was not printed newest first."

    $exactChangelogOutput = @(
        & (Join-Path $repoRoot "selibs.ps1") `
            changelog `
            "Test.Root@2.0.0" `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition (
            $exactChangelogOutput -contains "Selected release: 2.0.0"
        ) `
        -Message "Exact changelog selection used the wrong release."

    Assert-Equal `
        -Expected 0 `
        -Actual @(
            ConvertTo-SELibsPackageChangelog `
                -PackageId "Test.Legacy" `
                -PackageVersion "1.0.0" `
                -Value $null
        ).Count `
        -Message "A missing legacy changelog was rejected."

    Assert-Throws `
        -Action {
            ConvertTo-SELibsPackageChangelog `
                -PackageId "Test.Invalid" `
                -PackageVersion "1.0.0" `
                -Value @(
                    [pscustomobject]@{
                        version = "0.9.0"
                        changes = @("Older.")
                    }
                    [pscustomobject]@{
                        version = "1.0.0"
                        changes = @("Newer.")
                    }
                ) |
                Out-Null
        } `
        -ExpectedMessagePart "newest to oldest"

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

    $conflictMessage = $null

    try {
        Invoke-SELibsAdd `
            -ModRoot $modRoot `
            -PackageSpec "Test.Conflict@1.0.0" `
            -RegistryUrl $registryPath |
            Out-Null
    }
    catch {
        $conflictMessage = $_.Exception.Message
    }

    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace($conflictMessage)) `
        -Message "An incompatible exact dependency graph was accepted."

    Assert-True `
        -Condition (
            $conflictMessage -like
            "*Test.Root@2.0.0 -> Test.Dependency@1.0.0*"
        ) `
        -Message "The Test.Root dependency requirement path was not reported."

    Assert-True `
        -Condition (
            $conflictMessage -like
            "*Test.Conflict@1.0.0 -> Test.Dependency@2.0.0*"
        ) `
        -Message "The Test.Conflict requirement path was not reported."

    Assert-True `
        -Condition (
            $conflictMessage -like
            "*one exact version of each package per mod*"
        ) `
        -Message "The exact-version conflict policy was not explained."

    $manifestAfterConflict = Get-Content `
        -LiteralPath (Join-Path $modRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-True `
        -Condition (
            $null -eq (
                Get-SELibsObjectProperty `
                    -Object $manifestAfterConflict.dependencies `
                    -Name "Test.Conflict"
            )
        ) `
        -Message "A rejected dependency conflict changed the manifest."
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

    $updateAllRoot = Join-Path $testRoot "UpdateAllMod"

    New-Item `
        -ItemType Directory `
        -Path (Join-Path $updateAllRoot "Data\Scripts\UpdateAllMod") `
        -Force |
        Out-Null

    Invoke-SELibsInit -ModRoot $updateAllRoot | Out-Null

    Invoke-SELibsAdd `
        -ModRoot $updateAllRoot `
        -PackageSpec "Test.Root@2.0.0" `
        -RegistryUrl $registryPath |
        Out-Null

    Invoke-SELibsAdd `
        -ModRoot $updateAllRoot `
        -PackageSpec "Test.Second@1.0.0" `
        -RegistryUrl $registryPath |
        Out-Null

    Set-Item `
        -Path Function:\global:Read-Host `
        -Value {
            param([string]$Prompt)
            return "n"
        }

    try {
        $cancelledUpdateOutput = @(
            & (Join-Path $repoRoot "selibs.ps1") `
                update `
                -ModRoot $updateAllRoot `
                -RegistryUrl $registryPath
        )
    }
    finally {
        Remove-Item `
            -Path Function:\global:Read-Host `
            -ErrorAction SilentlyContinue
    }

    Assert-True `
        -Condition (
            $cancelledUpdateOutput -contains "Planned package changes:"
        ) `
        -Message "Update-all did not display its change plan."

    Assert-True `
        -Condition (
            $cancelledUpdateOutput -contains (
                "  Update direct Test.Root 2.0.0 -> 3.0.0"
            )
        ) `
        -Message "The Test.Root update was absent from the plan."

    Assert-True `
        -Condition (
            $cancelledUpdateOutput -contains (
                "  Update direct Test.Second 1.0.0 -> 2.0.0"
            )
        ) `
        -Message "The Test.Second update was absent from the plan."

    Assert-True `
        -Condition (
            $cancelledUpdateOutput -contains "Update cancelled."
        ) `
        -Message "Update-all cancellation was not reported."

    $cancelledManifest = Get-Content `
        -LiteralPath (Join-Path $updateAllRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$cancelledManifest.dependencies."Test.Root") `
        -Message "A cancelled update changed Test.Root."

    Assert-Equal `
        -Expected "1.0.0" `
        -Actual ([string]$cancelledManifest.dependencies."Test.Second") `
        -Message "A cancelled update changed Test.Second."

    Set-Item `
        -Path Function:\global:Read-Host `
        -Value {
            param([string]$Prompt)
            return "yes"
        }

    try {
        $updateAllOutput = @(
            & (Join-Path $repoRoot "selibs.ps1") `
                update `
                -ModRoot $updateAllRoot `
                -RegistryUrl $registryPath
        )
    }
    finally {
        Remove-Item `
            -Path Function:\global:Read-Host `
            -ErrorAction SilentlyContinue
    }

    Assert-True `
        -Condition (
            $updateAllOutput -contains "Updated Test.Root 2.0.0 -> 3.0.0."
        ) `
        -Message "Update-all did not update Test.Root."

    Assert-True `
        -Condition (
            $updateAllOutput -contains "Updated Test.Second 1.0.0 -> 2.0.0."
        ) `
        -Message "Update-all did not update Test.Second."

    Assert-True `
        -Condition (
            $updateAllOutput -contains (
                "Updated dependency Test.Dependency 1.0.0 -> 2.0.0."
            )
        ) `
        -Message "Update-all did not reconcile the shared dependency."

    $updateAllManifest = Get-Content `
        -LiteralPath (Join-Path $updateAllRoot "selibs.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "3.0.0" `
        -Actual ([string]$updateAllManifest.dependencies."Test.Root") `
        -Message "Update-all did not persist Test.Root."

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$updateAllManifest.dependencies."Test.Second") `
        -Message "Update-all did not persist Test.Second."

    $updateAllLock = Get-Content `
        -LiteralPath (Join-Path $updateAllRoot "selibs.lock.json") `
        -Raw |
        ConvertFrom-Json

    Assert-Equal `
        -Expected "2.0.0" `
        -Actual ([string]$updateAllLock.packages."Test.Dependency".version) `
        -Message "Update-all locked the wrong shared dependency version."
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

    $missingStatusFile = Join-Path `
        $updateModifiedRoot `
        "Data\Scripts\UpdateModifiedMod\Libraries\Test.Root.Game\Test.Root.Game.cs"

    Remove-Item -LiteralPath $missingStatusFile

    $addedStatusFile = Join-Path `
        $updateModifiedRoot `
        "Data\Scripts\UpdateModifiedMod\Libraries\Test.Root.Core\LocalOnly.cs"

    [System.IO.File]::WriteAllText(
        $addedStatusFile,
        "// local-only file`n",
        $script:Utf8NoBom
    )

    $modifiedStatusOutput = @(
        Invoke-SELibsStatus `
            -ModRoot $updateModifiedRoot `
            -RegistryUrl $registryPath
    )

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains (
                "  Test.Root        direct      2.0.0      " +
                "3.0.0   modified, update available"
            )
        ) `
        -Message "Status did not report an aligned modified package."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains (
                "Summary: 2 packages installed; " +
                "2 updates available; 1 modified."
            )
        ) `
        -Message "Status produced the wrong modified-package summary."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains "Managed package changes:"
        ) `
        -Message "Status did not introduce detailed managed-package changes."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains "  Test.Root:"
        ) `
        -Message "Status did not identify the package containing local changes."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains (
                "    added: Test.Root.Core/LocalOnly.cs"
            )
        ) `
        -Message "Status did not report the locally added managed file."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains (
                "    missing: Test.Root.Game/Test.Root.Game.cs"
            )
        ) `
        -Message "Status did not report the missing managed file."

    Assert-True `
        -Condition (
            $modifiedStatusOutput -contains (
                "    modified: Test.Root.Core/Test.Root.Core.cs"
            )
        ) `
        -Message "Status did not report the checksum-modified managed file."

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

    $repairLockPath = Join-Path $updateModifiedRoot "selibs.lock.json"
    $repairLockBefore = Get-Content -LiteralPath $repairLockPath -Raw

    Set-Item `
        -Path Function:\global:Read-Host `
        -Value {
            param([string]$Prompt)
            return "n"
        }

    try {
        $cancelledRepairOutput = @(
            Invoke-SELibsRepair `
                -ModRoot $updateModifiedRoot `
                -PackageId "Test.Root"
        )
    }
    finally {
        Remove-Item `
            -Path Function:\global:Read-Host `
            -ErrorAction SilentlyContinue
    }

    Assert-True `
        -Condition (
            $cancelledRepairOutput -contains "Planned package repairs:"
        ) `
        -Message "Repair did not display its change plan."

    Assert-True `
        -Condition (
            $cancelledRepairOutput -contains "  Restore Test.Root 2.0.0"
        ) `
        -Message "Repair did not identify the exact locked release."

    Assert-True `
        -Condition (
            $cancelledRepairOutput -contains "Repair cancelled."
        ) `
        -Message "Repair cancellation was not reported."

    $cancelledRepairDrift = Get-SELibsManagedPackageDrift `
        -LibrariesRoot (Join-Path `
            $updateModifiedRoot `
            "Data\Scripts\UpdateModifiedMod\Libraries") `
        -PackageId "Test.Root" `
        -LockEntry (
            (Get-Content -LiteralPath $repairLockPath -Raw |
                ConvertFrom-Json).packages."Test.Root"
        )

    Assert-True `
        -Condition ([bool]$cancelledRepairDrift.HasChanges) `
        -Message "Cancelled repair unexpectedly changed managed files."

    $repairOutput = @(
        Invoke-SELibsRepair `
            -ModRoot $updateModifiedRoot `
            -PackageId "Test.Root" `
            -Force
    )

    Assert-True `
        -Condition (
            $repairOutput -contains "Repaired Test.Root 2.0.0."
        ) `
        -Message "Selected repair did not report restored package version."

    Assert-Equal `
        -Expected "// root`n" `
        -Actual ([System.IO.File]::ReadAllText($updateModifiedFile)) `
        -Message "Selected repair did not restore the modified file."

    Assert-Equal `
        -Expected "// root`n" `
        -Actual ([System.IO.File]::ReadAllText($missingStatusFile)) `
        -Message "Selected repair did not restore the missing file."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $addedStatusFile)) `
        -Message "Selected repair did not remove the locally added file."

    Assert-Equal `
        -Expected $repairLockBefore `
        -Actual (Get-Content -LiteralPath $repairLockPath -Raw) `
        -Message "Repair unexpectedly rewrote selibs.lock.json."

    $repairedLock = Get-Content -LiteralPath $repairLockPath -Raw |
        ConvertFrom-Json

    $repairedDrift = Get-SELibsManagedPackageDrift `
        -LibrariesRoot (Join-Path `
            $updateModifiedRoot `
            "Data\Scripts\UpdateModifiedMod\Libraries") `
        -PackageId "Test.Root" `
        -LockEntry $repairedLock.packages."Test.Root"

    Assert-True `
        -Condition (-not [bool]$repairedDrift.HasChanges) `
        -Message "Selected repair did not restore the package to its lock."

    $dependencyRepairFile = Join-Path `
        $updateModifiedRoot `
        "Data\Scripts\UpdateModifiedMod\Libraries\Test.Dependency\Test.Dependency.cs"

    [System.IO.File]::AppendAllText(
        $dependencyRepairFile,
        "// local dependency edit`n",
        $script:Utf8NoBom
    )

    $repairAllOutput = @(
        Invoke-SELibsRepair `
            -ModRoot $updateModifiedRoot `
            -Force
    )

    Assert-True `
        -Condition (
            $repairAllOutput -contains "  Restore Test.Dependency 1.0.0"
        ) `
        -Message "Repair-all did not plan the drifted transitive package."

    Assert-True `
        -Condition (
            $repairAllOutput -contains "Repaired Test.Dependency 1.0.0."
        ) `
        -Message "Repair-all did not restore the drifted transitive package."

    Assert-Equal `
        -Expected "// dependency`n" `
        -Actual ([System.IO.File]::ReadAllText($dependencyRepairFile)) `
        -Message "Repair-all did not restore the transitive package source."

    Assert-Equal `
        -Expected $repairLockBefore `
        -Actual (Get-Content -LiteralPath $repairLockPath -Raw) `
        -Message "Repair-all unexpectedly rewrote selibs.lock.json."

    [System.IO.File]::AppendAllText(
        $dependencyRepairFile,
        "// local CLI repair edit`n",
        $script:Utf8NoBom
    )

    $cliRepairOutput = @(
        & (Join-Path $repoRoot "selibs.ps1") `
            repair `
            "Test.Dependency" `
            -ModRoot $updateModifiedRoot `
            -Force
    )

    Assert-True `
        -Condition (
            $cliRepairOutput -contains "Repaired Test.Dependency 1.0.0."
        ) `
        -Message "The CLI repair command did not restore the selected package."

    Assert-Equal `
        -Expected "// dependency`n" `
        -Actual ([System.IO.File]::ReadAllText($dependencyRepairFile)) `
        -Message "The CLI repair command did not restore package source."

    [System.IO.File]::AppendAllText(
        $dependencyRepairFile,
        "// local edit before mismatched repair`n",
        $script:Utf8NoBom
    )

    $dependencyReleaseRoot = Join-Path `
        $catalog `
        "Test.Dependency\1.0.0"

    Remove-Item `
        -LiteralPath $dependencyReleaseRoot `
        -Recurse `
        -Force

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Dependency" `
        -Version "1.0.0" `
        -Folders @("Test.Dependency") `
        -Dependencies @{} `
        -FileText "// republished dependency" |
        Out-Null

    Assert-Throws `
        -Action {
            Invoke-SELibsRepair `
                -ModRoot $updateModifiedRoot `
                -PackageId "Test.Dependency" `
                -Force |
                Out-Null
        } `
        -ExpectedMessagePart "does not match selibs.lock.json"

    Assert-True `
        -Condition (
            [System.IO.File]::ReadAllText($dependencyRepairFile) -like
            "*// local edit before mismatched repair*"
        ) `
        -Message "A rejected mismatched repair lost the local package edit."

    Assert-Equal `
        -Expected $repairLockBefore `
        -Actual (Get-Content -LiteralPath $repairLockPath -Raw) `
        -Message "A rejected mismatched repair rewrote selibs.lock.json."

    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (
            Join-Path $updateModifiedRoot ".selibs\tmp"
        ))) `
        -Message "A rejected mismatched repair left transaction files behind."

    Remove-Item `
        -LiteralPath $dependencyReleaseRoot `
        -Recurse `
        -Force

    New-TestPackageRelease `
        -CatalogRoot $catalog `
        -Id "Test.Dependency" `
        -Version "1.0.0" `
        -Folders @("Test.Dependency") `
        -Dependencies @{} `
        -FileText "// dependency" |
        Out-Null

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
