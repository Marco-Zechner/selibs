# SELibs package format

The central registry routes a package ID to its publishing location. It does
not list package versions or dependencies.

## Central routing entry

A GitHub-hosted package uses:

    {
      "provider": "github",
      "repository": "Author/repository",
      "releasePrefix": "library-name-v"
    }

For example, version `2.1.0` is discovered from the release tag
`library-name-v2.1.0`.

The `filesystem` provider exists for deterministic local testing.

## Release assets

A release contains:

    Package.Id-2.1.0-package.json
    Package.Id-2.1.0-component.zip

The package manifest contains:

    {
      "schemaVersion": 1,
      "id": "Package.Id",
      "version": "2.1.0",
      "changelog": [
        {
          "version": "2.1.0",
          "changes": [
            "Added the new routing API.",
            "Improved invalid-packet diagnostics."
          ]
        },
        {
          "version": "2.0.0",
          "changes": [
            "Published the previous stable release."
          ]
        }
      ],
      "dependencies": {
        "Other.Library": "1.0.0"
      },
      "folders": [
        "Package.Id.Core",
        "Package.Id.SpaceEngineers"
      ],
      "component": {
        "asset": "Package.Id-2.1.0-component.zip",
        "sha256": "<64 lowercase hexadecimal characters>"
      }
    }

The optional `changelog` array is ordered from newest to oldest. Its first
entry must match the manifest version, versions must be unique, and every entry
must contain at least one non-empty change. The field remains optional so
schema-version-1 packages published before changelog support remain installable.

`selibs changelog Package.Id` reads the complete history from the newest stable
release. Select an exact release with
`selibs changelog Package.Id@2.1.0`.

Dependency versions are exact in the initial implementation.

The component archive contains only its own source folders beneath one
`Libraries` root:

    Libraries/
      Package.Id.Core/
      Package.Id.SpaceEngineers/

SELibs rejects archive entries outside `Libraries`, path traversal, undeclared
folders, folder collisions, and checksum mismatches.

## Project reconciliation

`selibs add` resolves every direct dependency in `selibs.json`, detects exact
version conflicts, and installs only packages not already present in the lock.

`selibs remove` removes the selected direct dependency and all locked packages
that are no longer reachable from another direct dependency. Before deleting
owned folders, SELibs verifies that the recorded files have not been added,
removed, or modified.

## Updates

`selibs update Package.Id` selects the newest stable numeric release exposed by
the package route. `selibs update Package.Id@2.1.0` selects an exact release.

The complete direct and transitive graph is resolved before any installed
folder changes. Existing managed files are checksum-verified, changed packages
are staged, and folder swaps plus manifest and lock updates are rolled back
together if the transaction fails.
