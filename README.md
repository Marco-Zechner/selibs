# SELibs

SELibs is a source-library manager and package-routing registry for
Space Engineers mods.

The initial executable slice provides a single Windows PowerShell 5.1
compatible script that initializes a mod for future package management.

## Mod setup

Copy `selibs.ps1` to the mod root and run:

    .\selibs.ps1 init

SELibs will:

- create `selibs.json`;
- create `.selibs/` for local manager state;
- detect the sole folder below `Data/Scripts`, when one exists;
- otherwise use `Data/Scripts/<mod-root-name>/Libraries`;
- require an explicit path when several script folders exist;
- suggest missing `.gitignore` entries without changing the file.

An explicit path can be selected with:

    .\selibs.ps1 init `
        -LibrariesPath "Data/Scripts/MyMod/Libraries"

The configured destination must be inside the mod and end in `Libraries`.

## Current manifest

    {
      "schemaVersion": 1,
      "librariesPath": "Data/Scripts/MyMod/Libraries",
      "dependencies": {}
    }

`selibs.json` is intended to be committed. Local cache and installation state
will live under `.selibs/`.

## Development

Run the focused verification suite with:

    .\scripts\verify.ps1

The test suite uses Windows PowerShell directly and has no external
dependencies.