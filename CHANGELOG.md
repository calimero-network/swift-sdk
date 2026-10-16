# Changelog

Notable changes to MeroKit. Versions are git tags (see [RELEASING.md](RELEASING.md)).

## Unreleased: mero-js parity

### Breaking

- **SSO callbacks must answer a login this app began.** `buildAuthLoginUrl`
  now records a random, single-use `auth_state` (alive 10 minutes) in an
  `AuthLoginStateStore` and adds it to the callback URL's query;
  `parseAuthCallback` returns `nil` for a callback without a pending state, and
  consumes the state so a replay is refused (port of mero-js 25.3.2). Before,
  any URL with `#access_token=…` was adopted — anyone who could open the app
  could choose its session. Build the login URL with `buildAuthLoginUrl` before
  parsing; for a callback that can arrive after a relaunch, pass the same
  `AuthLoginStateStore.keychain()` (or any `AnyValueStore<PendingAuthLogins>`)
  to both calls. A host that injects tokens itself can pass
  `ParseAuthCallbackOptions(allowUnsolicited: true)`.
- **The login URL is form-encoded as mero-js encodes it**: `callback-url`,
  `permissions` and `registry-url` are percent-encoded (`myapp%3A%2F%2Fcb`),
  byte-identical with `URLSearchParams`.
- **Stored tokens are bound to their node.** `Mero` persists the bundle with
  `TokenData.nodeOrigin` (origin + path prefix, `TokenData.nodeKey(for:)`) and
  ignores a stored bundle for another node — or one with no `node_origin`,
  i.e. every bundle saved by an earlier release. **Sign in once after
  upgrading.** `nodeOrigin` is optional, so old bundles still decode.
- **The transport no longer retries.** Every request — a `POST`/`PUT`/`PATCH`/
  `DELETE` included — used to be sent up to three times on a network error or
  `5xx`/`429`, which could repeat a write that had already run. It is now sent
  once, as in mero-js; `401 token_expired` still drives one refresh and one
  replay. Wrap idempotent calls in the now-public `withRetry` to retry.
- `Mero.close()` now ends the event streams the instance started (it was a
  no-op), and so does `logout()`, which calls it.

### Added

- `withRetry(attempts:sleep:_:)` and `isRetryable(_:)` are public: opt-in
  backoff retry (base 250 ms, ±20% jitter) that honours `Retry-After`.
- `classifyError(_:) -> ClassifiedError` (`kind: ErrorKind`, `status`,
  `retryable`, `message`) over `MeroError`, `HTTPError`, `AccountError` and
  `URLError`, plus `HTTPError.explanation` (port of mero-js `classifyError`).
- `CapabilityPresets` (`none`, `joinOnly`, `contributor`, `collaborator` = 0,
  4, 7, 231; `byName`), `Capabilities.capMask(_:)` (names and/or bits via
  `CapabilityRef`; throws on an unknown name), `Capabilities.capNames(_:)`,
  `Capabilities.all`, `Capabilities.bit(named:)`.
- `NodeDiscovery`: `defaultLocalNodePorts`, `localNodeURL(port:)`,
  `nodeEndpoint(_:path:)`, `probeNodeHealth(_:timeout:session:)` and
  `discoverLocalNodes(ports:timeout:session:)` (parallel, per-probe timeout,
  cancellable) — port of mero-js `nodeDiscovery.ts`.
- Typed event streams, like the Kotlin SDK: `Mero.groupEvents(groupIds:)` →
  `GroupEvent`, `Mero.nodeEvents(contextIds:groupIds:)` → `NodeEvent`
  (`.context` / `.group`); the same on `SseClient`.
- `AdminApi.listNamespaceRevokedDevices(_:)` → `NamespaceRevokedDevices`
  (`GET /admin-api/namespaces/:id/revoked-devices`) and `AuthApi.getLoginPage()`
  (`GET /auth/login`), both served by core.
- **`SseConnection`**, one long-lived SSE connection (port of mero-js
  `SseClient`; `Mero.sse` is the instance's shared one):
  `subscribe(contextIds:groupIds:)` / `unsubscribe(...)` on the live session
  (`POST /sse/subscription`, 10 s timeout, only the ids that changed),
  `isSubscribed`, re-subscription of every remembered id after a reconnect
  before `.connect(sessionId:)` is announced, `updates()` / `events()` /
  `on(_:)`, and `presenceSeed(_:)`. `SseClient`'s per-call streams now run on
  it, and `SseClient.connection()` hands one out. A `401` naming
  `token_revoked` / `token_reuse` is now terminal too, like a `403`; other
  refused connects surface as `MeroError.http` (they were `.network`).
- **`ReconnectBackoff`** replaces the fixed 3 s SSE reconnect: 3 s first (as
  mero-js's `reconnectDelayMs`), doubling to 30 s while reconnects keep
  failing, ±20% jitter, reset once a stream opens. `.fixed(3)` is mero-js's
  flat delay; `SseClient`/`SseConnection` take `backoff:`.
- **Typed events**: `AppVersionChangedEvent`, `GroupMembershipEvent`
  (`MembershipChangeKind`), `GroupMigrationEvent` with `MigrationStartedData`,
  `MigrationProgressData`, `CascadeProgressData`, `MigrationCompletedData`
  (core's field names); `ContextEvent.appVersionChanged`, `.data`,
  `GroupEvent.membership`, `.migration`, `.data`; streams
  `appVersionChanges`, `migrationEvents`, `membershipEvents` and handlers
  `onAppVersionChanged` / `onMigrationEvent` on `SseConnection`, plus
  `Mero`/`SseClient` `appVersionChanges(contextIds:)` and
  `migrationEvents(groupIds:)`.
- **`WsClient`** (experimental, as in mero-js; `Mero.ws`): `GET /ws?token=`,
  `subscribe`/`unsubscribe` messages, re-subscribe after reconnect, backoff
  1 s · 2ⁿ ≤ 30 s, over a `WebSocketTransport`/`WebSocketConnector`
  abstraction (`URLSessionWebSocketConnector` by default).
- **Ephemeral presence**: `Mero.ephemeral` → `EphemeralClient`
  (`set(contextId:state:codec:)` via JSON-RPC `set_ephemeral`,
  `subscribe(contextId:codec:)`), `Codec` / `JSONCodec`, `EphemeralEntry`
  (`author`, `account`, `state`, `removed`, `ageMs`), `presenceStream(_:...)`
  seeded from the connection's kept presence. `RpcClient.call(_:params:)` for
  any JSON-RPC method.
- **Relay presence**: `PresenceStatement` (`calimero/presence/1` statement
  bytes and `stateHash`, pinned to core's vector; `signedIntent`),
  `RelayClient.presenceIntent(contextId:state:seq:sentAtMs:)` (signs with the
  device key), `AdminApi.postPresenceIntent(_:state:seq:sentAtMs:keys:authorProof:)`,
  and `RelayPresenceClient` (resends every 2.5 s, `set(nil)` retracts,
  `close()`), on every relay `CloudConnection` as `presence`.
- `MockURLProtocol.Stub(holdOpen:)` keeps a response open after its body — a
  live `/sse` in tests.
- `MeroKitTestSupport` is a library product, so apps can use `FakeNode` and
  `MockURLProtocol` in their own tests. It is not part of `MeroKit`, and the
  podspec does not ship it.
- **Signers** (port of mero-js `signer.ts`): the `Signer` protocol (public key
  + `sign(_:)`), `SeedSigner`, `signerFromSecret(_:label:)`,
  `resolveSigner(_:_:label:)`. Every new signing entry point takes a hex secret
  or a `Signer`, never both.
- **Account roots** (port of mero-js `account/account.ts` + `wordlist.ts`):
  `bip39EnglishWordlist` (pinned to its canonical SHA-256),
  `generateAccountRoot()`, `accountRootFromPhrase(_:)`,
  `accountRootFromSecret(_:)` — the 24 words are BIP39 *entropy* used as the
  Ed25519 seed, no PBKDF2 or BIP32, exactly as mero-js;
  `createAccountRootSigner(vault:)`, `accountRootSignerFromPhrase(_:vault:)`,
  `loadAccountRootSigner(from:)` over a `RootSeedVault`
  (`KeychainRootSeedVault`: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  never synchronized; `MemoryRootSeedVault`) whose `VaultRootSigner` reads the
  seed per signature and never returns it; `RootSource`, `resolveRoot(_:)`,
  `resolveRootPair(rootSecret:signer:)`; `signAccountLink(_:)` /
  `signAccountLogin(_:)` (mdma's domains, standard base64). Types
  `AccountRoot`, `RecoverableAccountRoot`, `AccountRootSigner`,
  `NewAccountRootSigner`, `ResolvedRoot`, `AccountLinkInput`, `AccountLoginInput`.
- **Owner-op root proofs** (port of mero-js `owner-op.ts`, pinned to core's
  `owner_op.rs` and `root_guarded_vectors_are_stable` vectors): `OwnerOpKind`
  (raw value = the signed byte), `OwnerOpPlane`, `OwnerOp`,
  `transferOwnershipOp`, `groupDeleteOp`, `adminChangedOp`,
  `teeAuthoringPolicyOp`, `teeAdmissionPolicyOp`, `teeReleaseAdmissionPolicyOp`,
  `ownerOpDigest`, `ownerOpSigningPayload`, `signOwnerOpProof(_:)`
  (`OwnerOpProofInput`, handoff `chain` and `keyEpoch`), `rootGuardedOpBytes`.
- **The SDK mints `rootProof` itself**: `AdminApi.transferOwnership(_:newOwner:root:)`,
  `changeNamespaceAdmin(_:newAdmin:root:)`, `ownerDeleteGroup(_:root:)`,
  `setTeeAuthoringPolicy(_:allowedMrtd:root:)`, `disableTeeAuthoringPolicy(_:root:)`
  and `setTeeAdmissionPolicy(_:request:root:)` read `namespaceId` and
  `ownerOpCounter`, build the op the node builds and send its proof
  (`ownerOpTarget(_:plane:)`, `signRootProof(_:op:root:)`,
  `SetTeeAdmissionPolicyRequest.ownerOp()`, `normalizeTeeReleaseVersion`). The
  raw-`rootProof` forms are unchanged.
- **Device scopes** (port of mero-js `device-scope.ts`, core vectors):
  `signDeviceScope(_:)`, `deviceScopePayload`, `DeviceScopeInput`, and
  `AdminApi.linkAccountDevice(_:credential:scope:)`, which signs the scope.
  `rescopeDevice` is unchanged: core signs that scope on the root's own node.
- **Request proofs** (port of mero-js `request/*`, `request-proof/*`, pinned to
  core's `request_wire_fixture.rs` / `proof_auth.rs`): `requestBodyHash`,
  `signRequest` (`RequestSigInput`), `callerProof` (`CallerProofInput`),
  `createProofSigner` (`ProofSignerOptions`, 120 s), `signRequestProof`
  (`RequestProofInput`, 300 s), `requestProofHeader` (`X-Calimero-Proof`),
  `createProofAuthorizer(_:)` (`ProofCredential`), `signedPath(_:)`,
  `carriesProof(_:)`, `ProofRequest`, `ProofCallback`, `RequestAuthorizer`.
  `MeroConfig.requestProof` (`RequestProofConfig`: `.keys`, `.custom`,
  `.authorizer`) and `TransportHooks.getProof` / `.authorizeRequest` sign every
  `auth`/`admin`/`rpc` request over the URL fetched and its exact body. **A
  request carrying a proof never follows a redirect**: the `3xx` surfaces as
  `MeroError.http` with status `0` and is not re-sent (as mero-js
  `refuseProofRedirect`). A file body cannot be signed and is refused.
  `SseConnection(baseURL:authorize:)` and `SseClient(baseURL:authorize:)` sign
  the stream and every subscription `POST`, with the same redirect refusal.

### Changed

- `URLSessionHttpClient` drops a bare trailing `?` from a request URL (as
  mero-js `withoutBareQuery`), so the URL signed and the URL fetched agree.

## Unreleased: Calimero Cloud sign-in

### Breaking

- **Mobile sign-in is Calimero Cloud only.** `LoginView` is now a single
  "Continue with Calimero" button: the wallet opens in the system auth sheet,
  the person approves the device with their passkey, and the app connects to
  the relay that serves their account. The node URL, username and password
  fields are gone.
  - `LoginView(callbackScheme:)` / `LoginView(callback:)` replace
    `LoginView(defaultNodeURL:)`; likewise `MeroRootView`.
  - Accessibility ids: `cloudSignInButton` is the button; `loginButton` now
    identifies the sign-in panel; `loginTitle` and `loginError` are unchanged.
  - `MeroClient.login(nodeURL:username:password:)` remains for development
    nodes, but no shipped view offers it.

### Added

- **Account layer** (`MeroKit`, ported from mero-js 24.5.0, byte-identical with
  core's wire fixtures):
  - `Crypto/`: `domainHash`, a little-endian borsh writer, Ed25519 / X25519 over
    CryptoKit (no new dependencies), canonical JSON for warrant commitments.
  - `Account/`: `DeviceKeys` (Keychain via `AnyValueStore.keychain`),
    `DeviceCertificates` (`parse`/`verify`, port of `verifyDeviceCredential`),
    `DeviceEnrolment` (wallet URL, callback parsing, `completeEnrolment`),
    `NamespaceOps.signMemberJoinOp` (namespace-op schema 24) and `AccountJoin`
    (`bootstrapFromInvitation`).
  - `Cloud/`: `CloudClient` (`getAccountRelays` with routing-proof headers,
    `chooseRelay`, `getNamespaceRouting`, `findAdmitter`) and `CloudSignIn`,
    the end-to-end orchestrator.
  - `Relay/`: `RelayClient` (`describe`/`execute` with warrant v2 and a
    persisted per-relay nonce sequence recovered from `warrant-nonce` on a nonce
    refusal; `query` with 409 → warrant fallback;
    `describeCreation`/`createContext`; `describeGovernance`/`govern`),
    `RelayLogin` (`account_proof` login with a signed login statement, and
    `POST /auth/logout`), `RelayNodeKey` + the pluggable `RelayKeyVerifier`.
- `MeroKitUI`: `SystemWebAuthenticator` (ASWebAuthenticationSession; app scheme
  or iOS 17.4+ https callback), `MeroClient.signInWithCloud(callbackScheme:)`,
  `handleEnrolmentCallback(_:)`, `restoreCloudSession()`, and session state
  (`account`, `relayURL`, `isSignedInWithoutRelay`, `cloudNote`, `connection`).
- Sample app: Calimero light design (system font, SF Symbols, ids behind
  "Show technical details"), Cloud-only sign-in on `mero-sample://enrol`, chat
  over the relay session, and a "Cloud & Relay" explorer category.

### Known gaps

- The relay's node key is taken from its TEE attestation over TLS (report data
  bound to the request nonce and the named key); **DCAP quote signature and
  measurement verification is a follow-up**. Writes do not depend on it.
- The hosted wallet returns only to `https://` callbacks; accepting app schemes
  is a pending wallet change.

## Unreleased: core 0.11.0-rc.83

The SDK now targets core `0.11.0-rc.83` (`ci/core-version`, and the merod image
the merobox workflows pin). This is a breaking release.

### Upgrade notes

- **Log in again after upgrading the node.** rc.83 tokens carry a required
  `key_id` claim, so every access and refresh token an rc.41 node minted is
  refused (`401`). Clear the stored session and call `authenticate` again.
- `await mero.logout()` is now `async` and first calls `POST /auth/logout` to
  retire the refresh token on the node. That call is best-effort; the local clear
  always happens.

### Removed

- `AdminApi.getCertificate()`: core removed `GET /admin-api/certificate`.
- `AdminApi.teeVerifyQuote(_:)`, `TeeVerifyQuoteRequest`,
  `TeeVerifyQuoteResponseData`: the node has not served
  `POST /tee/verify-quote` since before rc.41.
- `CreateGroupRequest.groupId`: group ids are derived, and a body naming one is a
  `400`.

### Changed

- `RpcClient.execute` / `executeWithMetadata` no longer take `executorPublicKey`.
  Core's execute request is `deny_unknown_fields` with only `contextId`,
  `method` and `argsJson`, so a call that named one was refused.
- SSE: a `403` on connect or subscribe now finishes the stream with the
  `MeroError` (`.authRevoked` when `x-auth-error` names a dead token family)
  instead of reconnecting every 3 s forever.

- `createGroupInNamespace` always sends `visibility`, `"open"` when the caller
  names none (`CreateGroupInNamespaceRequest.defaultVisibility`), matching
  rc.83's new default and mero-js. Pass `"restricted"` to keep a subgroup closed.
- `SetTeeAdmissionPolicyRequest` gained the signed-release form (`signedRelease`),
  `mode` (`replica` / `relay`) and `rootProof`, with `.measurement(...)` and
  `.signedRelease(...)` factories. In the measurement form rc.83 requires
  RTMR1–3 as well as MRTD. `GetTeeAdmissionPolicyResponseData` gained `enabled`,
  `signedRelease` and `mode`.
- `TeeAttestRequest` gained `bindNodeKey`, `bindTransportKey` and
  `includeCollateral` (sent only when set); `TeeAttestResponseData` gained
  `boundPublicKey`, `transportPublicKey` and `collateral`.
- SSE sends the bearer token in the `Authorization` header instead of `?token=`.

### Added

- Admin: `queryContext`, `getIntentRelay` (`IntentRelayInfo` with `executorKey`,
  `releaseBytecodeId`, `releaseVersion`), `postPresenceIntent`,
  `getContextIntentRelay` / `createContextIntent`, `getGovernanceIntentRelay` /
  `governanceIntent`, `getWarrantNonce` / `getWarrantNonceAsAuthor` (not served
  by rc.83, which answers `404`), `signWithAccountRoot`, `linkAccountDevice`,
  `sealToAccount`, `listGroupMemberDevices`, `teeRegistrationAttest`.
- Root-guarded owner ops: `transferOwnership`, `changeNamespaceAdmin`,
  `ownerDeleteGroup`, `setTeeAuthoringPolicy`, `disableTeeAuthoringPolicy`, each
  with an optional `rootProof`.
- `Capabilities.canAuthorOnBehalf` (bit 9), with `openToDelegatedExecution` and
  `grantAuthorship`.
- Typed `createGroup(_: CreateGroupRequest)`, and typed
  `issueOwnershipProof` / `issueNamespaceOwnershipProof` returning
  `IssueOwnershipProofResponseData` (with `founding` and `credential`).
- `Namespace.founding` / `heldOps`, `CreateNamespaceResponseData.founding`,
  `GroupInfo.namespaceId` / `ownerOpCounter`.
- Auth: `AuthApi.logout(_:)`; `GenerateClientKeyRequest.applicationId` and
  `ttlSecs`.
- Errors: `HTTPError.refusal`, `MeroError.httpStatus` / `refusal` / `errorType`
  for rc.83's typed refusals (`{error, type, data}`), and
  `RpcError.isReadOnlyWriteRefused` / `refusedContextId`. `MeroError`'s cases
  are unchanged.
- RPC: `executeWithMetadata` (`RpcExecuteResult`).
- SSE: `events(contextIds:groupIds:)` for group-keyed events
  (`ContextEvent.groupId`), and `ContextEvent.presenceAccount` /
  `presenceAuthor`.
- Tests: `Rc83SurfaceTests` against core's own rc.83 wire fixtures
  (`Tests/MeroKitTests/Fixtures/rc83-*.json`).
