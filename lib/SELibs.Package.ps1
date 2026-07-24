$script:SELibsDefaultRegistryUrl = (
    "https://raw.githubusercontent.com/" +
    "Marco-Zechner/selibs/main/registry/packages.json"
)

function Get-SELibsWebHeaders {
    [CmdletBinding()]
    param(
        [switch]$GitHubApi
    )

    $headers = @{
        "User-Agent" = "SELibs/0.1"
    }

    if ($GitHubApi) {
        $headers["Accept"] = "application/vnd.github+json"
        $headers["X-GitHub-Api-Version"] = "2026-03-10"

        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
        }
    }

    return $headers
}

function Read-SELibsJsonResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    try {
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            return Get-Content -LiteralPath $Source -Raw |
                ConvertFrom-Json
        }

        $response = Invoke-WebRequest `
            -Uri $Source `
            -UseBasicParsing `
            -Headers (Get-SELibsWebHeaders)

        return $response.Content | ConvertFrom-Json
    }
    catch {
        throw (
            "Could not read JSON resource '$Source': " +
            $_.Exception.Message
        )
    }
}

function Invoke-SELibsGitHubApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        return Invoke-RestMethod `
            -Uri $Uri `
            -UseBasicParsing `
            -Headers (Get-SELibsWebHeaders -GitHubApi)
    }
    catch {
        throw "GitHub request failed for '$Uri': $($_.Exception.Message)"
    }
}

function Copy-SELibsResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination

    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Copy-Item `
            -LiteralPath $Source `
            -Destination $Destination `
            -Force

        return
    }

    try {
        Invoke-WebRequest `
            -Uri $Source `
            -UseBasicParsing `
            -Headers (Get-SELibsWebHeaders) `
            -OutFile $Destination
    }
    catch {
        throw "Could not download '$Source': $($_.Exception.Message)"
    }
}

function ConvertFrom-SELibsPackageSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageSpec
    )

    $trimmed = $PackageSpec.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Package specification cannot be empty."
    }

    $separator = $trimmed.LastIndexOf("@")

    if ($separator -gt 0) {
        $id = $trimmed.Substring(0, $separator)
        $version = $trimmed.Substring($separator + 1)

        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Package '$trimmed' does not specify a version after '@'."
        }

        [void](ConvertTo-SELibsVersion -Version $version)
    }
    else {
        $id = $trimmed
        $version = $null
    }

    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Package ID '$id' contains unsupported characters."
    }

    return [pscustomobject]@{
        Id = $id
        Version = $version
    }
}

function ConvertTo-SELibsVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $parsed = $null

    if (
        -not [System.Version]::TryParse(
            $Version,
            [ref]$parsed
        )
    ) {
        throw (
            "Version '$Version' is not supported yet. " +
            "Use a numeric version such as 1.2.3."
        )
    }

    return $parsed
}

function Get-SELibsNamedProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $matches = @(
        $Object.PSObject.Properties |
            Where-Object {
                $_.Name.Equals(
                    $Name,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    if ($matches.Count -eq 0) {
        throw "$Description '$Name' was not found."
    }

    if ($matches.Count -gt 1) {
        throw "$Description '$Name' is ambiguous."
    }

    return $matches[0].Value
}

function Read-SELibsRegistry {
    [CmdletBinding()]
    param(
        [string]$RegistryUrl
    )

    $source = $RegistryUrl

    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = $script:SELibsDefaultRegistryUrl
    }

    $registry = Read-SELibsJsonResource -Source $source

    if (
        $null -eq $registry.schemaVersion -or
        $registry.schemaVersion -ne 1
    ) {
        throw "Registry '$source' does not use supported schema version 1."
    }

    if ($null -eq $registry.packages) {
        throw "Registry '$source' does not define packages."
    }

    return [pscustomobject]@{
        Source = $source
        Value = $registry
    }
}

function Get-SELibsPackageRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Registry,

        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $route = Get-SELibsNamedProperty `
        -Object $Registry.Value.packages `
        -Name $PackageId `
        -Description "Package"

    if ([string]::IsNullOrWhiteSpace([string]$route.provider)) {
        throw "Package '$PackageId' does not define a provider."
    }

    return $route
}

function Get-SELibsFilesystemRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [object]$Route,

        [string]$RequestedVersion
    )

    if ([string]::IsNullOrWhiteSpace([string]$Route.location)) {
        throw "Filesystem package '$PackageId' does not define location."
    }

    $location = [System.IO.Path]::GetFullPath([string]$Route.location)

    if (-not (Test-Path -LiteralPath $location -PathType Container)) {
        throw "Package location '$location' does not exist."
    }

    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        $versions = @(
            Get-ChildItem -LiteralPath $location -Directory |
                ForEach-Object {
                    try {
                        [pscustomobject]@{
                            Text = $_.Name
                            Parsed = ConvertTo-SELibsVersion `
                                -Version $_.Name
                        }
                    }
                    catch {
                    }
                } |
                Where-Object { $null -ne $_ } |
                Sort-Object Parsed -Descending
        )

        if ($versions.Count -eq 0) {
            throw "Package '$PackageId' has no supported releases."
        }

        $version = $versions[0].Text
    }
    else {
        [void](ConvertTo-SELibsVersion -Version $RequestedVersion)
        $version = $RequestedVersion
    }

    $releasePath = Join-Path $location $version

    if (-not (Test-Path -LiteralPath $releasePath -PathType Container)) {
        throw "Package '$PackageId' has no release '$version'."
    }

    $manifestName = "$PackageId-$version-package.json"
    $manifestPath = Join-Path $releasePath $manifestName

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw (
            "Release '$PackageId@$version' does not contain " +
            "'$manifestName'."
        )
    }

    return [pscustomobject]@{
        PackageId = $PackageId
        Version = $version
        ManifestSource = $manifestPath
        AssetRoot = $releasePath
        Assets = $null
    }
}

function Get-SELibsGitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [object]$Route,

        [string]$RequestedVersion
    )

    $repository = [string]$Route.repository
    $releasePrefix = [string]$Route.releasePrefix

    if ($repository -notmatch '^[^/]+/[^/]+$') {
        throw (
            "GitHub package '$PackageId' must define repository " +
            "as 'owner/name'."
        )
    }

    if ([string]::IsNullOrWhiteSpace($releasePrefix)) {
        throw "GitHub package '$PackageId' does not define releasePrefix."
    }

    $apiRoot = "https://api.github.com/repos/$repository"

    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        $releases = @(
            Invoke-SELibsGitHubApi `
                -Uri "$apiRoot/releases?per_page=100"
        )

        $candidates = @()

        foreach ($release in $releases) {
            $tag = [string]$release.tag_name

            if (
                $release.draft -or
                $release.prerelease -or
                -not $tag.StartsWith(
                    $releasePrefix,
                    [System.StringComparison]::Ordinal
                )
            ) {
                continue
            }

            $versionText = $tag.Substring($releasePrefix.Length)

            try {
                $parsedVersion = ConvertTo-SELibsVersion `
                    -Version $versionText
            }
            catch {
                continue
            }

            $candidates += [pscustomobject]@{
                Version = $versionText
                ParsedVersion = $parsedVersion
                Release = $release
            }
        }

        $selected = @(
            $candidates |
                Sort-Object ParsedVersion -Descending
        ) | Select-Object -First 1

        if ($null -eq $selected) {
            throw "Package '$PackageId' has no supported GitHub releases."
        }

        $version = $selected.Version
        $release = $selected.Release
    }
    else {
        [void](ConvertTo-SELibsVersion -Version $RequestedVersion)
        $version = $RequestedVersion
        $tag = $releasePrefix + $version
        $encodedTag = [System.Uri]::EscapeDataString($tag)
        $release = Invoke-SELibsGitHubApi `
            -Uri "$apiRoot/releases/tags/$encodedTag"
    }

    $manifestName = "$PackageId-$version-package.json"
    $manifestAssets = @(
        $release.assets |
            Where-Object { $_.name -eq $manifestName }
    )

    if ($manifestAssets.Count -ne 1) {
        throw (
            "Release '$PackageId@$version' must contain exactly one " +
            "'$manifestName' asset."
        )
    }

    return [pscustomobject]@{
        PackageId = $PackageId
        Version = $version
        ManifestSource = [string]$manifestAssets[0].browser_download_url
        AssetRoot = $null
        Assets = @($release.assets)
    }
}

function Get-SELibsRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [object]$Route,

        [string]$RequestedVersion
    )

    switch ([string]$Route.provider) {
        "filesystem" {
            return Get-SELibsFilesystemRelease `
                -PackageId $PackageId `
                -Route $Route `
                -RequestedVersion $RequestedVersion
        }

        "github" {
            return Get-SELibsGitHubRelease `
                -PackageId $PackageId `
                -Route $Route `
                -RequestedVersion $RequestedVersion
        }

        default {
            throw (
                "Package '$PackageId' uses unsupported provider " +
                "'$($Route.provider)'."
            )
        }
    }
}

function Get-SELibsComponentSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    if ($null -ne $Release.AssetRoot) {
        $path = Join-Path $Release.AssetRoot $AssetName

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw (
                "Release '$($Release.PackageId)@$($Release.Version)' " +
                "does not contain '$AssetName'."
            )
        }

        return $path
    }

    $matches = @(
        $Release.Assets |
            Where-Object { $_.name -eq $AssetName }
    )

    if ($matches.Count -ne 1) {
        throw (
            "Release '$($Release.PackageId)@$($Release.Version)' " +
            "must contain exactly one '$AssetName' asset."
        )
    }

    return [string]$matches[0].browser_download_url
}

function Get-SELibsPackageDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Registry,

        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [string]$RequestedVersion
    )

    $route = Get-SELibsPackageRoute `
        -Registry $Registry `
        -PackageId $PackageId

    $release = Get-SELibsRelease `
        -PackageId $PackageId `
        -Route $route `
        -RequestedVersion $RequestedVersion

    $packageManifest = Read-SELibsJsonResource `
        -Source $release.ManifestSource

    if (
        $null -eq $packageManifest.schemaVersion -or
        $packageManifest.schemaVersion -ne 1
    ) {
        throw (
            "Package manifest for '$PackageId' does not use " +
            "supported schema version 1."
        )
    }

    if (
        -not ([string]$packageManifest.id).Equals(
            $PackageId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "Package manifest ID '$($packageManifest.id)' does not " +
            "match requested ID '$PackageId'."
        )
    }

    if ([string]$packageManifest.version -ne $release.Version) {
        throw (
            "Package manifest version '$($packageManifest.version)' " +
            "does not match release version '$($release.Version)'."
        )
    }

    if ($null -eq $packageManifest.dependencies) {
        throw "Package '$PackageId' does not define dependencies."
    }

    if ($null -eq $packageManifest.component) {
        throw "Package '$PackageId' does not define component metadata."
    }

    $componentAsset = [string]$packageManifest.component.asset
    $componentSha256 = [string]$packageManifest.component.sha256

    if ([string]::IsNullOrWhiteSpace($componentAsset)) {
        throw "Package '$PackageId' does not define a component asset."
    }

    if ($componentSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Package '$PackageId' does not define a valid SHA-256 hash."
    }

    $folders = @($packageManifest.folders)

    if ($folders.Count -eq 0) {
        throw "Package '$PackageId' does not define any folders."
    }

    foreach ($folder in $folders) {
        $folderName = [string]$folder

        if (
            [string]::IsNullOrWhiteSpace($folderName) -or
            $folderName -match '[\\/]' -or
            $folderName -eq "." -or
            $folderName -eq ".."
        ) {
            throw (
                "Package '$PackageId' contains invalid folder " +
                "'$folderName'."
            )
        }
    }

    foreach ($dependency in $packageManifest.dependencies.PSObject.Properties) {
        [void](ConvertTo-SELibsVersion -Version ([string]$dependency.Value))
    }

    $componentSource = Get-SELibsComponentSource `
        -Release $release `
        -AssetName $componentAsset

    return [pscustomobject]@{
        Id = [string]$packageManifest.id
        Version = [string]$packageManifest.version
        Dependencies = $packageManifest.dependencies
        Folders = $folders
        ComponentSource = $componentSource
        ComponentSha256 = $componentSha256.ToLowerInvariant()
        Route = $route
    }
}

function Resolve-SELibsPackageGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Registry,

        [Parameter(Mandatory = $true)]
        [string]$RootPackageId,

        [string]$RootVersion
    )

    $resolved = [ordered]@{}
    $visiting = @{}
    $order = New-Object System.Collections.ArrayList

    function Resolve-Package {
        param(
            [Parameter(Mandatory = $true)]
            [string]$PackageId,

            [string]$RequestedVersion
        )

        if ($resolved.Contains($PackageId)) {
            $existing = $resolved[$PackageId]

            if (
                -not [string]::IsNullOrWhiteSpace($RequestedVersion) -and
                $existing.Version -ne $RequestedVersion
            ) {
                throw (
                    "Dependency conflict for '$PackageId': " +
                    "'$($existing.Version)' and '$RequestedVersion'."
                )
            }

            return
        }

        if ($visiting.ContainsKey($PackageId)) {
            throw "Dependency cycle detected at '$PackageId'."
        }

        $visiting[$PackageId] = $true

        try {
            $descriptor = Get-SELibsPackageDescriptor `
                -Registry $Registry `
                -PackageId $PackageId `
                -RequestedVersion $RequestedVersion

            foreach ($dependency in $descriptor.Dependencies.PSObject.Properties) {
                Resolve-Package `
                    -PackageId $dependency.Name `
                    -RequestedVersion ([string]$dependency.Value)
            }

            $resolved[$PackageId] = $descriptor
            [void]$order.Add($descriptor)
        }
        finally {
            $visiting.Remove($PackageId)
        }
    }

    Resolve-Package `
        -PackageId $RootPackageId `
        -RequestedVersion $RootVersion

    return @($order)
}

function Expand-SELibsComponentArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $destinationRoot = (
        [System.IO.Path]::GetFullPath($Destination)
    ).TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar

    $stream = [System.IO.File]::OpenRead($ArchivePath)

    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )

        try {
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace("\", "/")

                if (
                    [string]::IsNullOrWhiteSpace($name) -or
                    $name.StartsWith("/") -or
                    -not $name.StartsWith(
                        "Libraries/",
                        [System.StringComparison]::Ordinal
                    )
                ) {
                    throw (
                        "Archive entry '$name' is outside the " +
                        "Libraries directory."
                    )
                }

                $segments = $name.Split("/")

                if ($segments -contains "..") {
                    throw "Archive entry '$name' contains path traversal."
                }

                $relativePath = $name.Replace(
                    "/",
                    [System.IO.Path]::DirectorySeparatorChar
                )

                $targetPath = [System.IO.Path]::GetFullPath(
                    (Join-Path $Destination $relativePath)
                )

                if (
                    -not $targetPath.StartsWith(
                        $destinationRoot,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    throw "Archive entry '$name' escapes its destination."
                }
            }

            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace("\", "/")
                $relativePath = $name.Replace(
                    "/",
                    [System.IO.Path]::DirectorySeparatorChar
                )

                $targetPath = [System.IO.Path]::GetFullPath(
                    (Join-Path $Destination $relativePath)
                )

                if ($name.EndsWith("/")) {
                    New-Item `
                        -ItemType Directory `
                        -Path $targetPath `
                        -Force |
                        Out-Null

                    continue
                }

                $parent = Split-Path -Parent $targetPath

                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item `
                        -ItemType Directory `
                        -Path $parent `
                        -Force |
                        Out-Null
                }

                $input = $entry.Open()

                try {
                    $output = [System.IO.File]::Create($targetPath)

                    try {
                        $input.CopyTo($output)
                    }
                    finally {
                        $output.Dispose()
                    }
                }
                finally {
                    $input.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SELibsFolderFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibrariesRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Folders
    )

    $files = [ordered]@{}
    $rootPrefix = (
        [System.IO.Path]::GetFullPath($LibrariesRoot)
    ).TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar

    foreach ($folder in $Folders) {
        $folderPath = Join-Path $LibrariesRoot $folder

        foreach (
            $file in @(
                Get-ChildItem -LiteralPath $folderPath -File -Recurse |
                    Sort-Object FullName
            )
        ) {
            $relative = $file.FullName.Substring(
                $rootPrefix.Length
            ).Replace("\", "/")

            $files[$relative] = (
                Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }

    return $files
}

function ConvertTo-SELibsRouteLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Route
    )

    switch ([string]$Route.provider) {
        "github" {
            return [ordered]@{
                provider = "github"
                repository = [string]$Route.repository
                releasePrefix = [string]$Route.releasePrefix
            }
        }

        "filesystem" {
            return [ordered]@{
                provider = "filesystem"
                location = [string]$Route.location
            }
        }

        default {
            throw "Cannot lock unsupported provider '$($Route.provider)'."
        }
    }
}

function Write-SELibsJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $temporaryPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    $json = $Value | ConvertTo-Json -Depth 30

    try {
        Write-SELibsUtf8NoBom `
            -Path $temporaryPath `
            -Content ($json + "`n")

        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $Path `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-SELibsAdd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot,

        [Parameter(Mandatory = $true)]
        [string]$PackageSpec,

        [string]$RegistryUrl
    )

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot
    $manifestPath = Join-Path $root "selibs.json"
    $lockPath = Join-Path $root "selibs.lock.json"
    $statePath = Join-Path $root ".selibs"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "This mod is not initialized. Run 'selibs init' first."
    }

    $manifest = Read-SELibsManifest -Path $manifestPath

    if (@($manifest.dependencies.PSObject.Properties).Count -ne 0) {
        throw (
            "This first add implementation supports a fresh manifest only. " +
            "Additional-package reconciliation comes next."
        )
    }

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        throw (
            "A lock file already exists while the manifest has no " +
            "dependencies. Resolve the inconsistent state first."
        )
    }

    $resolvedLibraries = Resolve-SELibsLibrariesPath `
        -ModRoot $root `
        -LibrariesPath ([string]$manifest.librariesPath)

    $requested = ConvertFrom-SELibsPackageSpec `
        -PackageSpec $PackageSpec

    $registry = Read-SELibsRegistry -RegistryUrl $RegistryUrl
    $descriptors = @(
        Resolve-SELibsPackageGraph `
            -Registry $registry `
            -RootPackageId $requested.Id `
            -RootVersion $requested.Version
    )

    $rootDescriptor = @(
        $descriptors |
            Where-Object {
                $_.Id.Equals(
                    $requested.Id,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    if ($rootDescriptor.Count -ne 1) {
        throw "Resolved graph did not contain root package '$($requested.Id)'."
    }

    New-Item -ItemType Directory -Path $statePath -Force | Out-Null

    $transactionRoot = Join-Path `
        $statePath `
        ("tmp\install-" + [Guid]::NewGuid().ToString("N"))

    $combinedLibraries = Join-Path $transactionRoot "combined\Libraries"
    $createdTargets = New-Object System.Collections.ArrayList

    try {
        New-Item `
            -ItemType Directory `
            -Path $combinedLibraries `
            -Force |
            Out-Null

        $lockEntries = [ordered]@{}

        foreach ($descriptor in $descriptors) {
            $packageRoot = Join-Path $transactionRoot $descriptor.Id
            $archivePath = Join-Path $packageRoot "component.zip"
            $extractPath = Join-Path $packageRoot "extract"

            Copy-SELibsResource `
                -Source $descriptor.ComponentSource `
                -Destination $archivePath

            $actualHash = (
                Get-FileHash `
                    -LiteralPath $archivePath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()

            if ($actualHash -ne $descriptor.ComponentSha256) {
                throw (
                    "Component checksum mismatch for " +
                    "'$($descriptor.Id)@$($descriptor.Version)'."
                )
            }

            Expand-SELibsComponentArchive `
                -ArchivePath $archivePath `
                -Destination $extractPath

            $extractedLibraries = Join-Path $extractPath "Libraries"

            foreach ($folder in $descriptor.Folders) {
                $sourceFolder = Join-Path $extractedLibraries $folder

                if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
                    throw (
                        "Package '$($descriptor.Id)' does not contain " +
                        "declared folder '$folder'."
                    )
                }

                $stagedTarget = Join-Path $combinedLibraries $folder

                if (Test-Path -LiteralPath $stagedTarget) {
                    throw (
                        "Packages claim the same Libraries folder '$folder'."
                    )
                }

                Copy-Item `
                    -LiteralPath $sourceFolder `
                    -Destination $stagedTarget `
                    -Recurse
            }

            $dependencyLock = [ordered]@{}

            foreach (
                $dependency in @(
                    $descriptor.Dependencies.PSObject.Properties |
                        Sort-Object Name
                )
            ) {
                $dependencyLock[$dependency.Name] = [string]$dependency.Value
            }

            $lockEntries[$descriptor.Id] = [ordered]@{
                version = $descriptor.Version
                direct = $descriptor.Id.Equals(
                    $requested.Id,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
                source = ConvertTo-SELibsRouteLock `
                    -Route $descriptor.Route
                dependencies = $dependencyLock
                folders = @($descriptor.Folders)
                files = Get-SELibsFolderFiles `
                    -LibrariesRoot $extractedLibraries `
                    -Folders $descriptor.Folders
            }
        }

        foreach ($descriptor in $descriptors) {
            foreach ($folder in $descriptor.Folders) {
                $target = Join-Path $resolvedLibraries.FullPath $folder

                if (Test-Path -LiteralPath $target) {
                    throw (
                        "Refusing to overwrite existing Libraries folder " +
                        "'$folder'."
                    )
                }
            }
        }

        New-Item `
            -ItemType Directory `
            -Path $resolvedLibraries.FullPath `
            -Force |
            Out-Null

        foreach (
            $folder in @(
                Get-ChildItem -LiteralPath $combinedLibraries -Directory |
                    Sort-Object Name
            )
        ) {
            $target = Join-Path $resolvedLibraries.FullPath $folder.Name

            Copy-Item `
                -LiteralPath $folder.FullName `
                -Destination $target `
                -Recurse

            [void]$createdTargets.Add($target)
        }

        $newManifest = [ordered]@{
            schemaVersion = 1
            librariesPath = $resolvedLibraries.RelativePath
            dependencies = [ordered]@{
                $rootDescriptor[0].Id = $rootDescriptor[0].Version
            }
        }

        $newLock = [ordered]@{
            schemaVersion = 1
            registry = $registry.Source
            packages = $lockEntries
        }

        try {
            Write-SELibsJsonAtomic `
                -Path $lockPath `
                -Value $newLock

            Write-SELibsJsonAtomic `
                -Path $manifestPath `
                -Value $newManifest
        }
        catch {
            if (Test-Path -LiteralPath $lockPath) {
                Remove-Item -LiteralPath $lockPath -Force
            }

            throw
        }

        Write-Output (
            "Added $($rootDescriptor[0].Id) " +
            "$($rootDescriptor[0].Version)."
        )

        foreach (
            $descriptor in @(
                $descriptors |
                    Where-Object {
                        -not $_.Id.Equals(
                            $rootDescriptor[0].Id,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            )
        ) {
            Write-Output (
                "Installed dependency " +
                "$($descriptor.Id) $($descriptor.Version)."
            )
        }

        Write-Output "Libraries: $($resolvedLibraries.RelativePath)"
        Write-Output "Lock file: selibs.lock.json"
    }
    catch {
        foreach ($target in $createdTargets) {
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        }

        throw
    }
    finally {
        if (Test-Path -LiteralPath $transactionRoot) {
            Remove-Item `
                -LiteralPath $transactionRoot `
                -Recurse `
                -Force
        }

        $transactionParent = Split-Path -Parent $transactionRoot

        if (
            (Test-Path -LiteralPath $transactionParent -PathType Container) -and
            @(
                Get-ChildItem -LiteralPath $transactionParent -Force
            ).Count -eq 0
        ) {
            Remove-Item -LiteralPath $transactionParent -Force
        }
    }
}