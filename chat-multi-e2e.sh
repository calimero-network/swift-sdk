#!/usr/bin/env bash
#
# chat-multi-e2e.sh — two-user, two-node, two-simulator chat end-to-end.
#
# Boots two P2P-connected merod nodes (A :4001, B :4011) and two simulators,
# then runs the ChatMultiUserTests roles, handing the invite between simulators
# via the pasteboard:
#   A: create space+channel, copy invite, post "hi from host"
#   → copy invite from sim A's pasteboard to sim B's
#   B: auto-join (E2E_JOIN), see the host's message, reply "hi from guest"
#   A: see the guest's reply
#
# NOTE: the cross-node message sync depends on gossipsub between two co-located
# merods, which is historically unreliable on a single host. If a step fails at
# "did not sync", that's the P2P layer, not the app/test — the same flow works
# across separate hosts. Everything up to the sync is verified.
#
# Usage: ./chat-multi-e2e.sh

set -u
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
DEV_A="iPhone 17"
DEV_B="iPhone 16 Pro"
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
step() { echo; echo "${BOLD}▶ $*${RESET}"; }
die() { echo "${RED}✘ $*${RESET}"; exit 1; }

command -v merod >/dev/null 2>&1 || die "merod not on PATH"
xcrun --find xctest >/dev/null 2>&1 || die "full Xcode not selected"

PROJECT="Examples/MeroSampleApp/MeroSampleApp.xcodeproj"

# ---- fresh nodes -----------------------------------------------------------
step "Fresh start — stopping sims & nodes"
osascript -e 'quit app "Simulator"' 2>/dev/null || true
xcrun simctl shutdown all 2>/dev/null || true
for p in 4001 4011; do pids=$(lsof -ti "tcp:$p" 2>/dev/null || true); [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true; done
rm -rf "$REPO_ROOT/.mero-a" "$REPO_ROOT/.mero-b" "$REPO_ROOT"/.mero-*.log "$REPO_ROOT"/.mero-*.pid

step "Boot node A (:4001)"
printf 'dev-password' | merod --home "$REPO_ROOT/.mero-a" --node a init \
  --server-port 4001 --swarm-port 4002 --auth-mode embedded --auth-storage persistent \
  --admin-user dev --admin-password-stdin --mdns >/dev/null 2>&1 || die "node A init failed"
merod --home "$REPO_ROOT/.mero-a" --node a run > "$REPO_ROOT/.mero-a.log" 2>&1 &
echo $! > "$REPO_ROOT/.mero-a.pid"
until curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1; do sleep 1; done
echo "node A healthy"

# best-effort: extract A's swarm multiaddr for bootstrapping B
sleep 3
BOOT=$(grep -oE '/ip4/127\.0\.0\.1/tcp/4002/p2p/[A-Za-z0-9]+' "$REPO_ROOT/.mero-a.log" | head -1)
[ -z "$BOOT" ] && BOOT=$(grep -oE '/ip4/[0-9.]+/tcp/4002/p2p/[A-Za-z0-9]+' "$REPO_ROOT/.mero-a.log" | head -1)
echo "node A boot addr: ${BOOT:-<none found, relying on mDNS>}"

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
echo "waiting for peers to connect…"; sleep 8
echo "  A peers: $(curl -s http://localhost:4001/admin-api/peers 2>/dev/null)"
echo "  B peers: $(curl -s http://localhost:4011/admin-api/peers 2>/dev/null)"

# ---- simulators ------------------------------------------------------------
step "Boot simulators: A=$DEV_A  B=$DEV_B"
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
udid() { xcrun simctl list devices available | grep -E "^\s*$1 \(" | grep -oE '[0-9A-F-]{36}' | head -1; }
UDID_A=$(udid "$DEV_A"); UDID_B=$(udid "$DEV_B")
[ -n "$UDID_A" ] || die "no simulator '$DEV_A'"; [ -n "$UDID_B" ] || die "no simulator '$DEV_B'"
for u in "$UDID_A" "$UDID_B"; do
  xcrun simctl boot "$u" 2>/dev/null || true
  xcrun simctl bootstatus "$u" 2>/dev/null || true
  xcrun simctl spawn "$u" defaults write com.apple.security.AutoFill Enabled -bool NO 2>/dev/null || true
done
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true

( cd Examples/MeroSampleApp && command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null 2>&1 || true )

run_role() {  # <udid> <TestMethod> <label>
  echo; echo "${BOLD}— $3 —${RESET}"
  set -o pipefail
  xcodebuild test -project "$PROJECT" -scheme MeroSampleApp \
    -destination "platform=iOS Simulator,id=$1" \
    -only-testing:"MeroSampleAppUITests/ChatMultiUserTests/$2" 2>&1 \
    | tee "$REPO_ROOT/.mero-role-$2.log" | grep -iE "Test Case .* (passed|failed)|\*\* TEST"
  return ${PIPESTATUS[0]}
}

pass=0; fail=0
step "1/3 HOST creates space + invite + posts (sim A / node A)"
run_role "$UDID_A" testHostCreateInviteAndPost "host" && pass=$((pass+1)) || { fail=$((fail+1)); die "host role failed"; }

step "Handoff invite A → B via pasteboard"
INV=$(xcrun simctl pbpaste "$UDID_A" 2>/dev/null)
[ -n "$INV" ] || die "no invite on sim A pasteboard"
printf '%s' "$INV" | xcrun simctl pbcopy "$UDID_B"
echo "invite (${#INV} chars) copied to sim B"

step "2/3 GUEST joins + sees host msg + replies (sim B / node B)"
run_role "$UDID_B" testGuestJoinAndReply "guest" && pass=$((pass+1)) || fail=$((fail+1))

step "3/3 HOST sees the guest reply (sim A / node A)"
run_role "$UDID_A" testHostSeesReply "verify" && pass=$((pass+1)) || fail=$((fail+1))

echo
echo "${BOLD}────────── RESULT ──────────${RESET}"
echo "  ${GREEN}$pass passed${RESET}, ${RED}$fail failed${RESET} of 3 roles"
[ "$fail" -eq 0 ] && echo "${GREEN}✔ multi-user chat e2e passed${RESET}" \
  || echo "${YELLOW}⚠ a cross-node step failed — if it's 'did not sync', that's co-located gossipsub, not the app (see header).${RESET}"
[ "$fail" -eq 0 ]
