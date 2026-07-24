[CmdletBinding()]
param(
    [string]$InstallRoot = (
        Join-Path $env:LOCALAPPDATA "SELibs"
    ),

    [switch]$SkipPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\SELibs.Install.ps1")

Invoke-SELibsInstall `
    -SourceRoot $PSScriptRoot `
    -InstallRoot $InstallRoot `
    -SkipPathUpdate:$SkipPathUpdate
