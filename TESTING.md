# Testing

| What | How |
| --- | --- |
| Unit and journey tests (no node) | `swift test` |
| Lint, as CI runs it | `swiftlint lint --strict` and `swift-format lint --recursive --strict Sources Tests Examples` |
| Against a development cluster | `MERO_E2E_NODE_URL=http://127.0.0.1:2501 [MERO_E2E_BUNDLE=kv_store.wasm] swift test --filter MeroKitE2ETests` |
| The sample's UI tests | CI (`ui.yml`) runs them in the simulator against the in-app cluster (`-uitest-mock`) |

The journey tests run `CalimeroClient`, `CloudAppBackend` and `MeroAppSession`
against `FakeCloudNode` (MeroKitTestSupport): mock attestation, a real Noise NK
responder and sealed frames, so the whole client runs as it does against a
node. `SealedTransportTests` checks the wire against core's published vectors;
the TEE suites check DCAP, Sigstore and signed releases against captured
fixtures.

`merod` 1.0 runs on Linux only; on macOS run `merod local` in Docker.
