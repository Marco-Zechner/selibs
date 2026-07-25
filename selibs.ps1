[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "init", "add", "status", "update", "remove")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$PackageSpec,

    [string]$ModRoot = (Get-Location).Path,

    [string]$LibrariesPath,

    [string]$RegistryUrl,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SELibsRoot = Split-Path -Parent $PSCommandPath

function Write-SELibsUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Get-SELibsFullModRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($ModRoot)

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Mod root '$fullPath' does not exist."
    }

    return $fullPath.TrimEnd([char[]]"\/")
}

function ConvertTo-SELibsRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Libraries path '$candidate' must be inside mod root '$root'."
    }

    $relative = $candidate.Substring($rootPrefix.Length)

    if ([string]::IsNullOrWhiteSpace($relative)) {
        throw "Libraries path cannot be the mod root itself."
    }

    return $relative.Replace("\", "/")
}

function Resolve-SELibsLibrariesPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot,

        [string]$LibrariesPath
    )

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot

    if (-not [string]::IsNullOrWhiteSpace($LibrariesPath)) {
        if ([System.IO.Path]::IsPathRooted($LibrariesPath)) {
            $fullPath = [System.IO.Path]::GetFullPath($LibrariesPath)
        }
        else {
            $fullPath = [System.IO.Path]::GetFullPath(
                (Join-Path $root $LibrariesPath)
            )
        }
    }
    else {
        $scriptsRoot = Join-Path $root "Data\Scripts"
        $scriptFolders = @()

        if (Test-Path -LiteralPath $scriptsRoot -PathType Container) {
            $scriptFolders = @(
                Get-ChildItem -LiteralPath $scriptsRoot -Directory |
                    Sort-Object Name
            )
        }

        if ($scriptFolders.Count -eq 1) {
            $fullPath = Join-Path $scriptFolders[0].FullName "Libraries"
        }
        elseif ($scriptFolders.Count -eq 0) {
            $modName = Split-Path -Leaf $root

            if ([string]::IsNullOrWhiteSpace($modName)) {
                throw "Could not infer a script-folder name from '$root'."
            }

            $fullPath = Join-Path $scriptsRoot "$modName\Libraries"
        }
        else {
            $folderNames = (
                $scriptFolders |
                    ForEach-Object { $_.Name }
            ) -join ", "

            throw (
                "Several folders exist below Data\Scripts: $folderNames. " +
                "Specify -LibrariesPath explicitly."
            )
        }
    }

    $trimmedPath = $fullPath.TrimEnd([char[]]"\/")
    $leafName = [System.IO.Path]::GetFileName($trimmedPath)

    if ($leafName -ne "Libraries") {
        throw "Libraries path must end in a folder named 'Libraries'."
    }

    $relativePath = ConvertTo-SELibsRelativePath `
        -ModRoot $root `
        -Path $trimmedPath

    return [pscustomobject]@{
        FullPath = $trimmedPath
        RelativePath = $relativePath
    }
}

function Read-SELibsManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Could not read SELibs manifest '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $manifest.schemaVersion -or $manifest.schemaVersion -ne 1) {
        throw "Manifest '$Path' does not use supported schema version 1."
    }

    if ([string]::IsNullOrWhiteSpace([string]$manifest.librariesPath)) {
        throw "Manifest '$Path' does not define librariesPath."
    }

    if ($null -eq $manifest.dependencies) {
        throw "Manifest '$Path' does not define dependencies."
    }

    return $manifest
}

function Write-SELibsManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$LibrariesPath
    )

    $manifest = [ordered]@{
        schemaVersion = 1
        librariesPath = $LibrariesPath
        dependencies = [ordered]@{}
    }

    $json = $manifest | ConvertTo-Json -Depth 10
    Write-SELibsUtf8NoBom -Path $Path -Content ($json + "`n")
}

function Get-SELibsGitIgnoreRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot
    )

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot
    $gitIgnorePath = Join-Path $root ".gitignore"

    if (-not (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf)) {
        return @()
    }

    $existingEntries = @(
        Get-Content -LiteralPath $gitIgnorePath |
            ForEach-Object {
                $_.Trim().TrimStart("/")
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                -not $_.StartsWith("#")
            }
    )

    $recommendations = @()

    foreach ($entry in @("/.selibs/")) {
        $normalizedEntry = $entry.TrimStart("/")

        if ($existingEntries -notcontains $normalizedEntry) {
            $recommendations += $entry
        }
    }

    return $recommendations
}

function Show-SELibsGitIgnoreRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot
    )

    $recommendations = @(
        Get-SELibsGitIgnoreRecommendations -ModRoot $ModRoot
    )

    if ($recommendations.Count -eq 0) {
        return
    }

    Write-Output ""
    Write-Output ".gitignore found. Consider adding:"

    foreach ($entry in $recommendations) {
        Write-Output "  $entry"
    }
}

function Invoke-SELibsInit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot,

        [string]$LibrariesPath,

        [switch]$Force
    )

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot
    $manifestPath = Join-Path $root "selibs.json"
    $statePath = Join-Path $root ".selibs"

    if (
        (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
        -not $Force
    ) {
        if (-not [string]::IsNullOrWhiteSpace($LibrariesPath)) {
            throw (
                "The mod is already initialized. Use -Force to replace " +
                "the existing librariesPath."
            )
        }

        $manifest = Read-SELibsManifest -Path $manifestPath
        $resolved = Resolve-SELibsLibrariesPath `
            -ModRoot $root `
            -LibrariesPath ([string]$manifest.librariesPath)

        New-Item -ItemType Directory -Path $resolved.FullPath -Force |
            Out-Null

        New-Item -ItemType Directory -Path $statePath -Force |
            Out-Null

        Write-Output "SELibs is already initialized."
        Write-Output "Libraries: $($resolved.RelativePath)"
        Show-SELibsGitIgnoreRecommendations -ModRoot $root
        return
    }

    $resolved = Resolve-SELibsLibrariesPath `
        -ModRoot $root `
        -LibrariesPath $LibrariesPath

    New-Item -ItemType Directory -Path $resolved.FullPath -Force |
        Out-Null

    New-Item -ItemType Directory -Path $statePath -Force |
        Out-Null

    Write-SELibsManifest `
        -Path $manifestPath `
        -LibrariesPath $resolved.RelativePath

    Write-Output "Initialized SELibs."
    Write-Output "Manifest: selibs.json"
    Write-Output "Libraries: $($resolved.RelativePath)"
    Show-SELibsGitIgnoreRecommendations -ModRoot $root
}

. (Join-Path $script:SELibsRoot "lib\SELibs.Package.ps1")

function Show-SELibsHelp {
    Write-Output "SELibs - source-library manager for Space Engineers mods"
    Write-Output ""
    Write-Output "Usage:"
    Write-Output "  selibs init"
    Write-Output (
        "  selibs init -LibrariesPath " +
        '"Data/Scripts/MyMod/Libraries"'
    )
    Write-Output "  selibs add Mz.ApiProtocol@0.2.0"
    Write-Output "  selibs status"
    Write-Output "  selibs update Mz.ApiProtocol"
    Write-Output "  selibs update Mz.ApiProtocol@0.3.0"
    Write-Output "  selibs remove Mz.ApiProtocol"
    Write-Output ""
    Write-Output "Commands:"
    Write-Output "  init   Create selibs.json and the Libraries directory."
    Write-Output "  add     Add a direct library and reconcile dependencies."
    Write-Output "  status  Show installed, latest, and modified package state."
    Write-Output "  update  Update a direct library and its dependency graph."
    Write-Output "  remove  Remove a direct library and unused dependencies."
    Write-Output "  help    Show this help."
}

if ($MyInvocation.InvocationName -ne ".") {
    switch ($Command) {
        "init" {
            Invoke-SELibsInit `
                -ModRoot $ModRoot `
                -LibrariesPath $LibrariesPath `
                -Force:$Force
        }

        "add" {
            if ([string]::IsNullOrWhiteSpace($PackageSpec)) {
                throw "The add command requires a package ID or ID@version."
            }

            Invoke-SELibsAdd `
                -ModRoot $ModRoot `
                -PackageSpec $PackageSpec `
                -RegistryUrl $RegistryUrl
        }

        "status" {
            Invoke-SELibsStatus `
                -ModRoot $ModRoot `
                -RegistryUrl $RegistryUrl
        }

        "update" {
            if ([string]::IsNullOrWhiteSpace($PackageSpec)) {
                throw (
                    "The update command requires a package ID " +
                    "or ID@version."
                )
            }

            Invoke-SELibsUpdate `
                -ModRoot $ModRoot `
                -PackageSpec $PackageSpec `
                -RegistryUrl $RegistryUrl
        }

        "remove" {
            if ([string]::IsNullOrWhiteSpace($PackageSpec)) {
                throw "The remove command requires a package ID."
            }

            Invoke-SELibsRemove `
                -ModRoot $ModRoot `
                -PackageId $PackageSpec
        }

        "help" {
            Show-SELibsHelp
        }

        default {
            throw "Unsupported command '$Command'."
        }
    }
}
