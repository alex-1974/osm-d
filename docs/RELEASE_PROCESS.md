# Release process

osm-d keeps normal development on `develop` and treats `main` as the
released line. Minor releases use explicit feature/API checkpoints before
promotion.

## 1. Prepare the release on develop

Before a minor release:

- reconcile `CHANGELOG.md`, `README.md`, `docs/GETTING_STARTED.md` and
  `docs/API_STABILITY.md`;
- add the migration guide for the new minor line;
- compile all supported public consumer probes;
- merge the preparation PR only after Fast CI passes.

## 2. Feature freeze

Run **Create release freeze checkpoint** with:

- `version`: the intended release, for example `0.4.0`;
- `stage`: `feature`;
- `commit`: the exact reviewed full SHA.

The workflow creates the annotated tag
`freeze/feature-X.Y.Z`. Re-running it with the same SHA is idempotent.
An existing tag at another commit is an error; freeze tags are never moved.

## 3. API freeze

After final API review, run the same workflow with `stage=api`. This creates
`freeze/api-X.Y.Z` under the same immutable/idempotent rules.

Only `v*` tags are release-publication events. `freeze/*` tags therefore
cannot publish a package or GitHub Release.

## 4. Release branch and gate

Create `release/X.Y.Z` from the API-freeze commit. Set `RELEASE_VERSION`,
finalize the dated changelog entry and release notes, then run the full Release
Gate. The gate qualifies:

- DMD 2.111.0, 2.112.1 and 2.113.0;
- LDC 1.41.0, 1.42.0 and 1.43.0;
- external consumer and examples builds;
- package/archive smoke;
- malformed-input, interoperability and deterministic round-trip gates.

Promotion to `main` occurs only from the qualified release branch.

## 5. Final release tag and signing

The publication workflow accepts an existing annotated `vX.Y.Z` tag that is
reachable from `main`; it never replaces such a tag. This permits a
maintainer to create and push a locally signed annotated release tag with the
configured hardware-backed signing key before publication.

When no `vX.Y.Z` tag exists, GitHub Actions creates an **annotated but
unsigned** bot tag. CI does not receive a maintainer's hardware signing key or
PIN and therefore must not emulate or weaken that signing boundary.

Accordingly:

- signed final tags are preferred when a maintainer can create them locally;
- automated unsigned annotated final tags remain supported because the
  workspace policy treats signing as SHOULD rather than MUST;
- freeze checkpoint tags are provenance markers and are currently annotated
  but unsigned;
- tag immutability and exact commit identity are enforced regardless of
  signature availability.

The release workflow then verifies the archive from the tag, creates the
versioned archive and checksum, and publishes or resumes the GitHub Release.
