# Releasing MeroKit

Short version: **Swift has no “npm publish”.** A Swift Package Manager (SPM)
package is distributed as a **public Git repo + semver Git tags**. Consumers point
their `Package.swift` at the repo URL and a version; SPM resolves the tag directly.
There is nothing to upload to a central host for the SwiftPM path.

## How consumers depend on it

```swift
dependencies: [
    .package(url: "https://github.com/calimero-network/swift-sdk.git", from: "0.1.0"),
]
```

SPM reads the Git tags of this repo and picks the best match for `from:` /
`.upToNextMajor(...)` etc. So “releasing a version” == **pushing a tag**.

## Cutting a release: merge to `master`

Releases are automatic. Every push to `master` runs
[`release-on-merge.yml`](.github/workflows/release-on-merge.yml), which runs
semantic-release ([`.releaserc.json`](.releaserc.json)) over the conventional
commits since the last `v*` tag:

| Commit (the squash-merge title) | Release |
| --- | --- |
| `feat: …` | minor |
| `fix:`, `chore:`, `docs:`, `refactor:`, `perf:` | patch |
| `ci:`, `test:`, `build:` | none |
| `feat!: …`, or a `BREAKING-CHANGE:` footer | major |

Only the hyphenated `BREAKING-CHANGE` keyword counts: a body line that happens
to start with "breaking change" does not make a major (see the comment in
`.releaserc.json`).

When there is a release, it pushes the tag `v<version>` and creates the GitHub
Release with notes made from those commits, as the organization's GitHub App
(`vars.ACTIONS_APP_ID`, `secrets.ACTIONS_APP_PRIVATE_KEY`; the App must be
installed on this repository). A tag pushed with GITHUB_TOKEN would not start
other workflows. [`release.yml`](.github/workflows/release.yml) then builds and
tests the tag (`swift build -c release`, `swift test`); it creates a GitHub
Release only for a tag pushed by hand, so a release never gets two.

To release by hand anyway (a hotfix tag, say), push a `v`-prefixed semver tag;
`release.yml` verifies it and cuts the GitHub Release:

```bash
git tag v0.7.1
git push origin v0.7.1
```

### CHANGELOG.md

[CHANGELOG.md](CHANGELOG.md) stays hand-written and is not touched by the
release: each change adds its own section in its pull request, headed
`## Unreleased: <what changed>`. The released version of each change is the
first `v*` tag after its merge, and the generated GitHub Release lists the
commits per version. (A release commit written back to `master` would need the
App to bypass branch protection, and the sections are prose a generated
changelog would duplicate.)

### Release notes for a core bump

Every release that moves `ci/core-version` gets an entry in
[CHANGELOG.md](CHANGELOG.md) with an **Upgrade notes** section. Name anything a
caller must do by hand. For core rc.83 that is: log in again after the node
upgrade (tokens need a `key_id` claim, so older tokens are refused), and
`mero.logout()` is now `async`.

### Versioning policy

Semver. We track the `mero-js` wire contract this SDK implements — aim to keep the
major aligned (e.g. **MeroKit 7.x ⇄ mero-js 7.x**) once we reach 1.0. Pre-1.0
(`0.x`) the minor may carry breaking changes.

## Discovery — the closest thing to “npm search”

The [**Swift Package Index**](https://swiftpackageindex.com) is the community
directory (search, docs, compatibility matrix). It’s an *index*, not a host — you
submit the repo URL once and it tracks the tags automatically. To list MeroKit:
open a PR adding the repo URL to
[SwiftPackageIndex/PackageList](https://github.com/SwiftPackageIndex/PackageList).
Add a `.spi.yml` to control which products/platforms it documents (optional).

## Emerging: the Swift Package Registry

Swift now has a formal package-registry protocol (`swift package-registry`,
SE-0292/SE-0391) — a genuine npm-style registry. Adoption is still limited and
GitHub doesn’t broadly host one yet, so **git-tag distribution remains the
default**. If we later publish to a registry, the release flow becomes
`swift package-registry publish` in `release.yml`; no code changes needed.

## CocoaPods (optional, for non-SPM consumers)

Not part of the automatic release: since 0.7.0 MeroKit depends on
swift-openapi-runtime and swift-http-types, which `MeroKit.podspec` cannot
express (they are not on the CocoaPods trunk), so the pod does not build as it
stands. Before that, the podspec was published by hand after tagging:

```bash
pod spec lint MeroKit.podspec
pod trunk push MeroKit.podspec
```

Bump `spec.version` in `MeroKit.podspec` to match the Git tag each release. Most
consumers should prefer SPM; the podspec exists only for teams still on CocoaPods.
