# MeroKit — Calimero Swift SDK

The native Swift SDK for **Calimero 1.0**, the confidential cloud. It verifies a
node's TDX attestation, seals every request to it, signs people in with
passkeys, and gives a SwiftUI app its organizations, teams, app instances and
live events. It is the Swift port of
[mero-js](https://github.com/calimero-network/mero-js) ≥27 `CalimeroClient`:
the same methods, the same typed errors, the same retry and failover rules.

- Swift 5.9+, iOS 15+ / macOS 12+. Dependencies: Apple's
  [swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime) and
  [swift-http-types](https://github.com/apple/swift-http-types), pinned exactly.
- A Calimero 1.0 cluster (core `1.0.0-rc.10`, [`ci/core-version`](ci/core-version)),
  or `merod local` for development.
- Docs: <https://calimero-network.github.io/swift-sdk/>

```swift
.package(url: "https://github.com/calimero-network/swift-sdk", branch: "master")
```

| Product | What it is |
| --- | --- |
| `MeroKit` | `CalimeroClient` and its generated API facade, the sealed channel, TEE trust, passkeys (`SoftPasskey`), the app layer protocols (`MeroAppBackend`, `ContextContract`). |
| `MeroAPI` | The client generated from core's OpenAPI document: `Components.Schemas.*`, `Operations.*`, the types the facade answers. |
| `MeroKitUI` | `MeroAppSession`, `MeroClient`, `CalimeroAppBackend`, `PlatformPasskey`, the consent page in the system browser. |
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

let org = try await cloud.orgs.create(name: "Acme").orgId
let app = try await cloud.apps.create(name: "chat", package: "com.calimero.chat", org: org).appId
_ = try await cloud.call(app, "send_message", ["message": "hi"])   // POST /apps/{app}/intents
let page = try await cloud.view(app, "get_messages", [:])          // POST /apps/{app}/views
for try await event in cloud.events(app) { print(event.kind) }      // sealed SSE
```

## The node API, generated

Every route of the node API is a method of `CalimeroClient`, grouped as the
OpenAPI document groups them (`x-calimero-group`): `auth`, `apps`, `orgs`,
`consent`, `ops`, and `packagesApi`, `deploymentsApi` (sign-up, deployers,
deployments) and `publicApi`, which take an `Api` suffix because
`CalimeroClient` already has `packages()` and `deployments()` and `public` is
a keyword. Each takes the path parameters, the JSON body's fields and the query
as labelled arguments and answers the typed success value (`import MeroAPI`
to name it); a refusal throws the same typed errors as below.

```swift
let org = try await cloud.orgs.get(org: orgId)               // Operations.OrgGet.Output.Ok.Body.JsonPayload
let invite = try await cloud.orgs.inviteCreate(org: orgId, role: .member, passkey: passkey)
await cloud.useStepUp(PlatformPasskey())                     // answers any 412 without a `passkey:`
try await cloud.orgs.delete(org: orgId)
await cloud.useOperatorSigner(try Ed25519OperatorKey(raw: seed))   // answers a 428
```

Operations the document marks `x-calimero-retry-safe` (views, and calls
with an `idempotencyKey`) are retried on a 503 and fail over as `call` does.
A `412 CONFIRM_REQUIRED` is answered with the call's `passkey:`, else the
client's (`useStepUp`); a `428 OPERATOR_SIGNATURE_REQUIRED` with the call's
`operatorSigner:`, else the client's (`useOperatorSigner`). `client.api` is
swift-openapi-generator's own `Client` over the same transport.

The facade (`Sources/MeroKit/Api/Generated`) and `MeroAPI`
(`Sources/MeroAPI/Generated`) are generated from
[`openapi/openapi.json`](openapi/openapi.json), core's document at the commit
in [`openapi/source`](openapi/source), by
[`scripts/generate-openapi.sh`](scripts/generate-openapi.sh), and checked in:
`refresh [REF]` vendors a newer document, `check` (a CI job) fails on stale
output. MeroKit 1.0 removed the 0.x wrappers (`getOrg`, `invite`,
`createApp`, ...): [CHANGELOG.md](CHANGELOG.md) maps each to its facade
method. `call`/`view` (idempotent retries, failover, exact numbers), the
sign-in ceremonies, the event streams and the escape hatches (`post`,
`postConfirmed`, `answer(as:_:)`, ...) are hand-written.

## Behaviour

- **Transport.** Only `/health` and `/attestation` are plaintext. Everything
  else goes through `calimero/sealed-http/v2` (Noise NK to the attested
  transport key), byte for byte with core's `calimero-sealed`.
- **Trust.** `CloudPolicy.production` checks the release floor, the release's
  Sigstore signature, the quote's DCAP chain against Intel's collateral
  (from the cloud's PCCS mirror, or Intel's PCS) and the image's measurements. Mock quotes pass
  only with `allowMock` (`.development`).
- **Sessions.** Passkey session `v2.…` (15 min) and refresh token `rt_…`; a
  `401` triggers one shared refresh. `421 WRONG_NODE` moves to the next node,
  `421 NOT_LEADER` to the named leader. `CalimeroClient.connect(…cluster:)`
  reads a cluster's nodes from the node directory.
- **Step-ups.** Members, invites, passkeys, API keys (creating and revoking),
  package origins and organization recovery take a `passkey:` that answers the
  node's `412 CONFIRM_REQUIRED`. A sign-up prompts twice: the new passkey then
  signs the account it creates.
- **Sign-up policy.** `signUpPolicy()` says whether the cluster is `open`,
  `invite` or `closed` before any prompt; `signUp(_:name:invite:)` takes an
  organization or sign-up invite.
- **Retries.** A call or view that meets `503` or no answer is sent again with
  the same idempotency key (6 retries, 200 ms → 2 s), then the next node with
  the same key, then `UnavailableError`.
- **Errors.** `CalimeroError` and its subclasses: `AppError{appCode, fields}`,
  `ConfirmRequired`, `LoginRequired`, `WrongNode`, `NotLeader`, `NotFound`,
  `UnavailableError`, `ArgsTooLarge`, `IdempotencyMismatch`,
  `ReleaseDeadlineError`, `ConsentStale`, `TrapError`, `SignUpRefused{reason}`,
  `OriginNotRegistered`, `BadOrigin`, `OriginTaken`, `QuotaExceeded`,
  `RecoveryNotReady{readyAt}`; plus `ConfirmCancelled`.
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
one: namespace → organization, subgroup → team (`"{orgId}/{teamId}"`),
context → app instance, application → package, invitation → invite token
(`OrgInvitation`). See
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
scripts/generate-openapi.sh                     # regenerate MeroAPI + the facade from openapi/openapi.json
scripts/generate-openapi.sh refresh docs/openapi   # vendor core's document from a branch, tag or commit first
swiftlint lint --strict
swift-format lint --recursive --strict Sources Tests Examples
scripts/dev-cluster.sh up                       # merod local on :2501-2503 (Docker on a Mac)
MERO_E2E_NODE_URL=http://127.0.0.1:2501 swift test --filter MeroKitE2ETests   # against it
```
