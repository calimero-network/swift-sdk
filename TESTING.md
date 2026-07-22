# TESTING — MeroKit (swift-sdk)

Exact, section-by-section steps to test everything in this repo. Run every command
from the repo root (`swift-sdk/`) unless a section says otherwise.

---

## 0. Prerequisites (do this first — one-time / after any toolchain change)

The tests need **full Xcode**, not just the Command Line Tools. `XCTest` ships
with Xcode, so `swift test` fails with `no such module 'XCTest'` under CLT.

```bash
# Is a full Xcode installed?
ls -d /Applications/Xcode*.app

# Point the active toolchain at it (needs your password):
sudo xcode-select -s /Applications/Xcode-26.5.0.app/Contents/Developer

# Verify:
xcode-select -p            # → /Applications/Xcode-26.5.0.app/Contents/Developer
xcrun --find xctest        # should resolve to a path
swift --version            # note the Swift version
```

> ⚠️ **Toolchain-switch gotcha.** Any time you change toolchains (`xcode-select`,
> a new Xcode, or back to CLT), Swift modules in `.build` become incompatible
> (`module compiled with Swift X cannot be imported by the Swift Y compiler`).
> **Always wipe the cache first:**
>
> ```bash
> rm -rf .build
> ```

---

## 1. Build

```bash
swift build            # debug
swift build -v         # verbose, if you need to see the compiler invocation
```

Expected: builds `MeroKit`, `MeroKitUI`, `MeroExample`, and the test support target
with no errors.

---

## 2. Unit + mocked-e2e tests (the everyday run — no node, no simulator)

```bash
swift test
```

Expected result:

```
Executed 37 tests, with 2 tests skipped and 0 failures
```

- **35 passes** — unit tests (`RefreshStateMachineTests`, `RpcClientTests`,
  `SsoLoginTests`, `TokenStoreTests`, `AdminApiRequestTests`), the mocked
  end-to-end journeys (`EndToEndMockTests` against `FakeNode`), and the SwiftUI
  view-model tests (`MeroClientTests`).
- **2 skips** — `RealNodeE2ETests` (`testFullAuthJourney`, `testNodeIsHealthy`)
  self-skip because `MERO_E2E_NODE_URL` is not set. This is correct; see §4.

> The trailing `✔ Test run with 0 tests in 0 suites passed` line is the newer
> **swift-testing** runner finding no `@Test` cases — this package is all XCTest,
> so that's expected, not a failure.

Run a single target or test while iterating:

```bash
swift test --filter MeroKitTests
swift test --filter RpcClientTests
swift test --filter MeroKitTests.RpcClientTests/testExecuteUnwrapsOutput
```

---

## 3. Lint (what CI enforces — must be clean)

```bash
brew install swiftlint swift-format     # one-time

swiftlint lint --strict
swift-format lint --recursive --strict Sources Tests Examples
```

Both must exit 0. `--strict` turns warnings into failures, matching `ci.yml`.

---

## 4. Live end-to-end tests (against a real merod node)

These are the 2 tests that skip in §2. They run only when `MERO_E2E_NODE_URL`
is set, so you need a node first.

### 4a. Boot a node

```bash
# Download a released merod (arm64 mac) — or use one you already have:
TAG=$(gh release list --repo calimero-network/core --limit 1 --json tagName -q '.[0].tagName')
URL=$(gh release view "$TAG" --repo calimero-network/core --json assets \
  -q '.assets[] | select(.name | test("merod_aarch64-apple-darwin\\.tar\\.gz$")) | .url')
curl -sL "$URL" | tar xz && chmod +x ./merod

# Init a single node with embedded auth + an admin account.
# rc.17+ creates the admin AT INIT — there's no longer a first-login bootstrap
# secret. The password is never a plain flag; pass it via stdin (shown below),
# a file (--admin-password-file <PATH>), or env (MERO_AUTH_ADMIN_PASSWORD).
# --auth-storage persistent is required so the init-time admin survives into `run`.
printf 'dev-password' | ./merod --home ./e2e-node --node e2e init \
  --server-port 4001 --swarm-port 4002 \
  --auth-mode embedded --auth-storage persistent \
  --admin-user dev --admin-password-stdin

# Run the node:
./merod --home ./e2e-node --node e2e run > merod.log 2>&1 &
echo $! > merod.pid

# Wait for health:
until curl -sf http://localhost:4001/admin-api/health >/dev/null; do sleep 1; done
echo "node healthy"
```

> **rc.17 cutover (core#3276/#3277).** The admin credentials are set at `init`
> (above), so the old `MERO_AUTH_BOOTSTRAP_SECRET` / setup-code first-login flow
> is gone. The `MERO_E2E_USER` / `MERO_E2E_PASS` below must match `--admin-user`
> and the password you piped in.
>
> Alternative: skip `--admin-user`/`--admin-password-*` at init and instead set
> `MERO_AUTH_ADMIN_USER` + `MERO_AUTH_ADMIN_PASSWORD` on the `run` process to
> provision the admin at startup. (`--no-admin` skips admin creation entirely.)

### 4b. Run the live e2e tests

```bash
MERO_E2E_NODE_URL=http://localhost:4001 \
MERO_E2E_USER=dev MERO_E2E_PASS=dev-password \
swift test --filter MeroKitE2ETests
```

Expected: `testNodeIsHealthy` and `testFullAuthJourney` now **execute** (not skip):
`Executed 2 tests, with 0 failures`.

### 4c. Stop the node

```bash
kill "$(cat merod.pid)" 2>/dev/null; rm -f merod.pid
```

---

## 5. Runnable example — `MeroExample` (CLI, runs on your Mac, no simulator)

```bash
# Offline demo — prints SSO URL, capabilities, sample JSON:
swift run MeroExample

# Full online flow (auth → identity → contexts → rpc → logout) against a node:
# rc.17+ has no bootstrap secret — the username/password are the admin creds you
# set at node init (§4a: --admin-user / --admin-password-stdin).
MERO_NODE_URL=http://localhost:4001 \
MERO_USERNAME=dev MERO_PASSWORD=dev-password \
swift run MeroExample
```

---

## 6. UI tests — `MeroSampleApp` (XCUITest, runs in the iOS Simulator)

Needs full Xcode (see §0) — `xcodebuild`/`simctl` are not in the CLT.

> ⚠️ **Local-only setup: two simulator settings, or the tests flake.** CI runners
> hit neither (fresh simulator, no hardware keyboard), so this is only for local
> runs. Do both once, up front:
>
> ```bash
> # 1) Disable the hardware keyboard so the on-screen keyboard appears — otherwise
> #    typing fails with "Neither element nor any descendant has keyboard focus".
> defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
>
> # 2) Disable AutoFill Passwords so iOS never shows the "Save Password?" system
> #    prompt after login — that SpringBoard alert overlays the app and blocks the
> #    next tap (RPC/logout), and it cannot be dismissed from inside the test
> #    without destabilizing XCUITest. Target the iPhone 17 simulator by UDID:
> UDID=$(xcrun simctl list devices | grep -E "iPhone 17 \(" | grep -oE '[0-9A-F-]{36}' | head -1)
> xcrun simctl boot "$UDID" 2>/dev/null
> xcrun simctl spawn "$UDID" defaults write com.apple.security.AutoFill Enabled -bool NO
> xcrun simctl spawn "$UDID" defaults write com.apple.WebUI AutoFillPasswords -bool NO
>
> xcrun simctl shutdown all      # both settings take effect on next boot
> ```
>
> Opening Simulator.app can flip the hardware keyboard back on (⇧⌘K); an
> `xcrun simctl erase` resets the AutoFill setting. Re-run the commands above if
> the UI tests start failing on keyboard focus or on a tap that "never appeared".
>
> The test code itself is already hardened against the genuine flakes (it retries
> the focusing tap until the field reports `hasKeyboardFocus`, and retries button
> taps until the expected screen transition happens) — these two simulator
> settings cover the parts the test can't control.

```bash
brew install xcodegen              # one-time

cd Examples/MeroSampleApp
xcodegen generate                  # regenerates MeroSampleApp.xcodeproj

# Pick a simulator that actually exists on this machine:
xcrun simctl list devices available | grep iPhone

xcodebuild test \
  -project MeroSampleApp.xcodeproj \
  -scheme MeroSampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # ← use a name from the list above
```

Expected: `Test Suite 'All tests' passed`. This drives the real SwiftUI app in the
simulator (type → tap → assert) against an in-app mock backend — no node required.

To run the app interactively instead of the test suite: open
`MeroSampleApp.xcodeproj` in Xcode, pick a simulator, hit **Run** (⌘R).

---

## Quick reference — full green pass

```bash
sudo xcode-select -s /Applications/Xcode-26.5.0.app/Contents/Developer   # §0 (if needed)
rm -rf .build                                                            # §0 (after toolchain change)
swift build                                                              # §1
swift test                                                               # §2  → 37 tests, 2 skipped
swiftlint lint --strict                                                  # §3
swift-format lint --recursive --strict Sources Tests Examples            # §3
# §4 live e2e and §6 simulator UI tests are optional / heavier — run as needed.
```

CI mirrors these: `ci.yml` (§1–§3), `ui.yml` (§6), `e2e.yml` (§4).
