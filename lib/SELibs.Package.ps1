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

function Get-SELibsObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
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

    if ($matches.Count -gt 1) {
        throw "Property '$Name' is ambiguous."
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function ConvertTo-SELibsDependencyMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Dependencies
    )

    $result = [ordered]@{}

    foreach (
        $property in @(
            $Dependencies.PSObject.Properties |
                Sort-Object Name
        )
    ) {
        $result[$property.Name] = [string]$property.Value
    }

    return $result
}

function Read-SELibsLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $lock = Get-Content -LiteralPath $Path -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Could not read SELibs lock '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $lock.schemaVersion -or $lock.schemaVersion -ne 1) {
        throw "Lock '$Path' does not use supported schema version 1."
    }

    if ($null -eq $lock.packages) {
        throw "Lock '$Path' does not define packages."
    }

    return $lock
}

function Resolve-SELibsProjectGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Registry,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DirectDependencies
    )

    $resolved = [ordered]@{}
    $visiting = @{}
    $order = New-Object System.Collections.ArrayList

    function Resolve-ProjectPackage {
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

            foreach (
                $dependency in @(
                    $descriptor.Dependencies.PSObject.Properties |
                        Sort-Object Name
                )
            ) {
                Resolve-ProjectPackage `
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

    foreach ($packageId in @($DirectDependencies.Keys | Sort-Object)) {
        Resolve-ProjectPackage `
            -PackageId $packageId `
            -RequestedVersion ([string]$DirectDependencies[$packageId])
    }

    return @($order)
}

function Test-SELibsManagedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibrariesRoot,

        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [object]$LockEntry
    )

    $expectedFiles = @{}

    foreach ($property in $LockEntry.files.PSObject.Properties) {
        $expectedFiles[$property.Name.Replace("\", "/")] = (
            [string]$property.Value
        ).ToLowerInvariant()
    }

    $actualFiles = @{}
    $rootPrefix = (
        [System.IO.Path]::GetFullPath($LibrariesRoot)
    ).TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar

    foreach ($folderValue in @($LockEntry.folders)) {
        $folder = [string]$folderValue

        if (
            [string]::IsNullOrWhiteSpace($folder) -or
            $folder -match '[\\/]'
        ) {
            throw "Lock entry '$PackageId' contains invalid folder '$folder'."
        }

        $folderPath = Join-Path $LibrariesRoot $folder

        if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
            throw (
                "Managed package '$PackageId' is missing folder '$folder'."
            )
        }

        foreach (
            $file in @(
                Get-ChildItem -LiteralPath $folderPath -File -Recurse |
                    Sort-Object FullName
            )
        ) {
            $relative = $file.FullName.Substring(
                $rootPrefix.Length
            ).Replace("\", "/")

            $actualFiles[$relative] = $file.FullName
        }
    }

    if ($actualFiles.Count -ne $expectedFiles.Count) {
        throw (
            "Managed package '$PackageId' has added or removed files. " +
            "Restore it before changing dependencies."
        )
    }

    foreach ($relativePath in $expectedFiles.Keys) {
        if (-not $actualFiles.ContainsKey($relativePath)) {
            throw (
                "Managed package '$PackageId' is missing file " +
                "'$relativePath'."
            )
        }

        $actualHash = (
            Get-FileHash `
                -LiteralPath $actualFiles[$relativePath] `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        if ($actualHash -ne $expectedFiles[$relativePath]) {
            throw (
                "Managed package '$PackageId' has modified file " +
                "'$relativePath'."
            )
        }
    }
}

function Test-SELibsFolderClaims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Descriptors
    )

    $owners = @{}

    foreach ($descriptor in $Descriptors) {
        foreach ($folderValue in $descriptor.Folders) {
            $folder = [string]$folderValue

            if ($owners.ContainsKey($folder)) {
                throw (
                    "Packages '$($owners[$folder])' and " +
                    "'$($descriptor.Id)' both claim Libraries folder " +
                    "'$folder'."
                )
            }

            $owners[$folder] = $descriptor.Id
        }
    }
}

function New-SELibsLockEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Descriptor,

        [Parameter(Mandatory = $true)]
        [bool]$Direct,

        [Parameter(Mandatory = $true)]
        [object]$Files
    )

    return [ordered]@{
        version = $Descriptor.Version
        direct = $Direct
        source = ConvertTo-SELibsRouteLock -Route $Descriptor.Route
        dependencies = ConvertTo-SELibsDependencyMap `
            -Dependencies $Descriptor.Dependencies
        folders = @($Descriptor.Folders)
        files = $Files
    }
}

function Copy-SELibsLockEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [Parameter(Mandatory = $true)]
        [bool]$Direct
    )

    $source = [ordered]@{}

    foreach ($property in $Entry.source.PSObject.Properties) {
        $source[$property.Name] = $property.Value
    }

    return [ordered]@{
        version = [string]$Entry.version
        direct = $Direct
        source = $source
        dependencies = ConvertTo-SELibsDependencyMap `
            -Dependencies $Entry.dependencies
        folders = @($Entry.folders)
        files = ConvertTo-SELibsDependencyMap -Dependencies $Entry.files
    }
}

function Restore-SELibsProjectFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [object]$OriginalContent
    )

    if ($null -eq $OriginalContent) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }

        return
    }

    Write-SELibsUtf8NoBom `
        -Path $Path `
        -Content ([string]$OriginalContent)
}

function Remove-SELibsEmptyTransactionParent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TransactionRoot
    )

    $transactionParent = Split-Path -Parent $TransactionRoot

    if (
        (Test-Path -LiteralPath $transactionParent -PathType Container) -and
        @(
            Get-ChildItem -LiteralPath $transactionParent -Force
        ).Count -eq 0
    ) {
        Remove-Item -LiteralPath $transactionParent -Force
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
    $directDependencies = ConvertTo-SELibsDependencyMap `
        -Dependencies $manifest.dependencies

    $requested = ConvertFrom-SELibsPackageSpec `
        -PackageSpec $PackageSpec

    if ($directDependencies.Contains($requested.Id)) {
        throw (
            "Package '$($requested.Id)' is already a direct dependency. " +
            "Use update to change its version."
        )
    }

    $directDependencies[$requested.Id] = $requested.Version

    $existingLock = $null

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $existingLock = Read-SELibsLock -Path $lockPath
    }
    elseif ($directDependencies.Count -gt 1) {
        throw (
            "The manifest contains dependencies but selibs.lock.json " +
            "is missing."
        )
    }

    $resolvedLibraries = Resolve-SELibsLibrariesPath `
        -ModRoot $root `
        -LibrariesPath ([string]$manifest.librariesPath)

    $registry = Read-SELibsRegistry -RegistryUrl $RegistryUrl
    $descriptors = @(
        Resolve-SELibsProjectGraph `
            -Registry $registry `
            -DirectDependencies $directDependencies
    )

    Test-SELibsFolderClaims -Descriptors $descriptors

    $descriptorById = @{}

    foreach ($descriptor in $descriptors) {
        $descriptorById[$descriptor.Id] = $descriptor
    }

    $rootDescriptor = $descriptorById[$requested.Id]

    if ($null -eq $rootDescriptor) {
        throw "Resolved graph did not contain '$($requested.Id)'."
    }

    $finalDirectDependencies = [ordered]@{}

    foreach ($directId in @($directDependencies.Keys | Sort-Object)) {
        $descriptor = $descriptorById[$directId]

        if ($null -eq $descriptor) {
            throw "Resolved graph did not contain direct package '$directId'."
        }

        $finalDirectDependencies[$descriptor.Id] = $descriptor.Version
    }

    $existingPackageProperties = @{}

    if ($null -ne $existingLock) {
        foreach ($property in $existingLock.packages.PSObject.Properties) {
            $existingPackageProperties[$property.Name] = $property

            if (-not $descriptorById.ContainsKey($property.Name)) {
                throw (
                    "The lock contains unreachable package " +
                    "'$($property.Name)'. Run remove or restore first."
                )
            }
        }
    }

    New-Item -ItemType Directory -Path $statePath -Force | Out-Null

    $transactionRoot = Join-Path `
        $statePath `
        ("tmp\add-" + [Guid]::NewGuid().ToString("N"))

    $createdTargets = New-Object System.Collections.ArrayList
    $oldManifestContent = Get-Content -LiteralPath $manifestPath -Raw
    $oldLockContent = $null

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $oldLockContent = Get-Content -LiteralPath $lockPath -Raw
    }

    try {
        $lockEntries = [ordered]@{}
        $stagedPackages = @{}

        foreach ($descriptor in $descriptors) {
            $existingProperty = $null

            if ($existingPackageProperties.ContainsKey($descriptor.Id)) {
                $existingProperty = $existingPackageProperties[$descriptor.Id]
            }

            if ($null -ne $existingProperty) {
                $existingEntry = $existingProperty.Value

                if ([string]$existingEntry.version -ne $descriptor.Version) {
                    throw (
                        "Installed package '$($descriptor.Id)' is locked at " +
                        "'$($existingEntry.version)' but resolution selected " +
                        "'$($descriptor.Version)'."
                    )
                }

                Test-SELibsManagedPackage `
                    -LibrariesRoot $resolvedLibraries.FullPath `
                    -PackageId $descriptor.Id `
                    -LockEntry $existingEntry

                $lockEntries[$descriptor.Id] = New-SELibsLockEntry `
                    -Descriptor $descriptor `
                    -Direct:$finalDirectDependencies.Contains($descriptor.Id) `
                    -Files (Get-SELibsFolderFiles `
                        -LibrariesRoot $resolvedLibraries.FullPath `
                        -Folders $descriptor.Folders)

                continue
            }

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

            foreach ($folderValue in $descriptor.Folders) {
                $folder = [string]$folderValue
                $sourceFolder = Join-Path $extractedLibraries $folder
                $targetFolder = Join-Path $resolvedLibraries.FullPath $folder

                if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
                    throw (
                        "Package '$($descriptor.Id)' does not contain " +
                        "declared folder '$folder'."
                    )
                }

                if (Test-Path -LiteralPath $targetFolder) {
                    throw (
                        "Refusing to overwrite existing Libraries folder " +
                        "'$folder'."
                    )
                }
            }

            $stagedPackages[$descriptor.Id] = $extractedLibraries

            $lockEntries[$descriptor.Id] = New-SELibsLockEntry `
                -Descriptor $descriptor `
                -Direct:$finalDirectDependencies.Contains($descriptor.Id) `
                -Files (Get-SELibsFolderFiles `
                    -LibrariesRoot $extractedLibraries `
                    -Folders $descriptor.Folders)
        }

        New-Item `
            -ItemType Directory `
            -Path $resolvedLibraries.FullPath `
            -Force |
            Out-Null

        foreach ($descriptor in $descriptors) {
            if (-not $stagedPackages.ContainsKey($descriptor.Id)) {
                continue
            }

            $stagedLibraries = $stagedPackages[$descriptor.Id]

            foreach ($folderValue in $descriptor.Folders) {
                $folder = [string]$folderValue
                $sourceFolder = Join-Path $stagedLibraries $folder
                $targetFolder = Join-Path $resolvedLibraries.FullPath $folder

                Copy-Item `
                    -LiteralPath $sourceFolder `
                    -Destination $targetFolder `
                    -Recurse

                [void]$createdTargets.Add($targetFolder)
            }
        }

        $newManifest = [ordered]@{
            schemaVersion = 1
            librariesPath = $resolvedLibraries.RelativePath
            dependencies = $finalDirectDependencies
        }

        $newLock = [ordered]@{
            schemaVersion = 1
            registry = $registry.Source
            packages = $lockEntries
        }

        try {
            Write-SELibsJsonAtomic -Path $lockPath -Value $newLock
            Write-SELibsJsonAtomic -Path $manifestPath -Value $newManifest
        }
        catch {
            Restore-SELibsProjectFile `
                -Path $manifestPath `
                -OriginalContent $oldManifestContent

            Restore-SELibsProjectFile `
                -Path $lockPath `
                -OriginalContent $oldLockContent

            throw
        }

        Write-Output (
            "Added $($rootDescriptor.Id) $($rootDescriptor.Version)."
        )

        foreach ($descriptor in $descriptors) {
            if (
                $descriptor.Id -ne $rootDescriptor.Id -and
                -not $existingPackageProperties.ContainsKey($descriptor.Id)
            ) {
                Write-Output (
                    "Installed dependency " +
                    "$($descriptor.Id) $($descriptor.Version)."
                )
            }
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

        Restore-SELibsProjectFile `
            -Path $manifestPath `
            -OriginalContent $oldManifestContent

        Restore-SELibsProjectFile `
            -Path $lockPath `
            -OriginalContent $oldLockContent

        throw
    }
    finally {
        if (Test-Path -LiteralPath $transactionRoot) {
            Remove-Item `
                -LiteralPath $transactionRoot `
                -Recurse `
                -Force
        }

        Remove-SELibsEmptyTransactionParent `
            -TransactionRoot $transactionRoot
    }
}

function Get-SELibsReachablePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DirectDependencies
    )

    $reachable = @{}

    function Visit-LockedPackage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$PackageId
        )

        if ($reachable.ContainsKey($PackageId)) {
            return
        }

        $property = Get-SELibsObjectProperty `
            -Object $Lock.packages `
            -Name $PackageId

        if ($null -eq $property) {
            throw "Lock does not contain required package '$PackageId'."
        }

        $reachable[$property.Name] = $true

        foreach ($dependency in $property.Value.dependencies.PSObject.Properties) {
            Visit-LockedPackage -PackageId $dependency.Name
        }
    }

    foreach ($packageId in $DirectDependencies.Keys) {
        Visit-LockedPackage -PackageId $packageId
    }

    return $reachable
}

function Invoke-SELibsRemove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModRoot,

        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    if (
        [string]::IsNullOrWhiteSpace($PackageId) -or
        $PackageId.Contains("@") -or
        $PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    ) {
        throw "The remove command requires one valid package ID."
    }

    $root = Get-SELibsFullModRoot -ModRoot $ModRoot
    $manifestPath = Join-Path $root "selibs.json"
    $lockPath = Join-Path $root "selibs.lock.json"
    $statePath = Join-Path $root ".selibs"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "This mod is not initialized. Run 'selibs init' first."
    }

    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "selibs.lock.json is missing."
    }

    $manifest = Read-SELibsManifest -Path $manifestPath
    $lock = Read-SELibsLock -Path $lockPath
    $directDependencies = ConvertTo-SELibsDependencyMap `
        -Dependencies $manifest.dependencies

    $directProperty = Get-SELibsObjectProperty `
        -Object $manifest.dependencies `
        -Name $PackageId

    if ($null -eq $directProperty) {
        throw "Package '$PackageId' is not a direct dependency."
    }

    $canonicalId = $directProperty.Name
    $remainingDirect = [ordered]@{}

    foreach ($directId in @($directDependencies.Keys | Sort-Object)) {
        if (
            -not $directId.Equals(
                $canonicalId,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $remainingDirect[$directId] = $directDependencies[$directId]
        }
    }

    $reachable = Get-SELibsReachablePackages `
        -Lock $lock `
        -DirectDependencies $remainingDirect

    $removedProperties = @(
        $lock.packages.PSObject.Properties |
            Where-Object {
                -not $reachable.ContainsKey($_.Name)
            } |
            Sort-Object Name
    )

    $rootLockProperty = Get-SELibsObjectProperty `
        -Object $lock.packages `
        -Name $canonicalId

    if ($null -eq $rootLockProperty) {
        throw "Lock does not contain direct package '$canonicalId'."
    }

    $resolvedLibraries = Resolve-SELibsLibrariesPath `
        -ModRoot $root `
        -LibrariesPath ([string]$manifest.librariesPath)

    foreach ($property in $removedProperties) {
        Test-SELibsManagedPackage `
            -LibrariesRoot $resolvedLibraries.FullPath `
            -PackageId $property.Name `
            -LockEntry $property.Value
    }

    New-Item -ItemType Directory -Path $statePath -Force | Out-Null

    $transactionRoot = Join-Path `
        $statePath `
        ("tmp\remove-" + [Guid]::NewGuid().ToString("N"))

    $backupLibraries = Join-Path $transactionRoot "Libraries"
    $movedFolders = New-Object System.Collections.ArrayList
    $oldManifestContent = Get-Content -LiteralPath $manifestPath -Raw
    $oldLockContent = Get-Content -LiteralPath $lockPath -Raw

    try {
        foreach ($property in $removedProperties) {
            foreach ($folderValue in @($property.Value.folders)) {
                $folder = [string]$folderValue
                $source = Join-Path $resolvedLibraries.FullPath $folder
                $destination = Join-Path $backupLibraries $folder
                $destinationParent = Split-Path -Parent $destination

                New-Item `
                    -ItemType Directory `
                    -Path $destinationParent `
                    -Force |
                    Out-Null

                Move-Item `
                    -LiteralPath $source `
                    -Destination $destination

                [void]$movedFolders.Add([pscustomobject]@{
                    Source = $destination
                    Destination = $source
                })
            }
        }

        $remainingLockEntries = [ordered]@{}

        foreach (
            $property in @(
                $lock.packages.PSObject.Properties |
                    Sort-Object Name
            )
        ) {
            if (-not $reachable.ContainsKey($property.Name)) {
                continue
            }

            $remainingLockEntries[$property.Name] = Copy-SELibsLockEntry `
                -Entry $property.Value `
                -Direct:$remainingDirect.Contains($property.Name)
        }

        $newManifest = [ordered]@{
            schemaVersion = 1
            librariesPath = $resolvedLibraries.RelativePath
            dependencies = $remainingDirect
        }

        $newLock = [ordered]@{
            schemaVersion = 1
            registry = [string]$lock.registry
            packages = $remainingLockEntries
        }

        try {
            Write-SELibsJsonAtomic -Path $lockPath -Value $newLock
            Write-SELibsJsonAtomic -Path $manifestPath -Value $newManifest
        }
        catch {
            Restore-SELibsProjectFile `
                -Path $manifestPath `
                -OriginalContent $oldManifestContent

            Restore-SELibsProjectFile `
                -Path $lockPath `
                -OriginalContent $oldLockContent

            throw
        }

        if ($reachable.ContainsKey($canonicalId)) {
            Write-Output (
                "Removed direct dependency '$canonicalId'; " +
                "the package remains required transitively."
            )
        }
        else {
            Write-Output (
                "Removed $canonicalId " +
                "$($rootLockProperty.Value.version)."
            )
        }

        foreach ($property in $removedProperties) {
            if (
                -not $property.Name.Equals(
                    $canonicalId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                Write-Output (
                    "Removed unused dependency " +
                    "$($property.Name) $($property.Value.version)."
                )
            }
        }
    }
    catch {
        Restore-SELibsProjectFile `
            -Path $manifestPath `
            -OriginalContent $oldManifestContent

        Restore-SELibsProjectFile `
            -Path $lockPath `
            -OriginalContent $oldLockContent

        for (
            $index = $movedFolders.Count - 1;
            $index -ge 0;
            $index--
        ) {
            $moved = $movedFolders[$index]

            if (Test-Path -LiteralPath $moved.Source) {
                $parent = Split-Path -Parent $moved.Destination
                New-Item -ItemType Directory -Path $parent -Force | Out-Null

                Move-Item `
                    -LiteralPath $moved.Source `
                    -Destination $moved.Destination
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

        Remove-SELibsEmptyTransactionParent `
            -TransactionRoot $transactionRoot
    }
}

function Invoke-SELibsUpdate {
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

    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "selibs.lock.json is missing."
    }

    $manifest = Read-SELibsManifest -Path $manifestPath
    $lock = Read-SELibsLock -Path $lockPath
    $requested = ConvertFrom-SELibsPackageSpec `
        -PackageSpec $PackageSpec

    $directProperty = Get-SELibsObjectProperty `
        -Object $manifest.dependencies `
        -Name $requested.Id

    if ($null -eq $directProperty) {
        throw "Package '$($requested.Id)' is not a direct dependency."
    }

    $canonicalId = $directProperty.Name
    $oldDirectVersion = [string]$directProperty.Value
    $directDependencies = ConvertTo-SELibsDependencyMap `
        -Dependencies $manifest.dependencies

    $directDependencies[$canonicalId] = $requested.Version

    $effectiveRegistryUrl = $RegistryUrl

    if ([string]::IsNullOrWhiteSpace($effectiveRegistryUrl)) {
        $effectiveRegistryUrl = [string]$lock.registry
    }

    $registry = Read-SELibsRegistry `
        -RegistryUrl $effectiveRegistryUrl

    $descriptors = @(
        Resolve-SELibsProjectGraph `
            -Registry $registry `
            -DirectDependencies $directDependencies
    )

    Test-SELibsFolderClaims -Descriptors $descriptors

    $descriptorById = @{}

    foreach ($descriptor in $descriptors) {
        $descriptorById[$descriptor.Id] = $descriptor
    }

    $updatedDescriptor = $descriptorById[$canonicalId]

    if ($null -eq $updatedDescriptor) {
        throw "Resolved graph did not contain '$canonicalId'."
    }

    $finalDirectDependencies = [ordered]@{}

    foreach ($directId in @($directDependencies.Keys | Sort-Object)) {
        $descriptor = $descriptorById[$directId]

        if ($null -eq $descriptor) {
            throw "Resolved graph did not contain direct package '$directId'."
        }

        $finalDirectDependencies[$descriptor.Id] = $descriptor.Version
    }

    $existingProperties = @{}

    foreach ($property in $lock.packages.PSObject.Properties) {
        $existingProperties[$property.Name] = $property
    }

    $resolvedLibraries = Resolve-SELibsLibrariesPath `
        -ModRoot $root `
        -LibrariesPath ([string]$manifest.librariesPath)

    foreach ($property in $lock.packages.PSObject.Properties) {
        Test-SELibsManagedPackage `
            -LibrariesRoot $resolvedLibraries.FullPath `
            -PackageId $property.Name `
            -LockEntry $property.Value
    }

    $changedIds = @{}
    $removedProperties = New-Object System.Collections.ArrayList

    foreach ($descriptor in $descriptors) {
        $existingProperty = Get-SELibsObjectProperty `
            -Object $lock.packages `
            -Name $descriptor.Id

        if (
            $null -eq $existingProperty -or
            [string]$existingProperty.Value.version -ne $descriptor.Version
        ) {
            $changedIds[$descriptor.Id] = $true
        }
    }

    foreach ($property in $lock.packages.PSObject.Properties) {
        if (-not $descriptorById.ContainsKey($property.Name)) {
            [void]$removedProperties.Add($property)
        }
    }

    if (
        $changedIds.Count -eq 0 -and
        $removedProperties.Count -eq 0 -and
        $updatedDescriptor.Version -eq $oldDirectVersion
    ) {
        Write-Output (
            "$canonicalId is already at version " +
            "$($updatedDescriptor.Version)."
        )

        return
    }

    $replaceableFolders = @{}

    foreach ($property in $lock.packages.PSObject.Properties) {
        if (
            $changedIds.ContainsKey($property.Name) -or
            -not $descriptorById.ContainsKey($property.Name)
        ) {
            foreach ($folderValue in @($property.Value.folders)) {
                $replaceableFolders[[string]$folderValue] = $true
            }
        }
    }

    New-Item -ItemType Directory -Path $statePath -Force | Out-Null

    $transactionRoot = Join-Path `
        $statePath `
        ("tmp\update-" + [Guid]::NewGuid().ToString("N"))

    $backupLibraries = Join-Path $transactionRoot "backup\Libraries"
    $movedFolders = New-Object System.Collections.ArrayList
    $createdTargets = New-Object System.Collections.ArrayList
    $stagedPackages = @{}
    $oldManifestContent = Get-Content -LiteralPath $manifestPath -Raw
    $oldLockContent = Get-Content -LiteralPath $lockPath -Raw

    try {
        foreach ($descriptor in $descriptors) {
            if (-not $changedIds.ContainsKey($descriptor.Id)) {
                continue
            }

            $packageRoot = Join-Path `
                $transactionRoot `
                ("packages\" + $descriptor.Id)

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

            foreach ($folderValue in $descriptor.Folders) {
                $folder = [string]$folderValue
                $sourceFolder = Join-Path $extractedLibraries $folder
                $targetFolder = Join-Path $resolvedLibraries.FullPath $folder

                if (
                    -not (
                        Test-Path `
                            -LiteralPath $sourceFolder `
                            -PathType Container
                    )
                ) {
                    throw (
                        "Package '$($descriptor.Id)' does not contain " +
                        "declared folder '$folder'."
                    )
                }

                if (
                    (Test-Path -LiteralPath $targetFolder) -and
                    -not $replaceableFolders.ContainsKey($folder)
                ) {
                    throw (
                        "Refusing to overwrite existing Libraries folder " +
                        "'$folder'."
                    )
                }
            }

            $stagedPackages[$descriptor.Id] = $extractedLibraries
        }

        foreach ($property in $lock.packages.PSObject.Properties) {
            if (
                -not $changedIds.ContainsKey($property.Name) -and
                $descriptorById.ContainsKey($property.Name)
            ) {
                continue
            }

            foreach ($folderValue in @($property.Value.folders)) {
                $folder = [string]$folderValue
                $source = Join-Path $resolvedLibraries.FullPath $folder
                $destination = Join-Path $backupLibraries $folder
                $destinationParent = Split-Path -Parent $destination

                New-Item `
                    -ItemType Directory `
                    -Path $destinationParent `
                    -Force |
                    Out-Null

                Move-Item `
                    -LiteralPath $source `
                    -Destination $destination

                [void]$movedFolders.Add([pscustomobject]@{
                    Source = $destination
                    Destination = $source
                })
            }
        }

        foreach ($descriptor in $descriptors) {
            if (-not $changedIds.ContainsKey($descriptor.Id)) {
                continue
            }

            $stagedLibraries = $stagedPackages[$descriptor.Id]

            foreach ($folderValue in $descriptor.Folders) {
                $folder = [string]$folderValue
                $source = Join-Path $stagedLibraries $folder
                $target = Join-Path $resolvedLibraries.FullPath $folder

                [void]$createdTargets.Add($target)

                Copy-Item `
                    -LiteralPath $source `
                    -Destination $target `
                    -Recurse
            }
        }

        $lockEntries = [ordered]@{}

        foreach ($descriptor in $descriptors) {
            $lockEntries[$descriptor.Id] = New-SELibsLockEntry `
                -Descriptor $descriptor `
                -Direct:$finalDirectDependencies.Contains($descriptor.Id) `
                -Files (Get-SELibsFolderFiles `
                    -LibrariesRoot $resolvedLibraries.FullPath `
                    -Folders $descriptor.Folders)
        }

        $newManifest = [ordered]@{
            schemaVersion = 1
            librariesPath = $resolvedLibraries.RelativePath
            dependencies = $finalDirectDependencies
        }

        $newLock = [ordered]@{
            schemaVersion = 1
            registry = $registry.Source
            packages = $lockEntries
        }

        try {
            Write-SELibsJsonAtomic -Path $lockPath -Value $newLock
            Write-SELibsJsonAtomic -Path $manifestPath -Value $newManifest
        }
        catch {
            Restore-SELibsProjectFile `
                -Path $manifestPath `
                -OriginalContent $oldManifestContent

            Restore-SELibsProjectFile `
                -Path $lockPath `
                -OriginalContent $oldLockContent

            throw
        }

        Write-Output (
            "Updated $canonicalId $oldDirectVersion -> " +
            "$($updatedDescriptor.Version)."
        )

        foreach ($descriptor in $descriptors) {
            if ($descriptor.Id -eq $canonicalId) {
                continue
            }

            $existingProperty = Get-SELibsObjectProperty `
                -Object $lock.packages `
                -Name $descriptor.Id

            if ($null -eq $existingProperty) {
                Write-Output (
                    "Installed dependency " +
                    "$($descriptor.Id) $($descriptor.Version)."
                )
            }
            elseif (
                [string]$existingProperty.Value.version -ne
                $descriptor.Version
            ) {
                Write-Output (
                    "Updated dependency $($descriptor.Id) " +
                    "$($existingProperty.Value.version) -> " +
                    "$($descriptor.Version)."
                )
            }
        }

        foreach ($property in $removedProperties) {
            Write-Output (
                "Removed unused dependency " +
                "$($property.Name) $($property.Value.version)."
            )
        }
    }
    catch {
        foreach ($target in $createdTargets) {
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        }

        for (
            $index = $movedFolders.Count - 1;
            $index -ge 0;
            $index--
        ) {
            $moved = $movedFolders[$index]

            if (Test-Path -LiteralPath $moved.Source) {
                $parent = Split-Path -Parent $moved.Destination
                New-Item -ItemType Directory -Path $parent -Force | Out-Null

                Move-Item `
                    -LiteralPath $moved.Source `
                    -Destination $moved.Destination
            }
        }

        Restore-SELibsProjectFile `
            -Path $manifestPath `
            -OriginalContent $oldManifestContent

        Restore-SELibsProjectFile `
            -Path $lockPath `
            -OriginalContent $oldLockContent

        throw
    }
    finally {
        if (Test-Path -LiteralPath $transactionRoot) {
            Remove-Item `
                -LiteralPath $transactionRoot `
                -Recurse `
                -Force
        }

        Remove-SELibsEmptyTransactionParent `
            -TransactionRoot $transactionRoot
    }
}
