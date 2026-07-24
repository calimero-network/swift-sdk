#!/usr/bin/env bash
#
# run-app-2.sh — launch the app on TWO simulators against TWO nodes, so you can
# test invitations / cross-user chat by hand.
#
# Clean slate each run: quits the Simulator, stops + deletes both local nodes,
# then boots two P2P-connected merods (A :4001, B :4011, admin dev/dev-password),
# builds the app, installs it on two simulators, and launches:
#   sim A → node A (:4001, the default)
#   sim B → node B (:4011, via the E2E_NODE launch env)
# Both nodes are left running. Sign in as dev / dev-password on each; on A create
# a space + channel and an invite (copy it), on B paste it to join.
#
# Usage: ./run-app-2.sh   (override devices with DEV_A=/DEV_B= env)

set -u
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
APP_DIR="Examples/MeroSampleApp"
BUNDLE_ID="network.calimero.merokit.sample"
DEV_A="${DEV_A:-iPhone 17}"
DEV_B="${DEV_B:-iPhone 17 Pro}"
BOLD=$'\033[1m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RED=$'\033[31m'; RESET=$'\033[0m'
step() { echo; echo "${BOLD}▶ $*${RESET}"; }
die() { echo "${RED}✘ $*${RESET}"; exit 1; }

command -v merod >/dev/null 2>&1 || die "merod not on PATH"
xcrun --find xctest >/dev/null 2>&1 || die "full Xcode not selected (see TESTING.md §0)"

step "Fresh start — stopping simulators & nodes"
osascript -e 'quit app "Simulator"' 2>/dev/null || true
xcrun simctl shutdown all 2>/dev/null || true
for f in .mero-a.pid .mero-b.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done
for p in 4001 4011; do pids=$(lsof -ti "tcp:$p" 2>/dev/null || true); [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true; done
rm -rf "$REPO_ROOT/.mero-a" "$REPO_ROOT/.mero-b" "$REPO_ROOT"/.mero-a.* "$REPO_ROOT"/.mero-b.*

step "Boot node A (:4001)"
printf 'dev-password' | merod --home "$REPO_ROOT/.mero-a" --node a init \
  --server-port 4001 --swarm-port 4002 --auth-mode embedded --auth-storage persistent \
  --admin-user dev --admin-password-stdin --mdns >/dev/null 2>&1 || die "node A init failed"
merod --home "$REPO_ROOT/.mero-a" --node a run > "$REPO_ROOT/.mero-a.log" 2>&1 &
echo $! > "$REPO_ROOT/.mero-a.pid"
until curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1; do sleep 1; done
echo "node A healthy"
sleep 3
BOOT=$(grep -oE '/ip4/127\.0\.0\.1/tcp/4002/p2p/[A-Za-z0-9]+' "$REPO_ROOT/.mero-a.log" | head -1)
echo "node A boot addr: ${BOOT:-<none, relying on mDNS>}"

step "Boot node B (:4011)"
BOOT_ARGS=()
[ -n "$BOOT" ] && BOOT_ARGS=(--boot-nodes "$BOOT")
printf 'dev-password' | merod --home "$REPO_ROOT/.mero-b" --node b init \
  --server-port 4011 --swarm-port 4012 --auth-mode embedded --auth-storage persistent \
  --admin-user dev --admin-password-stdin --mdns ${BOOT_ARGS[@]+"${BOOT_ARGS[@]}"} >/dev/null 2>&1 || die "node B init failed"
merod --home "$REPO_ROOT/.mero-b" --node b run > "$REPO_ROOT/.mero-b.log" 2>&1 &
echo $! > "$REPO_ROOT/.mero-b.pid"
until curl -sf http://localhost:4011/admin-api/health >/dev/null 2>&1; do sleep 1; done
echo "node B healthy"

step "Boot simulators: A=$DEV_A  B=$DEV_B"
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
udid() { xcrun simctl list devices available | grep -E "^\s*$1 \(" | grep -oE '[0-9A-F-]{36}' | head -1; }
UDID_A=$(udid "$DEV_A"); UDID_B=$(udid "$DEV_B")
if [ -z "$UDID_A" ] || [ -z "$UDID_B" ] || [ "$UDID_A" = "$UDID_B" ]; then
  names=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9][^(]*' | sed 's/ *$//' | awk '!seen[$0]++')
  DEV_A=$(echo "$names" | sed -n 1p); DEV_B=$(echo "$names" | sed -n 2p); [ -n "$DEV_B" ] || DEV_B="$DEV_A"
  UDID_A=$(udid "$DEV_A"); UDID_B=$(udid "$DEV_B")
  echo "auto-picked: A=$DEV_A  B=$DEV_B"
fi
[ -n "$UDID_A" ] || die "no simulator '$DEV_A'"; [ -n "$UDID_B" ] || die "no simulator '$DEV_B'"
for u in "$UDID_A" "$UDID_B"; do
  xcrun simctl boot "$u" 2>/dev/null || true
  xcrun simctl bootstatus "$u" 2>/dev/null || true
  xcrun simctl spawn "$u" defaults write com.apple.security.AutoFill Enabled -bool NO 2>/dev/null || true
done
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true

step "Build app"
( cd "$APP_DIR" && command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null 2>&1 || true )
set -o pipefail
if ! xcodebuild -project "$APP_DIR/MeroSampleApp.xcodeproj" -scheme MeroSampleApp \
  -destination "platform=iOS Simulator,id=$UDID_A" -configuration Debug build \
  > "$REPO_ROOT/.mero-build.log" 2>&1; then
  grep -E "error:" "$REPO_ROOT/.mero-build.log" | head; die "build failed"
fi
set +o pipefail
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/MeroSampleApp-"*/Build/Products/Debug-iphonesimulator \
        -maxdepth 1 -name MeroSampleApp.app 2>/dev/null | head -1)
[ -n "$APP" ] || die "built app not found"

step "Install + launch on both simulators"
for u in "$UDID_A" "$UDID_B"; do
  xcrun simctl uninstall "$u" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$u" "${BUNDLE_ID}.uitests.xctrunner" >/dev/null 2>&1 || true
  xcrun simctl install "$u" "$APP" || die "install failed"
done
# sim A → node A :4001 (chat name dev1); sim B → node B :4011 (chat name dev2)
SIMCTL_CHILD_E2E_USERNAME="dev1" \
  xcrun simctl launch "$UDID_A" "$BUNDLE_ID" >/dev/null 2>&1
SIMCTL_CHILD_E2E_NODE="http://localhost:4011" SIMCTL_CHILD_E2E_USERNAME="dev2" \
  xcrun simctl launch "$UDID_B" "$BUNDLE_ID" >/dev/null 2>&1
osascript -e 'tell application "Simulator" to activate' 2>/dev/null || true

echo
echo "${GREEN}${BOLD}✔ two apps launched.${RESET}"
echo "  sim A ($DEV_A) → node A :4001 (chat name dev1)    sim B ($DEV_B) → node B :4011 (chat name dev2)"
echo "  Sign in as ${BOLD}dev / dev-password${RESET} on both (chat display names are dev1/dev2)."
echo "  On A: Open Chat → create a space + channel → Invite people → Copy."
echo "  Move the invite A→B (both sims share the Mac clipboard if Simulator ▸ Edit ▸ Automatically Sync Pasteboard is on),"
echo "  then on B: Open Chat → + → Join with invite → paste → Join."
echo "  ${DIM}Nodes stay running. Stop them with: kill \$(cat .mero-a.pid) \$(cat .mero-b.pid)${RESET}"
