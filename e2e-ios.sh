#!/usr/bin/env bash
#
# e2e-ios.sh — run the full-feature iOS end-to-end suite (AppE2ETests) against a
# LIVE node + registry, on one simulator. The "Playwright for iOS" run: login →
# explorer method call → chat install → space → channel → send/read a message.
#
# It boots a fresh merod on :4001 (admin dev/dev-password), preps the simulator
# (hardware keyboard + AutoFill off), builds, and runs AppE2ETests. The node is
# left running. For the multi-user (2-node/2-sim) chat e2e, use chat-multi-e2e.sh.
#
# Usage: ./e2e-ios.sh [--device 'iPhone 17']

set -u
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
DEVICE="iPhone 17"
[ "${1:-}" = "--device" ] && DEVICE="${2:?}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
die() { echo "${RED}✘ $*${RESET}"; exit 1; }

# Hard deadline in seconds; returns 124 on timeout, like GNU `timeout` (which
# macOS does not ship). `xcrun simctl bootstatus` can block forever on a
# simulator that never boots, and `|| true` / `|| sleep 5` does not save you —
# they catch a non-zero exit, not a hang. See chat-multi-e2e.sh for the run that
# burned 75 minutes on exactly this.
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$secs" ] && { kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; }
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

xcrun --find xctest >/dev/null 2>&1 || die "full Xcode not selected (see TESTING.md §0)"

echo "${BOLD}▶ fresh node on :4001${RESET}"
command -v merod >/dev/null 2>&1 || die "merod not on PATH"
NODE_HOME="$REPO_ROOT/.mero-e2e-node"
# Fresh node each run → deterministic state (no leftover spaces/channels).
pids=$(lsof -ti tcp:4001 2>/dev/null || true); [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
rm -rf "$NODE_HOME"
printf 'dev-password' | merod --home "$NODE_HOME" --node app init \
  --server-port 4001 --swarm-port 4002 --auth-mode embedded --auth-storage persistent \
  --admin-user dev --admin-password-stdin >/dev/null 2>&1 || die "node init failed"
merod --home "$NODE_HOME" --node app run > "$REPO_ROOT/.mero-e2e-node.log" 2>&1 &
echo $! > "$REPO_ROOT/.mero-e2e-node.pid"
# Bounded: an unbounded `until` spins forever if the node never comes up, which
# is the same shape of bug as the simulator hang above.
for _ in $(seq 1 60); do
  curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1 \
  || die "the node never became healthy within 60s — see .mero-e2e-node.log"
echo "node healthy (dev / dev-password)"

echo "${BOLD}▶ prep simulator: $DEVICE${RESET}"
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
UDID=$(xcrun simctl list devices available | grep -E "^\s*${DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then  # fall back to any available iPhone (CI images differ)
  DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9][^(]*' | head -1 | xargs)
  UDID=$(xcrun simctl list devices available | grep -E "${DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
fi
[ -n "$UDID" ] || die "no iPhone simulator available"
echo "device: $DEVICE"
with_timeout 120 xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
if ! with_timeout 180 xcrun simctl bootstatus "$UDID" >/dev/null 2>&1; then
  rc=$?
  [ "$rc" = "124" ] && die "simulator $UDID did not finish booting within 180s — the runner's simulator runtime is wedged, not the app."
  sleep 5
fi
with_timeout 60 xcrun simctl spawn "$UDID" defaults write com.apple.security.AutoFill Enabled -bool NO >/dev/null 2>&1 || true

echo "${BOLD}▶ run AppE2ETests${RESET}"
( cd Examples/MeroSampleApp && command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null 2>&1 || true )
set -o pipefail
xcodebuild test \
  -project Examples/MeroSampleApp/MeroSampleApp.xcodeproj \
  -scheme MeroSampleApp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:MeroSampleAppUITests/AppE2ETests \
  -retry-tests-on-failure -test-iterations 2 2>&1 | tee "$REPO_ROOT/.e2e-ios.log" \
  | grep -iE "Test Case .* (passed|failed|skipped)|\*\* TEST|error:|Assertion Failure|XCTAssert.* failed"
code=${PIPESTATUS[0]}

# A skip is a pass to xcodebuild, so print what was skipped and why. Otherwise a
# green run hides that half the suite never ran — the chat cases skip themselves
# while `com.calimero.curb` is unpublished, and that must not read as coverage.
if grep -q "Test skipped" "$REPO_ROOT/.e2e-ios.log" 2>/dev/null; then
  echo "${YELLOW}── skipped ──${RESET}"
  grep -o "Test skipped - .*" "$REPO_ROOT/.e2e-ios.log" | sort -u
fi
if [ "$code" -ne 0 ]; then
  # Surface the failing assertions directly in the console (the log tee'd above
  # is a hidden file; this makes CI failures diagnosable without the artifact).
  echo "${RED}── failing assertions ──${RESET}"
  grep -iE "\.swift:[0-9]+: error|Assertion Failure|XCTAssert.* failed" "$REPO_ROOT/.e2e-ios.log" | tail -30 || true
fi
[ "$code" -eq 0 ] && echo "${GREEN}✔ e2e passed${RESET}" || die "e2e failed — see .e2e-ios.log"
