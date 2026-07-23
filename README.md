# MeroKit — Calimero Swift SDK

Native Swift SDK for building iOS apps against a **remote** [Calimero](https://calimero.network)
node. It's a faithful port of [`@calimero-network/mero-js`](https://github.com/calimero-network/mero-js)'s
wire contract — auth + token refresh, JSON-RPC contract calls, the admin API,
SSO deep-link login, and live SSE events — in idiomatic `async/await` Swift, with
an optional SwiftUI layer (`MeroKitUI`).

The device is a **thin client**: it never runs a node. Every capability is an
HTTP(S) call to a remote node's endpoints.

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
let contexts = try await mero.admin.getContexts()
let providers = try await mero.auth.getProviders()
```

### 5. Live events (SSE)

```swift
let task = Task {
    for try await event in mero.events(contextIds: [contextId]) {
        // event: ContextEvent { contextId, kind, payload }
        await reload()
    }
}
// task.cancel() closes the stream.
```

### 6. Log out

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

## Frontend (`MeroKitUI`)

A SwiftUI "frontend" layer ships alongside the core SDK — the native analog of
mero-react's `MeroProvider`/`useMero` + `LoginModal`:

```swift
import MeroKitUI

@main
struct MyApp: App {
    @StateObject private var client = MeroClient()
    var body: some Scene {
        WindowGroup {
            MeroRootView().environmentObject(client)   // routes Login ⇄ Home on auth state
        }
    }
}
```

`MeroClient` is an `@MainActor ObservableObject` exposing `isAuthenticated`,
`login(...)`, `runSampleRpc(...)`, `logout()`, and friendly error text. A full
SwiftUI sample app lives in `Examples/MeroSampleApp`.

## Runnable example

`MeroExample` is an executable target that tours the whole SDK:

```bash
swift run MeroExample                       # offline demo (SSO URL, capabilities, JSON)

MERO_NODE_URL=http://localhost:4001 \
MERO_USERNAME=dev MERO_PASSWORD=dev-password \
MERO_BOOTSTRAP_SECRET=… \
swift run MeroExample                       # full online flow: auth → identity → contexts → rpc → logout
```

## Testing

The suite is a Swift test pyramid:

- **Unit tests** (`Tests/MeroKitTests`) — JWT/token parsing, JSONValue, SSO, capabilities,
  retry, and per-method admin request-shape checks.
- **Mocked end-to-end** (`FakeNode` + `EndToEndMockTests`) — a stateful in-memory node
  (the Swift analog of nock/msw) drives whole journeys: login → refresh mid-flight →
  concurrent single-flight refresh → revoked-family re-login → logout. No node needed.
- **Frontend view-model tests** (`Tests/MeroKitUITests`) — fast `MeroClient` tests
  (login/logout/RPC/error) against `FakeNode`; no simulator needed.
- **UI tests / XCUITest** (`Examples/MeroSampleApp/UITests`) — the Swift analog of
  Playwright: drives the real SwiftUI app in the iOS Simulator (type → tap → assert
  on-screen) against an in-app mock backend.
- **Live e2e** (`Tests/MeroKitE2ETests`) — runs against a real `merod`; **skips itself**
  unless `MERO_E2E_NODE_URL` is set, so normal CI stays green. The `E2E` workflow boots a
  released node and runs these.

```bash
swift build
swift test                                  # unit + mocked e2e (live e2e auto-skips)
swiftlint lint --strict                     # brew install swiftlint
xcrun swift-format lint -r Sources Tests

# live e2e against a running node:
MERO_E2E_NODE_URL=http://localhost:4001 swift test --filter MeroKitE2ETests

# UI tests (XCUITest) in the simulator:
cd Examples/MeroSampleApp && xcodegen generate
xcodebuild test -project MeroSampleApp.xcodeproj -scheme MeroSampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

CI (`.github/workflows/`): `ci.yml` (build + test + lint), `ui.yml` (XCUITest on the
iOS Simulator), `e2e.yml` (live-node run, manual/weekly), `release.yml` (tag-driven release).

## Releasing

Swift packages are distributed as a **Git repo + semver tags** — there's no
`npm publish`. Pushing a `vX.Y.Z` tag *is* the release. See [`RELEASING.md`](RELEASING.md)
for the full flow (tags, GitHub Releases, Swift Package Index, and the optional CocoaPods podspec).

## License

MIT © Calimero Ltd
