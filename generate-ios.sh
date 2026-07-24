#!/usr/bin/env bash
#
# generate-ios.sh — build & install the MeroSampleApp onto a PHYSICAL iPhone for
# development, with NO App Store and NO paid ($99) Apple Developer Program. A
# plain Apple ID (your iCloud account) works as a free "Personal Team".
#
# What it automates:
#   • patches project.yml so the app can reach a plaintext-HTTP node on your LAN
#       - NSAppTransportSecurity  → allow HTTP (iOS blocks cleartext by default)
#       - NSLocalNetworkUsageDescription → the iOS 14+ local-network permission
#       - DefaultNodeURL          → pre-fills the login field with your Mac's LAN URL
#   • runs xcodegen, auto-detects your connected iPhone + your Mac's LAN IP
#   • builds with automatic signing (-allowProvisioningUpdates) and installs to
#     the device via devicectl, then launches it
#   • optionally boots a LAN-reachable merod node (--boot-node)
#
# ONE-TIME MANUAL STEP (a script cannot do this — it needs your Apple ID
# password + 2FA):  add your Apple ID to Xcode and do the very first signed
# build to your device from the Xcode GUI. That makes Xcode create the signing
# certificate and register your iPhone. After that, THIS SCRIPT works from the
# CLI every time. If no signing certificate is found, the script stops and
# prints exactly what to click. (Free-account apps expire after 7 days — just
# re-run this script to refresh.)
#
# Usage:
#   ./generate-ios.sh                          # auto-detect team, device, LAN IP
#   ./generate-ios.sh --team ABCDE12345         # force a signing team id
#   ./generate-ios.sh --bundle-id network.calimero.merokit.sample.fran
#   ./generate-ios.sh --node-url http://192.168.1.5:2528
#   ./generate-ios.sh --device 00008120-0011...  # target a specific device udid
#   ./generate-ios.sh --boot-node               # also start a LAN-bound merod node
#   ./generate-ios.sh --no-install              # build only, don't install/launch
#
#   ./generate-ios.sh --duo                     # DUAL dev setup (no signing needed):
#       • boots node A (:4001) for a SIMULATOR running the app on your Mac
#       • boots node B (:4011) bound to 0.0.0.0, P2P-peered with A, for your PHONE
#       • runs the app in one simulator (→ node A) and prints the LAN URL to type
#         on your phone (→ node B). The two nodes sync, so the simulator and the
#         phone see each other's data.
#     Override the simulator with --sim-device 'iPhone 17 Pro'.
#
set -u
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
APP_DIR="Examples/MeroSampleApp"
SCHEME="MeroSampleApp"
PROJ="$APP_DIR/MeroSampleApp.xcodeproj"
DERIVED="$REPO_ROOT/.ios-build"

# ---- options ---------------------------------------------------------------
TEAM=""
BUNDLE_ID="network.calimero.merokit.sample"
NODE_URL=""
DEVICE_ID=""
BOOT_NODE=0
DO_INSTALL=1
DUO=0
SIM_DEVICE="iPhone 17"
NODE_PORT=2528
SWARM_PORT=2428
ADMIN_USER="dev"
ADMIN_PASS="dev-password"
while [ $# -gt 0 ]; do
  case "$1" in
    --team)       TEAM="${2:?--team needs a value}"; shift ;;
    --bundle-id)  BUNDLE_ID="${2:?--bundle-id needs a value}"; shift ;;
    --node-url)   NODE_URL="${2:?--node-url needs a value}"; shift ;;
    --device)     DEVICE_ID="${2:?--device needs a udid}"; shift ;;
    --boot-node)  BOOT_NODE=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --duo)        DUO=1 ;;
    --sim-device) SIM_DEVICE="${2:?--sim-device needs a name}"; shift ;;
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
ok()   { echo "${GREEN}✔ $*${RESET}"; }

# ---- --duo: node A + simulator (on Mac) + node B (LAN) for the phone --------
# Boots two P2P-peered merods (A for the simulator, B bound to 0.0.0.0 for the
# phone), runs the app in one simulator pointed at A, and prints the LAN URL to
# type on the phone (→ B). No code signing needed — the simulator uses none.
run_duo() {
  command -v merod >/dev/null 2>&1 || die "merod not on PATH"

  step "Fresh start — stopping simulators & any prior duo nodes"
  osascript -e 'quit app "Simulator"' 2>/dev/null || true
  xcrun simctl shutdown all 2>/dev/null || true
  for f in .mero-a.pid .mero-b.pid; do [ -f "$REPO_ROOT/$f" ] && kill "$(cat "$REPO_ROOT/$f")" 2>/dev/null || true; done
  for p in "$DUO_A_SERVER" "$DUO_B_SERVER"; do
    pids=$(lsof -ti "tcp:$p" 2>/dev/null || true); [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  done
  rm -rf "$REPO_ROOT/.mero-a" "$REPO_ROOT/.mero-b" "$REPO_ROOT"/.mero-a.* "$REPO_ROOT"/.mero-b.*

  step "Boot node A (:$DUO_A_SERVER) — for the simulator on this Mac"
  printf '%s' "$ADMIN_PASS" | merod --home "$REPO_ROOT/.mero-a" --node a init \
    --server-port "$DUO_A_SERVER" --swarm-port "$DUO_A_SWARM" \
    --auth-mode embedded --auth-storage persistent \
    --admin-user "$ADMIN_USER" --admin-password-stdin --mdns >/dev/null 2>&1 || die "node A init failed"
  merod --home "$REPO_ROOT/.mero-a" --node a run > "$REPO_ROOT/.mero-a.log" 2>&1 &
  echo $! > "$REPO_ROOT/.mero-a.pid"
  until curl -sf "http://127.0.0.1:$DUO_A_SERVER/admin-api/health" >/dev/null 2>&1; do sleep 1; done
  ok "node A healthy on :$DUO_A_SERVER"
  sleep 3
  # A's swarm multiaddr so B can peer with it (mDNS is flaky for two merods/host)
  BOOT=$(grep -oE "/ip4/127\.0\.0\.1/tcp/$DUO_A_SWARM/p2p/[A-Za-z0-9]+" "$REPO_ROOT/.mero-a.log" | head -1)
  echo "  node A peer addr: ${BOOT:-<none — relying on mDNS>}"

  step "Boot node B (:$DUO_B_SERVER) — bound to 0.0.0.0 for your phone"
  BOOT_ARGS=(); [ -n "$BOOT" ] && BOOT_ARGS=(--boot-nodes "$BOOT")
  printf '%s' "$ADMIN_PASS" | merod --home "$REPO_ROOT/.mero-b" --node b init \
    --server-host 0.0.0.0 --server-port "$DUO_B_SERVER" --swarm-port "$DUO_B_SWARM" \
    --auth-mode embedded --auth-storage persistent \
    --admin-user "$ADMIN_USER" --admin-password-stdin --mdns \
    ${BOOT_ARGS[@]+"${BOOT_ARGS[@]}"} >/dev/null 2>&1 || die "node B init failed"
  merod --home "$REPO_ROOT/.mero-b" --node b run > "$REPO_ROOT/.mero-b.log" 2>&1 &
  echo $! > "$REPO_ROOT/.mero-b.pid"
  until curl -sf "http://127.0.0.1:$DUO_B_SERVER/admin-api/health" >/dev/null 2>&1; do sleep 1; done
  ok "node B healthy on :$DUO_B_SERVER"
  # Prove node B is reachable on the LAN IP (this is exactly what the phone hits).
  if curl -sf -o /dev/null "${NODE_URL}/admin-api/health" 2>/dev/null; then
    ok "node B reachable from the LAN at ${NODE_URL}  ← your phone uses this"
  else
    echo "${YELLOW}⚠ node B not answering on ${NODE_URL} — check your Mac firewall / Wi-Fi.${RESET}"
  fi
  echo "  ${DIM}giving A↔B a few seconds to find each other on the P2P layer…${RESET}"; sleep 6

  step "Boot simulator: $SIM_DEVICE"
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
  UDID=$(xcrun simctl list devices available | grep -E "^\s*${SIM_DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
  if [ -z "$UDID" ]; then
    SIM_DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9][^(]*' | sed 's/ *$//' | head -1)
    UDID=$(xcrun simctl list devices available | grep -E "^\s*${SIM_DEVICE} \(" | grep -oE '[0-9A-F-]{36}' | head -1)
    echo "  auto-picked simulator: $SIM_DEVICE"
  fi
  [ -n "$UDID" ] || die "no available simulator found (xcrun simctl list devices available)"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" 2>/dev/null || true
  open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true

  step "Build app for the simulator"
  rm -rf "$DERIVED-sim"
  set -o pipefail
  xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED-sim" build \
    > "$REPO_ROOT/.mero-build.log" 2>&1 || { grep -E "error:" "$REPO_ROOT/.mero-build.log" | head; die "build failed (see .mero-build.log)"; }
  set +o pipefail
  APP="$DERIVED-sim/Build/Products/Debug-iphonesimulator/${SCHEME}.app"
  [ -d "$APP" ] || die "built app not found at $APP"
  ok "built"

  step "Install + launch on the simulator (→ node A)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP" || die "install failed"
  # Point the simulator's app at node A; the phone uses the baked LAN URL (node B).
  SIMCTL_CHILD_E2E_NODE="http://localhost:$DUO_A_SERVER" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  osascript -e 'tell application "Simulator" to activate' 2>/dev/null || true

  echo
  echo "${BOLD}${GREEN}✔ Duo dev setup running.${RESET}"
  echo "  • Simulator ($SIM_DEVICE) → node A  ${BOLD}http://localhost:$DUO_A_SERVER${RESET}"
  echo "  • Your phone   → node B  ${BOLD}${NODE_URL}${RESET}   ${DIM}(type this in the app's Node URL field)${RESET}"
  echo "  • Sign in as ${BOLD}${ADMIN_USER} / ${ADMIN_PASS}${RESET} on both. A and B are P2P-peered, so their data syncs."
  echo "  • ${DIM}Phone on the SAME Wi-Fi as this Mac. Stop nodes: kill \$(cat .mero-a.pid) \$(cat .mero-b.pid)${RESET}"
  echo "  • ${DIM}The app must already be installed on your phone (run ./generate-ios.sh without --duo to install it).${RESET}"
}

# ---- prereqs ---------------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found — brew install xcodegen"
xcrun --find xcodebuild >/dev/null 2>&1 || die "full Xcode not selected — sudo xcode-select -s /Applications/Xcode.app"

# ---- Mac LAN IP + node URL -------------------------------------------------
# In --duo mode the phone talks to node B (:4011); otherwise the single LAN node.
DUO_A_SERVER=4001; DUO_A_SWARM=4002; DUO_B_SERVER=4011; DUO_B_SWARM=4012
[ "$DUO" -eq 1 ] && NODE_PORT="$DUO_B_SERVER"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[ -n "$LAN_IP" ] || die "could not determine your Mac's LAN IP (are you on WiFi?) — pass --node-url explicitly"
[ -n "$NODE_URL" ] || NODE_URL="http://${LAN_IP}:${NODE_PORT}"
ok "Mac LAN IP: ${LAN_IP}  →  node URL for the phone: ${BOLD}${NODE_URL}${RESET}"

# ---- patch project.yml (ATS + local-network + DefaultNodeURL) --------------
step "Patching ${APP_DIR}/project.yml for LAN/HTTP access"
NODE_URL="$NODE_URL" BUNDLE_ID="$BUNDLE_ID" python3 - "$APP_DIR/project.yml" <<'PY'
import os, re, sys
path = sys.argv[1]
node_url = os.environ["NODE_URL"]
bundle   = os.environ["BUNDLE_ID"]
src = open(path).read()

# keep the bundle id in sync with what we sign/install
src = re.sub(r'(PRODUCT_BUNDLE_IDENTIFIER:\s*)network\.calimero\.merokit\.sample(?!\.)',
             r'\g<1>' + bundle, src, count=1)

info_block = (
    "    info:\n"
    "      path: Sources/Generated-Info.plist\n"
    "      properties:\n"
    "        UILaunchScreen: {}\n"
    "        DefaultNodeURL: \"%s\"\n"
    "        NSLocalNetworkUsageDescription: \"Connect to a Calimero node running on your Mac over the local network for development.\"\n"
    "        NSAppTransportSecurity:\n"
    "          NSAllowsArbitraryLoads: true\n"
) % node_url

if "NSLocalNetworkUsageDescription" not in src:
    # a manual Info.plist replaces the auto-generated one
    src = re.sub(r'^\s*GENERATE_INFOPLIST_FILE:\s*YES\s*\n', '', src, flags=re.M)
    src = re.sub(r'^\s*INFOPLIST_KEY_UILaunchScreen_Generation:\s*YES\s*\n', '', src, flags=re.M)
    # insert the info: block right after the app target's `type: application`
    src = re.sub(r'(^  MeroSampleApp:\n(?:.*\n)*?    type: application\n)',
                 r'\1' + info_block, src, count=1, flags=re.M)
    print("  inserted info: block (ATS + local network + DefaultNodeURL)")
else:
    # already patched — just refresh the baked-in node URL
    src = re.sub(r'(DefaultNodeURL:\s*)"[^"]*"', r'\g<1>"%s"' % node_url, src, count=1)
    print("  refreshed DefaultNodeURL")

open(path, "w").write(src)
PY
[ $? -eq 0 ] || die "project.yml patch failed"
ok "project.yml patched"

# ---- generate the Xcode project -------------------------------------------
step "Generating Xcode project (xcodegen)"
( cd "$APP_DIR" && xcodegen generate ) || die "xcodegen failed"
ok "project generated"

# ---- --duo mode: two nodes + a simulator, no signing; then done ------------
if [ "$DUO" -eq 1 ]; then
  run_duo
  exit 0
fi

# ---- resolve signing team --------------------------------------------------
detect_team() {
  # OU of the "Apple Development" cert == the team id (works for free Personal Teams)
  security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU *= *[A-Z0-9]{10}' | head -1 | grep -oE '[A-Z0-9]{10}$'
}
if [ -z "$TEAM" ]; then TEAM="$(detect_team || true)"; fi

if [ -z "$TEAM" ]; then
  echo
  echo "${YELLOW}No signing certificate found yet.${RESET} This is the one-time step a script"
  echo "cannot do for you (it needs your Apple ID password + 2FA). Do this ONCE:"
  echo
  echo "  1. ${BOLD}open $PROJ${RESET}"
  echo "  2. Xcode → Settings (⌘,) → Accounts → ${BOLD}+${RESET} → Apple ID → sign in with your iCloud account"
  echo "  3. Select the ${BOLD}$SCHEME${RESET} target → Signing & Capabilities tab"
  echo "     → tick ${BOLD}Automatically manage signing${RESET}"
  echo "     → Team = your name ${DIM}(Personal Team)${RESET}"
  echo "     → if it complains the bundle id is taken, change it (e.g. ${BUNDLE_ID}.$(whoami))"
  echo "  4. Plug in your iPhone, trust the Mac, pick it as the run target, press ${BOLD}⌘R${RESET} once."
  echo "     On the phone: Settings → General → VPN & Device Management → trust your developer cert."
  echo
  echo "That first run creates your signing cert and registers the phone. Then just re-run:"
  echo "  ${BOLD}./generate-ios.sh${RESET}   ${DIM}# fully automated from here on${RESET}"
  echo
  open "$PROJ" 2>/dev/null || true
  exit 0
fi
ok "signing team: ${TEAM}"

# ---- find the connected device --------------------------------------------
if [ -z "$DEVICE_ID" ]; then
  step "Looking for a connected iPhone"
  # devicectl JSON → grab the first connected/available device udid
  DEVLIST="$(xcrun devicectl list devices 2>/dev/null)"
  echo "$DEVLIST"
  DEVICE_ID="$(echo "$DEVLIST" | grep -iE "connected|available|paired" \
                | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-F]{40}' | head -1)"
  [ -n "$DEVICE_ID" ] || die "no connected iPhone found — plug it in, unlock it, tap Trust, then retry (or pass --device <udid>)"
fi
ok "target device: ${DEVICE_ID}"

# ---- optional: boot a LAN-bound merod node ---------------------------------
if [ "$BOOT_NODE" -eq 1 ]; then
  step "Booting a LAN-reachable merod node on ${LAN_IP}:${NODE_PORT}"
  command -v merod >/dev/null 2>&1 || die "merod not on PATH"
  NODE_HOME="$REPO_ROOT/.mero-node-lan"
  if curl -sf "http://127.0.0.1:${NODE_PORT}/admin-api/health" >/dev/null 2>&1; then
    ok "a node is already answering on :${NODE_PORT}"
  else
    if [ ! -d "$NODE_HOME" ]; then
      echo "initializing node (admin: ${ADMIN_USER}) bound to 0.0.0.0…"
      printf '%s' "$ADMIN_PASS" | merod --home "$NODE_HOME" --node lan init \
        --server-host 0.0.0.0 --server-port "$NODE_PORT" --swarm-port "$SWARM_PORT" \
        --auth-mode embedded --auth-storage persistent \
        --admin-user "$ADMIN_USER" --admin-password-stdin >/dev/null 2>&1 \
        || die "node init failed"
    fi
    merod --home "$NODE_HOME" --node lan run > "$REPO_ROOT/.mero-node-lan.log" 2>&1 &
    echo $! > "$REPO_ROOT/.mero-node-lan.pid"
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:${NODE_PORT}/admin-api/health" >/dev/null 2>&1 && break
      sleep 1
    done
    ok "node running (pid $(cat "$REPO_ROOT/.mero-node-lan.pid")) — sign in as ${ADMIN_USER} / ${ADMIN_PASS}"
    echo "${DIM}  stop it with: kill \$(cat $REPO_ROOT/.mero-node-lan.pid)${RESET}"
  fi
fi

# ---- build (automatic signing, provisioning updates) -----------------------
step "Building ${SCHEME} for the device (automatic signing)"
rm -rf "$DERIVED"
xcodebuild \
  -project "$PROJ" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build || die "xcodebuild failed (see output above — signing/team issues show here)"

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/${SCHEME}.app"
[ -d "$APP_PATH" ] || die "build succeeded but .app not found at $APP_PATH"
ok "built: $APP_PATH"

if [ "$DO_INSTALL" -eq 0 ]; then
  echo "${DIM}--no-install: skipping install. App is at $APP_PATH${RESET}"
  exit 0
fi

# ---- install + launch on device -------------------------------------------
step "Installing on device ${DEVICE_ID}"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" || die "install failed"
ok "installed"

step "Launching on device"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null \
  && ok "launched" \
  || echo "${YELLOW}couldn't auto-launch — just tap the app icon on your phone.${RESET}"

echo
echo "${BOLD}${GREEN}Done.${RESET}"
echo "  • App installed on your iPhone (bundle id: ${BUNDLE_ID})"
echo "  • Node URL is pre-filled to ${BOLD}${NODE_URL}${RESET} — sign in with your node's admin creds"
[ "$BOOT_NODE" -eq 1 ] && echo "  • Local node running as ${ADMIN_USER} / ${ADMIN_PASS}"
echo "  • ${DIM}Free-account builds expire after ~7 days; re-run this script to refresh.${RESET}"
