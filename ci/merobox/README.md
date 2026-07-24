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
- **`sync-two-node-bidi.yml`** — same setup, but asserts **both directions**:
  node 1 → node 2 *and* node 2 → node 1 (the joiner writes, the creator must
  see it). Catches a sync path that only works outward from the context creator.

The CI job also always dumps each node's logs and a best-effort **peer-connectivity
count**, so a failure can be diagnosed as *"nodes never peered"* (discovery /
networking) vs *"peered but state didn't sync"* (the sync path itself).

## History: the `1111…` failure was a wasm/node version mismatch

The first runs failed with node 2 stuck on the all-ones **uninitialized** hash
while node 1 had a real hash:

```
context=…:
  calimero-node-1: BkifspwXGw7MfKumpuYkB8RNFmS3fqZ1s4nwR4zytdNV
  calimero-node-2: 11111111111111111111111111111111
```

That looked like the iOS chat sync bug, but it was **our harness**: the vendored
`kv_store.wasm` was a stale build incompatible with the `edge` node, so the
joining node could never initialize the context. merobox's own Docker CI passes
all 30+ sync scenarios against `edge` — it just always *builds* the wasm from
core `master`. Fixed by doing the same (see the wasm note below).

With the matching wasm, both scenarios now converge on CI in **under 2 seconds**
(forward and backward), so the job is a **gating check** — a red run means a
genuine regression (upstream node sync broke, or the vendored wasm drifted from
the node image).

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

### `res/kv_store.wasm` must match the node

**This was the root cause of the first failures.** The wasm was originally
vendored from merobox's stale `example-project/res/kv_store.wasm` (321 KB), whose
bytecode/host-ABI predates the `edge` node. The joining node could not
initialize the context against it, so node 2 stayed on the `1111…` hash forever
— exactly the symptom above. merobox's own CI never hits this because it *builds*
`kv_store.wasm` from core `master` on every run.

So `res/kv_store.wasm` here is now **built from `calimero-network/core` master**
(`apps/kv-store`, `app-release` profile) to match the `edge` image. To rebuild
after a core bump:

```sh
git clone --depth 1 https://github.com/calimero-network/core.git
(cd core/apps/kv-store && ./build.sh)
cp core/apps/kv-store/res/kv_store.wasm ci/merobox/res/kv_store.wasm
```

(Equivalently, merobox's `workflow-examples/scripts/build_res_wasm.sh`.)
