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
- A Calimero node on **core `0.11.0-rc.83`**.

### Which core release?

[`ci/core-version`](ci/core-version) names it, and it is the single source of
truth: every CI job and local script that boots a node reads that file instead
of resolving "the newest core release". That matters because the admin API is
still moving — core rc.17 changed how a node is initialised, rc.23 deleted a
route this SDK called, rc.26 changed a networking default, rc.27 changed how
every id is encoded, rc.32 took the URL out of an application install and rc.38
closed 37 request bodies that had been silently dropping extra keys — and a
job that follows the newest release goes red on a commit of its own that changed
nothing.

rc.39–rc.41 were additive on the wire: no route this SDK calls was removed and
no request body closed further. What they added is served here —
`PUT /account/devices/{id}/label` and `PUT /account/devices/{id}/scope`, the
`label` on a device listing, `identitiesOf` on a context-identity listing,
`revokedFrom` on the node identity, and `X-Blob-Source` on a blob `HEAD`.

⚠️ rc.39 also removed blob discovery from the DHT, which is a behaviour change
rather than a wire one: `context_id` is now the only way to reach a blob a peer
holds, so `getBlob` and `getBlobInfo` take one.

rc.42–rc.83 took things away, and this SDK follows:

- **Log in again after upgrading the node.** Tokens gained a required `key_id`
  claim, so every token an older node minted is refused. Clear the stored
  session and `authenticate` again.
- `getCertificate` (`GET /certificate`) and `teeVerifyQuote`
  (`POST /tee/verify-quote`) are gone; the node serves neither.
- `CreateGroupRequest.groupId` is gone: group ids are derived, and a body naming
  one is a `400`.
- An absent subgroup `visibility` now means `open`. `createGroupInNamespace`
  always sends one, `"open"` unless you say otherwise.
- `setTeeAdmissionPolicy` needs RTMR1–3 as well as MRTD (or the new signed-release
  form), and is a root-guarded owner op.

And it added: `queryContext`, the delegated intent routes (`getIntentRelay` with
`executorKey` and release, context, governance and presence intents), root-guarded
owner ops (`transferOwnership`, `changeNamespaceAdmin`, `ownerDeleteGroup`,
`setTeeAuthoringPolicy`), `signWithAccountRoot`, `linkAccountDevice`,
`sealToAccount`, `Capabilities.canAuthorOnBehalf` with
`openToDelegatedExecution` / `grantAuthorship`, `POST /auth/logout` (now called by
`mero.logout()`), group-keyed SSE subscriptions, typed refusals
(`MeroError.refusal`) and the `ReadOnlyWriteRefused` JSON-RPC error. See
[CHANGELOG.md](CHANGELOG.md).

Bumping to a newer core is a one-line change there, plus whatever wire changes
it brings to `Sources/MeroKit/Admin`.

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

## Sign in with Calimero Cloud (mobile)

Mobile apps sign in with **Calimero Cloud** only: the person approves this
device with their passkey on the Calimero wallet (in the system auth sheet),
the wallet returns a certificate for a device key that never leaves the app,
and the app talks to the hosted relay that serves their account. No node URL,
no password.

```swift
import MeroKitUI

@StateObject private var client = MeroClient()
// …
MeroRootView(callbackScheme: "myapp").environmentObject(client)
// or, from your own button:
await client.signInWithCloud(callbackScheme: "myapp")
```

Without the UI layer, `CloudSignIn` does the same in four calls
(`beginEnrolment` → present the URL → `completeEnrolment` → `connect`) and hands
back a `RelayClient` (warranted writes, query reads) plus a `Mero` holding the
relay's Bearer session (admin reads, SSE). See
[Authentication](docs/src/content/docs/get-started/authentication.mdx).

> The hosted wallet returns only to `https://` callbacks today; app-scheme
> callbacks are a pending wallet change. The SDK accepts either. The relay's
> node key is taken from its TEE attestation over TLS; full DCAP quote
> verification is a follow-up (pluggable via `RelayKeyVerifier`).

## Quick start (development node)

The steps below talk to a node you run yourself.

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
    Credentials(username: "alice", password: "s3cr3t")
)
```

These are the admin credentials the node was initialised with. There is no
first-login setup code: core 0.11.0-rc.17 moved admin provisioning to
`merod init`, so `Credentials` has exactly two fields.

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
            // Restores a stored session, else shows the Cloud sign-in screen.
            MeroRootView(callbackScheme: "myapp").environmentObject(client)
        }
    }
}
```

`MeroClient` is an `@MainActor ObservableObject` exposing `isAuthenticated`,
`signInWithCloud(callbackScheme:)`, `handleEnrolmentCallback(_:)`, the session
(`account`, `relayURL`, `isSignedInWithoutRelay`, `connection`),
`runSampleRpc(...)`, `logout()`, and friendly error text. `LoginView` is a single
"Continue with Calimero" button (accessibility ids `loginTitle`,
`cloudSignInButton`, `loginError`, and `loginButton` on the sign-in panel).

A full SwiftUI sample app lives in `Examples/MeroSampleApp`: Cloud sign-in, a
chat example running on the relay, and an explorer for every SDK method, in the
Calimero light design. Its wallet callback scheme is `mero-sample`.

## Runnable example

`MeroExample` is an executable target that tours the whole SDK:

```bash
swift run MeroExample                       # offline demo (SSO URL, capabilities, JSON)

MERO_NODE_URL=http://localhost:4001 \
MERO_USERNAME=dev MERO_PASSWORD=dev-password \
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
