function Get-SELibsComparablePath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $trimmed = $Path.Trim().Trim('"')
    $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)

    try {
        $normalized = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        $normalized = $expanded
    }

    return $normalized.TrimEnd([char[]]"\/").ToLowerInvariant()
}

function Add-SELibsPathEntry {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $entryValue = [System.IO.Path]::GetFullPath($Entry)
    $entryComparison = Get-SELibsComparablePath -Path $entryValue
    $result = New-Object System.Collections.ArrayList

    foreach ($segment in @($PathValue -split ";")) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if (
            (Get-SELibsComparablePath -Path $segment) -eq
            $entryComparison
        ) {
            continue
        }

        [void]$result.Add($segment)
    }

    [void]$result.Add($entryValue)
    return ($result -join ";")
}

function Remove-SELibsPathEntry {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $entryComparison = Get-SELibsComparablePath -Path $Entry
    $result = New-Object System.Collections.ArrayList

    foreach ($segment in @($PathValue -split ";")) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if (
            (Get-SELibsComparablePath -Path $segment) -eq
            $entryComparison
        ) {
            continue
        }

        [void]$result.Add($segment)
    }

    return ($result -join ";")
}

function Write-SELibsInstallJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $json = $Value | ConvertTo-Json -Depth 10
    $content = ($json + "`n").Replace("`r`n", "`n")

    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        $encoding
    )
}

function Read-SELibsInstallMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $markerPath = Join-Path $InstallRoot "install.json"

    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw (
            "Installation root '$InstallRoot' is not managed by SELibs " +
            "because install.json is missing."
        )
    }

    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw |
            ConvertFrom-Json
    }
    catch {
        throw (
            "Could not read SELibs installation marker '$markerPath': " +
            $_.Exception.Message
        )
    }

    if (
        $null -eq $marker.schemaVersion -or
        $marker.schemaVersion -ne 1 -or
        [string]$marker.product -ne "SELibs" -or
        [string]$marker.binPath -ne "bin"
    ) {
        throw (
            "Installation root '$InstallRoot' does not contain a " +
            "supported SELibs installation marker."
        )
    }

    return $marker
}

function Set-SELibsUserPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BinPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Add", "Remove")]
        [string]$Action
    )

    $current = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    if ($null -eq $current) {
        $current = ""
    }

    if ($Action -eq "Add") {
        $updated = Add-SELibsPathEntry `
            -PathValue $current `
            -Entry $BinPath
    }
    else {
        $updated = Remove-SELibsPathEntry `
            -PathValue $current `
            -Entry $BinPath
    }

    if ($updated -ne $current) {
        [Environment]::SetEnvironmentVariable(
            "Path",
            $updated,
            "User"
        )

        return $true
    }

    return $false
}

function Invoke-SELibsInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [switch]$SkipPathUpdate
    )

    $source = [System.IO.Path]::GetFullPath($SourceRoot)
    $destination = [System.IO.Path]::GetFullPath($InstallRoot)
    $binPath = Join-Path $destination "bin"

    $requiredSources = @(
        "selibs.cmd",
        "selibs.ps1",
        "uninstall.ps1",
        "lib\SELibs.Package.ps1",
        "lib\SELibs.Install.ps1"
    )

    foreach ($relativePath in $requiredSources) {
        $path = Join-Path $source $relativePath

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required installer source '$path' does not exist."
        }
    }

    if (
        (Get-SELibsComparablePath -Path $source) -eq
        (Get-SELibsComparablePath -Path $destination)
    ) {
        throw "InstallRoot must differ from the SELibs source directory."
    }

    if (Test-Path -LiteralPath $destination) {
        [void](Read-SELibsInstallMarker -InstallRoot $destination)
    }

    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $staging = Join-Path `
        $parent `
        (".selibs-install-" + [Guid]::NewGuid().ToString("N"))

    $previous = Join-Path `
        $parent `
        (".selibs-previous-" + [Guid]::NewGuid().ToString("N"))

    $movedExisting = $false
    $installedNew = $false
    $oldUserPath = $null
    $pathUpdated = $false

    try {
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $staging "bin\lib") `
            -Force |
            Out-Null

        New-Item `
            -ItemType Directory `
            -Path (Join-Path $staging "lib") `
            -Force |
            Out-Null

        Copy-Item `
            -LiteralPath (Join-Path $source "selibs.cmd") `
            -Destination (Join-Path $staging "bin\selibs.cmd")

        Copy-Item `
            -LiteralPath (Join-Path $source "selibs.ps1") `
            -Destination (Join-Path $staging "bin\selibs.ps1")

        Copy-Item `
            -LiteralPath (Join-Path $source "lib\SELibs.Package.ps1") `
            -Destination (
                Join-Path $staging "bin\lib\SELibs.Package.ps1"
            )

        Copy-Item `
            -LiteralPath (Join-Path $source "uninstall.ps1") `
            -Destination (Join-Path $staging "uninstall.ps1")

        Copy-Item `
            -LiteralPath (Join-Path $source "lib\SELibs.Install.ps1") `
            -Destination (
                Join-Path $staging "lib\SELibs.Install.ps1"
            )

        Write-SELibsInstallJson `
            -Path (Join-Path $staging "install.json") `
            -Value ([ordered]@{
                schemaVersion = 1
                product = "SELibs"
                binPath = "bin"
                files = @(
                    "bin/selibs.cmd",
                    "bin/selibs.ps1",
                    "bin/lib/SELibs.Package.ps1",
                    "uninstall.ps1",
                    "lib/SELibs.Install.ps1"
                )
            })

        if (Test-Path -LiteralPath $destination) {
            Move-Item `
                -LiteralPath $destination `
                -Destination $previous

            $movedExisting = $true
        }

        Move-Item `
            -LiteralPath $staging `
            -Destination $destination

        $installedNew = $true

        if (-not $SkipPathUpdate) {
            $oldUserPath = [Environment]::GetEnvironmentVariable(
                "Path",
                "User"
            )

            $pathUpdated = Set-SELibsUserPath `
                -BinPath $binPath `
                -Action Add
        }

        if (Test-Path -LiteralPath $previous) {
            Remove-Item `
                -LiteralPath $previous `
                -Recurse `
                -Force
        }

        Write-Output "Installed SELibs."
        Write-Output "Location: $destination"
        Write-Output "Command directory: $binPath"

        if ($SkipPathUpdate) {
            Write-Output "User PATH was not changed."
        }
        elseif ($pathUpdated) {
            Write-Output (
                "Added the command directory to the user PATH. " +
                "Open a new terminal before running selibs."
            )
        }
        else {
            Write-Output "The command directory is already on the user PATH."
        }
    }
    catch {
        if (
            -not $SkipPathUpdate -and
            $pathUpdated
        ) {
            [Environment]::SetEnvironmentVariable(
                "Path",
                $oldUserPath,
                "User"
            )
        }

        if (
            $installedNew -and
            (Test-Path -LiteralPath $destination)
        ) {
            Remove-Item `
                -LiteralPath $destination `
                -Recurse `
                -Force
        }

        if (
            $movedExisting -and
            (Test-Path -LiteralPath $previous)
        ) {
            Move-Item `
                -LiteralPath $previous `
                -Destination $destination
        }

        throw
    }
    finally {
        foreach ($temporaryPath in @($staging, $previous)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item `
                    -LiteralPath $temporaryPath `
                    -Recurse `
                    -Force
            }
        }
    }
}

function Invoke-SELibsUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [switch]$SkipPathUpdate
    )

    $destination = [System.IO.Path]::GetFullPath($InstallRoot)

    if (-not (Test-Path -LiteralPath $destination)) {
        Write-Output "SELibs is already uninstalled."
        return
    }

    [void](Read-SELibsInstallMarker -InstallRoot $destination)

    $binPath = Join-Path $destination "bin"
    $oldUserPath = $null
    $pathUpdated = $false

    try {
        if (-not $SkipPathUpdate) {
            $oldUserPath = [Environment]::GetEnvironmentVariable(
                "Path",
                "User"
            )

            $pathUpdated = Set-SELibsUserPath `
                -BinPath $binPath `
                -Action Remove
        }

        Remove-Item `
            -LiteralPath $destination `
            -Recurse `
            -Force

        Write-Output "Uninstalled SELibs."

        if ($SkipPathUpdate) {
            Write-Output "User PATH was not changed."
        }
        elseif ($pathUpdated) {
            Write-Output "Removed the SELibs command directory from user PATH."
        }
    }
    catch {
        if (
            -not $SkipPathUpdate -and
            $pathUpdated
        ) {
            [Environment]::SetEnvironmentVariable(
                "Path",
                $oldUserPath,
                "User"
            )
        }

        throw
    }
}
