[CmdletBinding()]
param(
    [string]$InstallRoot = (
        Join-Path $env:LOCALAPPDATA "SELibs"
    ),

    [switch]$SkipPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path `
    $InstallRoot `
    "lib\SELibs.Install.ps1"

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    $modulePath = Join-Path $PSScriptRoot "lib\SELibs.Install.ps1"
}

. $modulePath

Invoke-SELibsUninstall `
    -InstallRoot $InstallRoot `
    -SkipPathUpdate:$SkipPathUpdate
