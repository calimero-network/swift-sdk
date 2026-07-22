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

RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
die() { echo "${RED}✘ $*${RESET}"; exit 1; }

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
until curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1; do sleep 1; done
echo "node healthy (dev / dev-password)"

echo "${BOLD}▶ prep simulator: $DEVICE${RESET}"
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
UDID=$(xcrun simctl list devices available | grep -E "^\s*${DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$UDID" ] || die "no simulator named '$DEVICE'"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" 2>/dev/null || sleep 5
xcrun simctl spawn "$UDID" defaults write com.apple.security.AutoFill Enabled -bool NO 2>/dev/null || true

echo "${BOLD}▶ run AppE2ETests${RESET}"
( cd Examples/MeroSampleApp && command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null 2>&1 || true )
set -o pipefail
xcodebuild test \
  -project Examples/MeroSampleApp/MeroSampleApp.xcodeproj \
  -scheme MeroSampleApp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:MeroSampleAppUITests/AppE2ETests \
  -retry-tests-on-failure -test-iterations 2 2>&1 | tee "$REPO_ROOT/.e2e-ios.log" | grep -iE "Test Case .* (passed|failed)|\*\* TEST"
code=${PIPESTATUS[0]}
[ "$code" -eq 0 ] && echo "${GREEN}✔ e2e passed${RESET}" || die "e2e failed — see .e2e-ios.log"
