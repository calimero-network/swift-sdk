# MeroKit — Calimero Swift SDK

Native Swift SDK for building iOS apps against a **remote** [Calimero](https://calimero.network)
node. It's a faithful port of [`@calimero-network/mero-js`](https://github.com/calimero-network/mero-js)'s
wire contract — auth + token refresh, JSON-RPC contract calls, the admin API, and
SSO deep-link login — in idiomatic `async/await` Swift.

The device is a **thin client**: it never runs a node. Every capability is an
HTTP(S) call to a remote node's endpoints.

> Status: **M1 — transport + auth core + full Admin API.** Events (SSE), the
> optional SwiftUI UI kit (`MeroKitUI`), and blob streaming polish are on the
> roadmap (`ROADMAP` milestones M3/M5). See `ROADMAP-TASKS/task-1-ios-sdk.md`.

## Requirements

- Swift 5.9+ (built and tested on Swift 6)
- iOS 15+ / macOS 12+
- Zero third-party dependencies (uses `URLSession`, `Foundation`, `Security`).

## Installation (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/calimero-network/swift-sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "MeroKit", package: "swift-sdk"),
    ]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

## Quick start

### 1. Create the client

```swift
import MeroKit

let mero = Mero(config: MeroConfig(
    baseURL: URL(string: "https://your-node.example")!,
    // Persist tokens securely in the Keychain (defaults to in-memory otherwise):
    tokenStore: KeychainTokenStore()
))
```

### 2. Log in

**Direct credentials** (first-party apps):

```swift
let tokens = try await mero.authenticate(
    Credentials(username: "alice", password: "s3cr3t",
                bootstrapSecret: "…") // only needed on a fresh node's first login
)
```

**Hosted SSO** (deep-link, matches the web redirect flow) — open the URL in
`ASWebAuthenticationSession`, then feed the callback back in:

```swift
let loginURL = Mero.buildAuthLoginUrl(
    nodeUrl: "https://your-node.example",
    options: AuthLoginOptions(callbackUrl: "myapp://auth-callback", mode: "login")
)
// … present loginURL via ASWebAuthenticationSession …

// On the callback URL:
if let callback = Mero.parseAuthCallback(callbackURL.absoluteString) {
    await mero.setTokenData(from: callback)
}
```

### 3. Call a contract (JSON-RPC)

```swift
struct Post: Decodable { let id: String; let title: String }

let post: Post = try await mero.rpc.execute(
    contextId: "…",
    method: "get_post",
    argsJson: ["id": "42"]
)
```

### 4. Admin / auth APIs

```swift
let contexts = try await mero.admin.listContexts()
let providers = try await mero.auth.getProviders()
```

### 5. Log out

```swift
await mero.logout() // clears the token bundle from memory and the store
```

## How auth works (the important part)

- **Refresh is reactive.** The SDK never refreshes proactively — the server
  rejects refresh while the access token is still valid. A `401 token_expired`
  drives a single refresh and one retry.
- **Refresh tokens are single-use** (core#3083). `Mero` is an `actor`, so
  concurrent 401s share one in-flight refresh; the rotated refresh token is
  persisted immediately. A refresh also re-reads the store first, so if another
  process/extension already rotated, that bundle is adopted instead of replaying
  a consumed token (which would revoke the whole family).
- **Terminal errors force re-login.** `x-auth-error: token_reuse | token_revoked`
  is never retried — it surfaces as `MeroError.authRevoked` and the token bundle
  is cleared.

## Development

```bash
swift build
swift test
swiftlint lint --strict          # brew install swiftlint
xcrun swift-format lint -r Sources Tests
```

## License

MIT © Calimero Ltd
