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
