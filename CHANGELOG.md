# Changelog

Notable changes to MeroKit. Versions are git tags (see [RELEASING.md](RELEASING.md)).

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
