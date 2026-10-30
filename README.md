# MeroKit — Calimero Swift SDK

The native Swift SDK for **Calimero 1.0**, the confidential cloud. It verifies a
node's TDX attestation, seals every request to it, signs people in with
passkeys, and gives a SwiftUI app its organizations, teams, app instances and
live events. It is the Swift port of
[mero-js](https://github.com/calimero-network/mero-js) ≥27 `CalimeroClient`:
the same methods, the same typed errors, the same retry and failover rules.

- Swift 5.9+, iOS 15+ / macOS 12+, no third-party dependencies.
- A Calimero 1.0 cluster (core `1.0.0-rc.3`, [`ci/core-version`](ci/core-version)),
  or `merod local` for development.
- Docs: <https://calimero-network.github.io/swift-sdk/>

```swift
.package(url: "https://github.com/calimero-network/swift-sdk", branch: "master")
```

| Product | What it is |
| --- | --- |
| `MeroKit` | `CalimeroClient`, the sealed channel, TEE trust, passkeys (`SoftPasskey`), the app layer protocols (`MeroAppBackend`, `ContextContract`). |
| `MeroKitUI` | `MeroAppSession`, `MeroClient`, `CloudAppBackend`, `PlatformPasskey`, the consent page in the system browser. |
| `MeroKitTestSupport` | `InMemoryAppBackend`, `RecordingContextContract`, `FakeCloudNode` + `FakeCloud` (a node that runs the real sealed channel, and a cluster in memory), `MockURLProtocol`. |

## The client

```swift
import MeroKit

// Development: `cargo run -p merod -- local` (3 nodes, mock attestation).
let client = CalimeroClient(CalimeroClientOptions(
    baseUrl: "http://127.0.0.1:2501", nodes: ["http://127.0.0.1:2502"], policy: .development))
try await client.signUp(SoftPasskey(), name: "ada")

// Production: real TDX quotes from a signed mero-tee release ≥ 2.3.109.
let cloud = CalimeroClient(CalimeroClientOptions(baseUrl: nodeURL, policy: .production))
try await cloud.signIn(PlatformPasskey())

let org = try await cloud.createOrg("Acme")
let app = try await cloud.createApp("chat", bundle: .package("com.calimero.chat"), org: org)
_ = try await cloud.call(app, "send_message", ["message": "hi"])   // POST /apps/{app}/intents
let page = try await cloud.view(app, "get_messages", [:])          // POST /apps/{app}/views
for try await event in cloud.events(app) { print(event.kind) }      // sealed SSE
```

- **Transport.** Only `/health` and `/attestation` are plaintext. Everything
  else goes through `calimero/sealed-http/v2` (Noise NK to the attested
  transport key), byte for byte with core's `calimero-sealed`.
- **Trust.** `CloudPolicy.production` checks the release floor, the release's
  Sigstore signature, the quote's DCAP chain against Intel's collateral
  (fetched from Intel's PCS) and the image's measurements. Mock quotes pass
  only with `allowMock` (`.development`).
- **Sessions.** Passkey session `v2.…` (15 min) and refresh token `rt_…`; a
  `401` triggers one shared refresh. `421 WRONG_NODE` moves to the next node,
  `421 NOT_LEADER` to the named leader.
- **Retries.** A call or view that meets `503` or no answer is sent again with
  the same idempotency key (6 retries, 200 ms → 2 s), then `UnavailableError`.
- **Errors.** `CalimeroError` and its subclasses: `AppError{appCode, fields}`,
  `ConfirmRequired`, `LoginRequired`, `WrongNode`, `NotLeader`, `NotFound`,
  `UnavailableError`, `ArgsTooLarge`, `IdempotencyMismatch`,
  `ReleaseDeadlineError`, `ConsentStale`, `TrapError`; plus `ConfirmCancelled`.
- **Approvals** happen on the node's consent page: `requestConsent` → open the
  `url` in the system browser → `consentResult`.

## The app layer (SwiftUI)

```swift
import MeroKitUI

@StateObject var session = MeroAppSession(
    packageName: "com.calimero.chat", callback: .scheme("merochat", path: "consent"),
    config: MeroProviderConfig(nodeURL: "https://node.example"))

.task { await session.restore() }
.onOpenURL { url in Task { await session.handle(url) } }
```

`session.backend` is a `MeroAppBackend`. Its names predate 1.0 and map one to
one: namespace → organization, subgroup → team, context → app instance,
application → package, invitation → invite token (`OrgInvitation`). See
[the app layer guide](docs/src/content/docs/guides/app-session.mdx).

## The sample app

[`Examples/MeroSampleApp`](Examples/MeroSampleApp) (`xcodegen generate`) is
the SDK Explorer: Home, Chat (mero-chat, `com.calimero.chat`, on orgs and
teams) and SDK tabs. Sign in to a Calimero Cloud cluster with a passkey, or
"Manually enter node URL" for `merod local` (mock attestation, software
passkey). `-uitest-mock` runs it against an in-app cluster; that is what the
XCUITest suite drives.

## Development

```sh
swift build && swift test
swiftlint lint --strict
swift-format lint --recursive --strict Sources Tests Examples
MERO_E2E_NODE_URL=http://127.0.0.1:2501 swift test --filter MeroKitE2ETests   # against merod local
```
