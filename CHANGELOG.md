# Changelog

Notable changes to MeroKit. Versions are git tags (see [RELEASING.md](RELEASING.md)).

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

- `createGroupInNamespace` always sends `visibility`, `"restricted"` when the
  caller names none (`CreateGroupInNamespaceRequest.defaultVisibility`). rc.83
  made an absent visibility mean `open`.
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
