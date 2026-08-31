# SELibs package format

The central registry lists repositories that publish SELibs packages. Current
clients discover package IDs and versions from their published GitHub Releases.

## Central registry

The production registry remains schema version 1 for compatibility with older
installed SELibs clients. Its explicit `packages` map contains the established
fallback routes, while current clients additionally read `repositories`:

    {
      "schemaVersion": 1,
      "packages": {
        "Existing.Package": {
          "provider": "github",
          "repository": "Author/repository",
          "releasePrefix": "release/Existing.Package/"
        }
      },
      "repositories": [
        {
          "provider": "github",
          "repository": "Author/repository"
        }
      ]
    }

Older clients ignore the additional `repositories` property and continue using
the explicit package routes. Current clients augment those routes by discovering
stable, non-draft GitHub Releases whose tags use:

    release/Package.Id/2.1.0

The release must contain the matching package manifest asset:

    Package.Id-2.1.0-package.json

A repository can publish any number of packages. Once a repository is listed,
publishing another package there does not require another explicit central
registry entry. Existing explicit routes that are also discovered must agree
with the discovered repository and release prefix.

Package IDs discovered from different repositories must be unique
case-insensitively. SELibs rejects an ambiguous registry instead of choosing
one repository implicitly.

Repository-only schema-version-2 registries are also supported by current
clients. Schema-version-1 explicit registries and the `filesystem` provider
remain supported for deterministic local testing.

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

## Managed-package repair

`selibs status` reports exact added, missing, and checksum-modified managed
paths when installed package content differs from `selibs.lock.json`.

`selibs repair Package.Id` restores one drifted package to the exact version and
source route recorded in the lock. `selibs repair` restores every drifted locked
package. Repair displays a plan and asks for confirmation; `-Force` accepts that
plan without prompting.

Repair stages the locked release first, verifies its component checksum, then
verifies the extracted managed files against the existing lock hashes before
replacing installed folders. A mismatched or republished release is rejected
before installed package files are touched. Repair does not rewrite the project
manifest or lock file.

## Updates

`selibs update` selects the newest stable release of every direct dependency,
resolves one final graph, prints the complete change plan, and asks for
confirmation. `-Force` accepts that plan without prompting.

`selibs update Package.Id` selects the newest stable numeric release exposed by
one package route. `selibs update Package.Id@2.1.0` selects an exact release.

The complete direct and transitive graph is resolved before any installed
folder changes. Existing managed files are checksum-verified, changed packages
are staged, and folder swaps plus manifest and lock updates are rolled back
together if the transaction fails.

A mod contains one exact version of each package. If two dependency paths
require different versions, resolution fails before the transaction starts and
reports both paths so compatible direct-package versions can be selected.
