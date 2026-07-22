#!/usr/bin/env bash
#
# test-all.sh — run everything in TESTING.md in one shot.
#
# It is RECOVERABLE: a failing step never aborts the run; every remaining step
# still executes. At the end it prints a PASS/FAIL summary of every step.
#
# Usage:
#   ./test-all.sh                 # run all sections (§0–§6)
#   ./test-all.sh --clean         # wipe .build first (after a toolchain change)
#   ./test-all.sh --skip-e2e      # skip §4 live-node e2e (and online MeroExample)
#   ./test-all.sh --skip-ui       # skip §6 simulator UI tests
#   ./test-all.sh --skip-e2e --skip-ui
#
# Exit code: 0 if every executed step passed, 1 if any failed.

set -u  # (no `set -e` — we want to continue past failures)

cd "$(dirname "$0")"           # always run from the repo root
REPO_ROOT="$(pwd)"

# ---- options ---------------------------------------------------------------
CLEAN=0 SKIP_E2E=0 SKIP_UI=0
for arg in "$@"; do
  case "$arg" in
    --clean)    CLEAN=1 ;;
    --skip-e2e) SKIP_E2E=1 ;;
    --skip-ui)  SKIP_UI=1 ;;
    -h|--help)  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

# ---- pretty output ---------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; RESET=""
fi

# ---- result tracking -------------------------------------------------------
STEP_NAMES=(); STEP_RESULTS=(); STEP_SECONDS=()

record() { STEP_NAMES+=("$1"); STEP_RESULTS+=("$2"); STEP_SECONDS+=("${3:-0}"); }

# run_step "Section — name" <command...>   (command runs live; exit code decides)
run_step() {
  local name="$1"; shift
  echo
  echo "${BOLD}${BLUE}▶ ${name}${RESET}"
  local start=$SECONDS
  if "$@"; then
    local dur=$((SECONDS - start))
    echo "${GREEN}✔ PASS${RESET} ${DIM}(${dur}s)${RESET} — ${name}"
    record "$name" PASS "$dur"
    return 0
  else
    local code=$? dur=$((SECONDS - start))
    echo "${RED}✘ FAIL (exit ${code})${RESET} ${DIM}(${dur}s)${RESET} — ${name}"
    record "$name" FAIL "$dur"
    return 1
  fi
}

# mark a step as SKIPPED without running it
skip_step() {
  echo
  echo "${YELLOW}⤼ SKIP${RESET} — $1  ${DIM}($2)${RESET}"
  record "$1" SKIP 0
}

# resolve swift-format (bare binary or via xcrun)
swiftformat() {
  if command -v swift-format >/dev/null 2>&1; then swift-format "$@"
  else xcrun swift-format "$@"; fi
}

# ===========================================================================
echo "${BOLD}MeroKit — full local test run (TESTING.md)${RESET}"
echo "${DIM}repo: ${REPO_ROOT}${RESET}"

# ---------------------------------------------------------------------------
# §0. Prerequisites — verify full Xcode is selected (we can't sudo for you).
# ---------------------------------------------------------------------------
prereq() {
  local ok=0
  echo "xcode-select -p: $(xcode-select -p 2>&1)"
  if xcrun --find xctest >/dev/null 2>&1; then
    echo "${GREEN}XCTest available${RESET}: $(xcrun --find xctest)"
    echo "swift: $(swift --version 2>&1 | head -1)"
  else
    echo "${RED}XCTest NOT found${RESET} — you're on Command Line Tools, not full Xcode."
    local xc; xc=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
    if [ -n "$xc" ]; then
      echo "Run this once (needs your password), then re-run this script:"
      echo "  ${BOLD}sudo xcode-select -s ${xc}/Contents/Developer${RESET}"
    fi
    ok=1
  fi
  return $ok
}
run_step "§0 Prerequisites — full Xcode / XCTest" prereq

if [ "$CLEAN" -eq 1 ]; then
  run_step "§0 Clean — rm -rf .build" bash -c 'rm -rf .build && echo "cleaned"'
else
  echo; echo "${DIM}(skipping .build wipe — pass --clean to force it after a toolchain change)${RESET}"
fi

# ---------------------------------------------------------------------------
# §1. Build
# ---------------------------------------------------------------------------
run_step "§1 Build — swift build" swift build

# ---------------------------------------------------------------------------
# §2. Unit + mocked-e2e tests (live e2e auto-skips)
# ---------------------------------------------------------------------------
run_step "§2 Unit + mocked tests — swift test" swift test

# ---------------------------------------------------------------------------
# §3. Lint (swiftlint + swift-format) — what CI enforces
# ---------------------------------------------------------------------------
if command -v swiftlint >/dev/null 2>&1; then
  run_step "§3 Lint — swiftlint --strict" swiftlint lint --strict
else
  skip_step "§3 Lint — swiftlint --strict" "swiftlint not installed — brew install swiftlint"
fi
run_step "§3 Lint — swift-format --strict" swiftformat lint --recursive --strict Sources Tests Examples

# ---------------------------------------------------------------------------
# §4. Live e2e against a real merod node (+ used by online MeroExample in §5)
# ---------------------------------------------------------------------------
NODE_UP=0
MEROD_BIN=""

boot_node() {
  # pick a merod: PATH first, then ./merod, else download the latest release
  if command -v merod >/dev/null 2>&1; then MEROD_BIN="$(command -v merod)"
  elif [ -x ./merod ]; then MEROD_BIN="./merod"
  else
    echo "downloading released merod (aarch64-apple-darwin)…"
    local TAG URL
    TAG=$(gh release list --repo calimero-network/core --limit 1 --json tagName -q '.[0].tagName') || return 1
    URL=$(gh release view "$TAG" --repo calimero-network/core --json assets \
      -q '.assets[] | select(.name | test("merod_aarch64-apple-darwin\\.tar\\.gz$")) | .url') || return 1
    [ -n "$URL" ] || { echo "no merod darwin asset on $TAG"; return 1; }
    curl -sL "$URL" | tar xz && chmod +x ./merod && MEROD_BIN="./merod"
  fi
  echo "using merod: ${MEROD_BIN} ($("$MEROD_BIN" --version 2>&1 | head -1))"

  rm -rf ./e2e-node
  printf 'dev-password' | "$MEROD_BIN" --home ./e2e-node --node e2e init \
    --server-port 4001 --swarm-port 4002 \
    --auth-mode embedded --auth-storage persistent \
    --admin-user dev --admin-password-stdin || return 1

  "$MEROD_BIN" --home ./e2e-node --node e2e run > merod.log 2>&1 &
  echo $! > merod.pid

  echo -n "waiting for node health"
  for _ in $(seq 1 30); do
    if curl -sf http://localhost:4001/admin-api/health >/dev/null 2>&1; then
      echo " — healthy"; NODE_UP=1; return 0
    fi
    echo -n "."; sleep 1
  done
  echo " — TIMED OUT"; echo "--- last merod.log ---"; tail -20 merod.log 2>/dev/null
  return 1
}

stop_node() {
  if [ -f merod.pid ]; then
    kill "$(cat merod.pid)" 2>/dev/null || true
    rm -f merod.pid
    echo "node stopped"
  fi
}
trap stop_node EXIT

if [ "$SKIP_E2E" -eq 1 ]; then
  skip_step "§4a Boot merod node" "--skip-e2e"
  skip_step "§4b Live e2e — swift test --filter MeroKitE2ETests" "--skip-e2e"
else
  run_step "§4a Boot merod node (rc.17 init-time admin creds)" boot_node
  if [ "$NODE_UP" -eq 1 ]; then
    run_step "§4b Live e2e — swift test --filter MeroKitE2ETests" \
      env MERO_E2E_NODE_URL=http://localhost:4001 MERO_E2E_USER=dev MERO_E2E_PASS=dev-password \
      swift test --filter MeroKitE2ETests
  else
    skip_step "§4b Live e2e — swift test --filter MeroKitE2ETests" "node did not boot"
  fi
fi

# ---------------------------------------------------------------------------
# §5. Runnable example — MeroExample (offline always; online if node is up)
# ---------------------------------------------------------------------------
run_step "§5 MeroExample — offline demo (swift run)" swift run MeroExample
if [ "$NODE_UP" -eq 1 ]; then
  run_step "§5 MeroExample — online flow (auth→rpc→logout)" \
    env MERO_NODE_URL=http://localhost:4001 MERO_USERNAME=dev MERO_PASSWORD=dev-password \
    swift run MeroExample
else
  skip_step "§5 MeroExample — online flow" "no live node"
fi

# ---------------------------------------------------------------------------
# §6. UI tests — MeroSampleApp (XCUITest in the iOS Simulator)
# ---------------------------------------------------------------------------
prep_simulator() {
  # 1) hardware keyboard OFF (host default, applied on next sim boot)
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
  # find the iPhone 17 simulator
  local UDID
  UDID=$(xcrun simctl list devices | grep -E "iPhone 17 \(" | grep -oE '[0-9A-F-]{36}' | head -1)
  [ -n "$UDID" ] || { echo "no 'iPhone 17' simulator found"; return 1; }
  echo "iPhone 17 UDID: $UDID"
  # reboot so the hardware-keyboard pref takes effect
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl boot "$UDID" || return 1
  xcrun simctl bootstatus "$UDID" 2>/dev/null || sleep 5
  # 2) AutoFill Passwords OFF so no "Save Password?" prompt blocks taps
  xcrun simctl spawn "$UDID" defaults write com.apple.security.AutoFill Enabled -bool NO
  xcrun simctl spawn "$UDID" defaults write com.apple.WebUI AutoFillPasswords -bool NO
  echo "simulator prepared (hardware keyboard off, autofill off)"
}

run_ui_tests() {
  ( cd Examples/MeroSampleApp
    if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; else
      echo "xcodegen not installed — using committed MeroSampleApp.xcodeproj"; fi
    xcodebuild test \
      -project MeroSampleApp.xcodeproj \
      -scheme MeroSampleApp \
      -destination 'platform=iOS Simulator,name=iPhone 17' )
}

if [ "$SKIP_UI" -eq 1 ]; then
  skip_step "§6 Simulator prep (keyboard + autofill)" "--skip-ui"
  skip_step "§6 UI tests — xcodebuild test" "--skip-ui"
else
  run_step "§6 Simulator prep (keyboard + autofill)" prep_simulator
  run_step "§6 UI tests — MeroSampleApp XCUITest" run_ui_tests
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "${BOLD}────────────────────────── SUMMARY ──────────────────────────${RESET}"
pass=0; fail=0; skip=0
for i in "${!STEP_NAMES[@]}"; do
  case "${STEP_RESULTS[$i]}" in
    PASS) icon="${GREEN}✔ PASS${RESET}"; pass=$((pass+1)) ;;
    FAIL) icon="${RED}✘ FAIL${RESET}"; fail=$((fail+1)) ;;
    SKIP) icon="${YELLOW}– SKIP${RESET}"; skip=$((skip+1)) ;;
  esac
  printf "  %b  %-55s %s\n" "$icon" "${STEP_NAMES[$i]}" "${DIM}${STEP_SECONDS[$i]}s${RESET}"
done
echo "${BOLD}──────────────────────────────────────────────────────────────${RESET}"
echo "  ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}, ${YELLOW}${skip} skipped${RESET}   (of $(( pass + fail + skip )) steps)"
echo

[ "$fail" -eq 0 ]
