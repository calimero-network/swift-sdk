# Merobox sync checks

Backend/protocol-level tests that boot real `merod` nodes in Docker (via
[merobox](https://github.com/calimero-network/merobox)) and assert that state
**syncs across nodes**. They isolate the node + WASM + sync layer from the iOS
sample app and the simulator, so a sync regression shows up here as a clean,
fast signal.

## What runs

- **`sync-two-node.yml`** — installs the canonical `kv_store` app, meshes one
  context across two nodes, writes a key on node 1, waits for the context state
  hash to **converge across both nodes**, then reads the key back on node 2 and
  asserts it matches. The `wait_for_sync` step is the important part: if node 2
  never initializes its context (the all-ones "uninitialized" hash) or never
  catches up, it times out and the check fails instead of passing silently.

## Status: informational

On the current `edge` node image this check **fails on purpose-revealing grounds**:
node 2 joins the group and pre-installs the app, but its context state stays on
the all-ones **uninitialized** hash (`11111111...`) and never converges with
node 1 — the same cross-node sync issue seen in the iOS chat e2e, under
investigation core-side. The CI job is therefore `continue-on-error` (see
`.github/workflows/merobox-sync.yml`). The assertions are real: once sync
converges, the job goes green on its own and can be promoted to a required gate.

Observed failure (node 1 has a real hash, node 2 does not):

```
context=…:
  calimero-node-1: BkifspwXGw7MfKumpuYkB8RNFmS3fqZ1s4nwR4zytdNV
  calimero-node-2: 11111111111111111111111111111111
```

## Run locally

Requires Docker running.

```sh
pip install merobox
merobox bootstrap validate ci/merobox/sync-two-node.yml   # schema only, no Docker
merobox bootstrap run      ci/merobox/sync-two-node.yml   # boots 2 nodes in Docker
```

## Node image

`merod` has **no published `0.11.x` Docker tag** — the iOS e2e uses the
`0.11.0-rc.x` darwin *binary* from GitHub releases, which has no Docker build.
So these workflows track `ghcr.io/calimero-network/merod:edge`. Override in CI
via the `merod_image` `workflow_dispatch` input (see `.github/workflows/merobox-sync.yml`).

`res/kv_store.wasm` is vendored from merobox's `example-project/res/kv_store.wasm`
so the check has no run-time download dependency.
