# SELibs

SELibs is a global source-library manager and package-routing registry for
Space Engineers mods.

## Install

Install SELibs for the current Windows user from a downloaded or cloned
release:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies the runtime to `%LOCALAPPDATA%\SELibs`, adds
`%LOCALAPPDATA%\SELibs\bin` to the user `PATH`, and can be run again to replace
an existing managed installation.

Open a new terminal after installation and confirm the command is available:

```shell
selibs help
```

A custom installation directory can be selected with `-InstallRoot`.

Uninstall the default installation with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "$env:LOCALAPPDATA\SELibs\uninstall.ps1"
```

The installer and uninstaller refuse to replace or remove a non-SELibs
directory. Unrelated user `PATH` entries are preserved.

The `selibs.cmd` launcher invokes the Windows PowerShell 5.1-compatible
`selibs.ps1` implementation, so the command works from `cmd.exe` and
PowerShell without copying the manager into every mod.

## Browse available libraries

Show every package exposed by the selected registry and its newest stable
release:

```shell
selibs list
```

The command is read-only. It reports every registry package, its newest stable
numeric release, and its provider. A package is marked `unavailable` when its
route cannot currently produce a supported release.

Use `-RegistryUrl` to inspect another registry:

```powershell
selibs list -RegistryUrl "C:\path\to\packages.json"
```

## View package changelogs

Show the complete changelog published by the newest stable release:

```shell
selibs changelog Mz.ApiProtocol
```

Select an exact release manifest instead:

```shell
selibs changelog Mz.ApiProtocol@0.2.0
```

The selected package manifest contains the complete ordered history and SELibs
prints every version from newest to oldest. Packages published before changelog
metadata was introduced remain installable, but the changelog command reports
that no history is available for those releases.

Use `-RegistryUrl` with the changelog command to inspect another registry.

## Mod setup

From the mod root, run:

```shell
selibs init
```

SELibs will:

- create `selibs.json`;
- create `.selibs/` for local cache and installation state;
- detect the sole folder below `Data/Scripts`, when one exists;
- otherwise use `Data/Scripts/<mod-root-name>/Libraries`;
- require an explicit path when several script folders exist;
- suggest `/.selibs/` for an existing `.gitignore` without editing it.

Select an explicit destination with:

```shell
selibs init -LibrariesPath "Data/Scripts/MyMod/Libraries"
```

The configured destination must be inside the current mod and end in
`Libraries`.

Install the first direct library with an exact version:

```shell
selibs add Mz.ApiProtocol@0.2.0
```

SELibs resolves exact transitive dependencies through the central routing
registry, verifies component checksums, installs source folders, updates
`selibs.json`, and creates `selibs.lock.json`.

Additional direct libraries can be added with the same command. SELibs
re-resolves the complete exact-version dependency graph and installs shared
dependencies only once.

Inspect the installed graph and check for newer stable releases with:

```shell
selibs status
```

The status command is read-only. It reports each direct and transitive package,
its installed version, the newest stable release currently exposed by the
registry, and whether its checksum-managed files were modified. A newer
transitive release is informational; updating a direct package still
re-resolves the complete compatible graph.

Remove a direct library with:

```shell
selibs remove Mz.ApiProtocol
```

Update a direct library to its newest stable release with:

```shell
selibs update Mz.ApiProtocol
```

Or select an exact release:

```shell
selibs update Mz.ApiProtocol@0.3.0
```

The complete graph is resolved again, so transitive dependencies are upgraded,
installed, or removed as required.

Packages no longer reachable from another direct dependency are removed
automatically and reported. Managed source files are checksum-verified before
updates and removals; SELibs refuses to replace or delete locally modified
package files.

The mod does not need its own copy of `selibs.ps1` or `selibs.cmd`.

## Files stored in a mod

The intended project-local files are:

```text
selibs.json
selibs.lock.json
.selibs/
```

`selibs.json` and `selibs.lock.json` are intended to be committed.
`.selibs/` contains local cache and file-ownership state and should normally
be ignored.

The current manifest format is:

```json
{
  "schemaVersion": 1,
  "librariesPath": "Data/Scripts/MyMod/Libraries",
  "dependencies": {}
}
```

## Development

Run the focused verification suite with:

```powershell
.\scripts\verify.ps1
```

The tests execute under Windows PowerShell 5.1 and have no external
dependencies.

Package publishing conventions are documented in
[`docs/package-format.md`](docs/package-format.md).
