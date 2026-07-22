#!/usr/bin/env bash
#
# run-app.sh — build & launch the MeroSampleApp in the iOS Simulator so you can
# click through it (login → home → run RPC → logout). This is the interactive
# app, NOT the test suite (see test-all.sh for tests).
#
# Every run is a CLEAN SLATE: it quits the Simulator, shuts down all devices,
# stops and DELETES the local node, then rebuilds the app and boots a brand-new
# node (fresh admin creds + empty state) on http://localhost:4001. Sign in with
# the admin creds (default dev / dev-password). The node is left running after
# the script exits so the app keeps working.
#
# Use --mock for the tiny in-app-mock flow the XCUITest drives (no node needed).
#
# Usage:
#   ./run-app.sh                      # fresh node + explorer on localhost:4001
#   ./run-app.sh --admin-user me --admin-pass s3cret
#   ./run-app.sh --mock               # in-app mock flow (no node) — log in with anything
#   ./run-app.sh --no-node            # don't manage a node (use one you booted yourself)
#   ./run-app.sh --device 'iPhone 16 Pro'
#   ./run-app.sh --logs               # stream the app's stdout after launch
#
# Prereqs: full Xcode selected (see TESTING.md §0). xcodegen optional (a
# committed .xcodeproj is used if xcodegen isn't installed).

set -u
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
APP_PROJECT_DIR="Examples/MeroSampleApp"

# ---- options ---------------------------------------------------------------
DEVICE="iPhone 17"
MOCK=0            # 0 = real node (default), 1 = in-app mock backend
STREAM_LOGS=0
MANAGE_NODE=1     # boot/init a local merod node automatically
NODE_PORT=4001
ADMIN_USER="dev"
ADMIN_PASS="dev-password"
while [ $# -gt 0 ]; do
  case "$1" in
    --live)       MOCK=0 ;;
    --mock)       MOCK=1 ;;
    --no-node)    MANAGE_NODE=0 ;;
    --admin-user) ADMIN_USER="${2:?--admin-user needs a value}"; shift ;;
    --admin-pass) ADMIN_PASS="${2:?--admin-pass needs a value}"; shift ;;
    --port)       NODE_PORT="${2:?--port needs a value}"; shift ;;
    --device)     DEVICE="${2:?--device needs a name}"; shift ;;
    --logs)       STREAM_LOGS=1 ;;
    -h|--help)    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
  BLUE=$'\033[34m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else BOLD=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; DIM=""; RESET=""; fi
step() { echo; echo "${BOLD}${BLUE}▶ $*${RESET}"; }
die()  { echo "${RED}✘ $*${RESET}"; exit 1; }

# bundle id from project.yml (falls back to the known value)
BUNDLE_ID=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER:' "$APP_PROJECT_DIR/project.yml" 2>/dev/null | awk '{print $2}')
BUNDLE_ID="${BUNDLE_ID:-network.calimero.merokit.sample}"

# ---- prereq check ----------------------------------------------------------
xcrun --find xctest >/dev/null 2>&1 || die "full Xcode not selected — see TESTING.md §0 (sudo xcode-select ...)"

# ---- fresh start: stop simulators + node, wipe node data -------------------
# Every run starts clean: quit the Simulator, shut down all devices, stop any
# managed node + free the node port, and delete the node's data so a brand-new
# node (fresh admin creds, empty state) is created below.
step "Fresh start — stopping simulators and node"
osascript -e 'quit app "Simulator"' 2>/dev/null || true
xcrun simctl shutdown all 2>/dev/null || true
if [ "$MOCK" -eq 0 ] && [ "$MANAGE_NODE" -eq 1 ]; then
  [ -f "$REPO_ROOT/.mero-node.pid" ] && kill "$(cat "$REPO_ROOT/.mero-node.pid")" 2>/dev/null || true
  node_pids=$(lsof -ti "tcp:${NODE_PORT}" 2>/dev/null || true)
  [ -n "$node_pids" ] && kill -9 $node_pids 2>/dev/null || true
  pkill -f "merod --home .*e2e-node" 2>/dev/null || true   # legacy test-all node on the port
  rm -rf "$REPO_ROOT/.mero-node" "$REPO_ROOT/.mero-node.pid" "$REPO_ROOT/.mero-node.log"
  echo "simulators stopped · :${NODE_PORT} freed · node data wiped → a fresh node will be created"
fi

# ---- ensure a local node (init if needed, run, leave it running) -----------
# Reuses a node already answering on :$NODE_PORT; otherwise inits one with the
# given admin creds (rc.17 init-time creds) and runs it in the background. The
# node is left running after this script exits so the app keeps working — stop
# it with:  kill "$(cat .mero-node.pid)"
NODE_HOME="$REPO_ROOT/.mero-node"
ensure_node() {
  if curl -sf "http://localhost:${NODE_PORT}/admin-api/health" >/dev/null 2>&1; then
    echo "${GREEN}node already running${RESET} on :${NODE_PORT} — sign in as ${ADMIN_USER} / ${ADMIN_PASS}"
    return 0
  fi
  command -v merod >/dev/null 2>&1 || {
    echo "${YELLOW}merod not on PATH${RESET} — install it or run with --mock (login will fail without a node)."
    return 1
  }
  if [ ! -d "$NODE_HOME" ]; then
    echo "initializing node (admin: ${ADMIN_USER})…"
    printf '%s' "$ADMIN_PASS" | merod --home "$NODE_HOME" --node app init \
      --server-port "$NODE_PORT" --swarm-port $((NODE_PORT + 1)) \
      --auth-mode embedded --auth-storage persistent \
      --admin-user "$ADMIN_USER" --admin-password-stdin >/dev/null 2>&1 \
      || { echo "${YELLOW}node init failed${RESET}"; return 1; }
  fi
  echo "starting node…"
  merod --home "$NODE_HOME" --node app run > "$REPO_ROOT/.mero-node.log" 2>&1 &
  echo $! > "$REPO_ROOT/.mero-node.pid"
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${NODE_PORT}/admin-api/health" >/dev/null 2>&1; then
      echo "${GREEN}node healthy${RESET} on :${NODE_PORT} — sign in as ${ADMIN_USER} / ${ADMIN_PASS}"
      return 0
    fi
    sleep 1
  done
  echo "${YELLOW}node did not become healthy${RESET} — see .mero-node.log"
  return 1
}

if [ "$MOCK" -eq 0 ] && [ "$MANAGE_NODE" -eq 1 ]; then
  step "Ensuring a Calimero node on :${NODE_PORT}"
  ensure_node || true
fi

# ---- resolve + boot simulator ----------------------------------------------
step "Booting simulator: $DEVICE"
UDID=$(xcrun simctl list devices available | grep -E "^\s*${DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$UDID" ] || die "no available simulator named '$DEVICE' (list: xcrun simctl list devices available | grep iPhone)"
echo "UDID: $UDID"
# Disable the hardware keyboard BEFORE boot so the on-screen keyboard shows and
# you can actually type credentials.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
xcrun simctl boot "$UDID" 2>/dev/null || true   # already-booted is fine
# Open the Simulator GUI so a window actually appears. NOTE: `open -a Simulator`
# fails silently — Simulator.app lives inside Xcode, not /Applications — so open
# it by full path, then bring it to the front.
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null \
  || open -a Simulator 2>/dev/null || true
osascript -e 'tell application "Simulator" to activate' 2>/dev/null || true
xcrun simctl bootstatus "$UDID" 2>/dev/null || sleep 5
# Disable AutoFill Passwords so the "Save/Strong Password" system prompt never
# covers the password field (it otherwise blocks typing → login can't proceed).
xcrun simctl spawn "$UDID" defaults write com.apple.security.AutoFill Enabled -bool NO 2>/dev/null || true
xcrun simctl spawn "$UDID" defaults write com.apple.WebUI AutoFillPasswords -bool NO 2>/dev/null || true

# ---- generate project + build ----------------------------------------------
step "Generating Xcode project"
( cd "$APP_PROJECT_DIR"
  if command -v xcodegen >/dev/null 2>&1; then xcodegen generate
  else echo "${DIM}xcodegen not installed — using committed MeroSampleApp.xcodeproj${RESET}"; fi )

step "Building MeroSampleApp (Debug, simulator)"
BUILD_LOG="$REPO_ROOT/.mero-build.log"
set -o pipefail
if ! xcodebuild \
  -project "$APP_PROJECT_DIR/MeroSampleApp.xcodeproj" \
  -scheme MeroSampleApp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -configuration Debug \
  build > "$BUILD_LOG" 2>&1; then
  echo "${RED}build failed:${RESET}"
  grep -E "error:" "$BUILD_LOG" | head -20
  die "build failed — see $BUILD_LOG (not installing a stale app)"
fi
set +o pipefail
grep -qE "BUILD SUCCEEDED" "$BUILD_LOG" && echo "** BUILD SUCCEEDED **"
# find the freshly built .app
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/MeroSampleApp-"*/Build/Products/Debug-iphonesimulator \
        -maxdepth 1 -name "MeroSampleApp.app" 2>/dev/null | head -1)
[ -n "$APP" ] || die "build succeeded but MeroSampleApp.app not found in DerivedData"
echo "app: $APP"

# ---- install + launch ------------------------------------------------------
step "Installing on simulator (clean reinstall → always the latest build)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
# Also remove the XCUITest runner app that `xcodebuild test` leaves behind, so
# only the real app (with the Calimero icon) is on the home screen.
xcrun simctl uninstall "$UDID" "${BUNDLE_ID}.uitests.xctrunner" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" || die "install failed"

step "Launching ${BUNDLE_ID}  ($([ "$MOCK" -eq 1 ] && echo 'MOCK backend' || echo 'LIVE node'))"
LAUNCH_ARGS=()
[ "$MOCK" -eq 1 ] && LAUNCH_ARGS+=("-uitest-mock")

if [ "$STREAM_LOGS" -eq 1 ]; then
  echo "${DIM}streaming app stdout — Ctrl-C to stop${RESET}"
  xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
  echo
  echo "${GREEN}${BOLD}✔ launched${RESET} in the Simulator."
  if [ "$MOCK" -eq 1 ]; then
    echo "  Log in with ${BOLD}any${RESET} username/password → Home → ${BOLD}Run sample RPC${RESET} (returns 42) → ${BOLD}Log Out${RESET}."
  else
    echo "  Log in with your node's admin creds (e.g. ${BOLD}dev / dev-password${RESET})."
  fi
  echo "  ${DIM}Re-run with --logs to stream the app's stdout.${RESET}"
fi
