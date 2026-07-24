# SELibs

SELibs is a global source-library manager and package-routing registry for
Space Engineers mods.

Install SELibs once, add its installation directory to `PATH`, and run it from
the root directory of any mod:

    selibs init

The `selibs.cmd` launcher invokes the Windows PowerShell 5.1-compatible
`selibs.ps1` implementation, so the command works from `cmd.exe` and
PowerShell without copying the manager into every mod.

## Mod setup

From the mod root, run:

    selibs init

SELibs will:

- create `selibs.json`;
- create `.selibs/` for local cache and installation state;
- detect the sole folder below `Data/Scripts`, when one exists;
- otherwise use `Data/Scripts/<mod-root-name>/Libraries`;
- require an explicit path when several script folders exist;
- suggest `/.selibs/` for an existing `.gitignore` without editing it.

An explicit destination can be selected with:

    selibs init `
        -LibrariesPath "Data/Scripts/MyMod/Libraries"

The configured destination must be inside the current mod and end in
`Libraries`.

The mod does not need its own copy of `selibs.ps1` or `selibs.cmd`.

## Files stored in a mod

The intended project-local files are:

    selibs.json
    selibs.lock.json
    .selibs/

`selibs.json` and `selibs.lock.json` are intended to be committed.
`.selibs/` contains local cache and file-ownership state and should normally
be ignored.

The current manifest format is:

    {
      "schemaVersion": 1,
      "librariesPath": "Data/Scripts/MyMod/Libraries",
      "dependencies": {}
    }

## Development

Run the focused verification suite with:

    .\scripts\verify.ps1

The tests execute under Windows PowerShell 5.1 and have no external
dependencies.