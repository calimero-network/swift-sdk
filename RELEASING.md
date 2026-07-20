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

## Cutting a release (the SwiftPM way)

1. Make sure `master` is green (build + test + lint + UI tests).
2. Tag with a `v`-prefixed semver and push the tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. `.github/workflows/release.yml` fires on `v*` tags: it re-runs `swift build -c
   release` + `swift test`, then cuts a **GitHub Release** with generated notes.

That’s it — consumers can now resolve `0.1.0`. (A GitHub Release is optional for
SPM resolution but nice for humans/changelogs; the tag is what SPM needs.)

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

A `MeroKit.podspec` is provided. To publish to the CocoaPods trunk after tagging:

```bash
pod spec lint MeroKit.podspec
pod trunk push MeroKit.podspec
```

Bump `spec.version` in `MeroKit.podspec` to match the Git tag each release. Most
consumers should prefer SPM; the podspec exists only for teams still on CocoaPods.
