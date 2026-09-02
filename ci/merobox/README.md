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

## History: two ways this went red without a commit of its own

Both failures were the harness, not the node, and both had the same shape — the
thing under test was resolved at run time rather than pinned, so a core release
changed what this job did with nothing changing here.

**1. A stale wasm → node 2 stuck on the uninitialized hash.** The first runs
failed with node 2 on the all-ones hash while node 1 had a real one:

```
context=…:
  calimero-node-1: BkifspwXGw7MfKumpuYkB8RNFmS3fqZ1s4nwR4zytdNV
  calimero-node-2: 11111111111111111111111111111111
```

That looks exactly like a cross-node sync bug. It was a `kv_store.wasm` whose
host ABI predated the node, so the joining node could never initialize the
context. Rebuilding it by hand fixed it — and then it went stale again, ten
release candidates behind, because nothing made it move. It is no longer
vendored: see *Node image and wasm* below.

**2. mDNS off by default → `join_namespace` HTTP 500.** core rc.26 (core#3620,
"leave mDNS off unless asked for") turned multicast off. These two containers
have nothing else to find each other with — `bootstrap.nodes` names the public
devnet boot-node, no sibling addresses are wired, and merod ships no rendezvous
server — so they stopped peering. It does not surface as a discovery problem:
the joiner holds a valid invitation, finds no mesh peer, falls back to gossip and
times out waiting for a group key only a peer could send, and the handler answers
`HTTP 500`. The real line is only in the node log (`KeyDelivery timed out …`).
The scenarios now ask for multicast explicitly with `mdns: true` on the `nodes:`
block, which is the honest thing for a test fleet sharing one Docker bridge.

With both fixed, the scenarios converge in **under 2 seconds** (forward and
backward), so this job is a **gating check** — a red run means a genuine
regression in the node's sync path.

## Run locally

Requires Docker running.

```sh
pip install 'merobox>=0.6.69'   # floor: parses the hex ids core rc.27 made universal
merobox bootstrap validate ci/merobox/sync-two-node.yml   # schema only, no Docker or wasm

# `run` needs the wasm the CI job downloads; fetch the same one first:
gh release download "$(. ci/core-version; echo "$CORE_TAG")" \
  --repo calimero-network/core --pattern 'kv-store-test-fixture.mpk' \
  --output kv-store.mpk --clobber
mkdir -p kv-store-fixture ci/merobox/res
tar xzf kv-store.mpk -C kv-store-fixture
cp kv-store-fixture/app.wasm ci/merobox/res/kv_store.wasm

merobox bootstrap run ci/merobox/sync-two-node.yml        # boots 2 nodes in Docker
```

## Node image and wasm

Both are **pinned to one core release**, named in [`ci/core-version`](../core-version):

- **Node image** — `ghcr.io/calimero-network/merod:<CORE_TAG>`. The CI job
  substitutes it into each scenario's `image:` line, so the checked-in value and
  the value CI uses cannot disagree. Override for a single run with the
  `merod_image` `workflow_dispatch` input.
- **`res/kv_store.wasm`** — extracted from that release's
  `kv-store-test-fixture.mpk` asset (a gzip tar of `manifest.json` + `app.wasm` +
  `abi.json`), downloaded per run and **gitignored**. A wasm whose host ABI
  predates the node leaves the joiner uninitialized forever, and a committed
  binary is one nothing forces you to refresh — so it is no longer committed,
  and it can no longer drift from the node it runs against.

Bumping to a new core is a one-line change to `ci/core-version`; the image and
the wasm both follow.
