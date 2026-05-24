#!/usr/bin/env bash
# NexGenSpec App Store screenshot capture helper.
#
# Workflow:
#   ./scripts/screenshots.sh prep iphone-pro-max light    # boot + install + set appearance + launch
#   ./scripts/screenshots.sh prep iphone-pro    dark
#   ./scripts/screenshots.sh prep ipad-13       light
#
# Then drive the UI manually on the simulator. After each shot:
#   ./scripts/screenshots.sh shot 01-dashboard
#
# Output lands at:
#   marketing/screenshots/<device>-<appearance>/<NN-name>.png
#
# Re-runnable: each `prep` boots/installs cleanly, each `shot` overwrites.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$REPO_ROOT/marketing/screenshots"
APP_PATH_SIM="$HOME/Library/Developer/Xcode/DerivedData/NexGenSpec-errgrofrtszgelfppunfgitduupk/Build/Products/Debug-iphonesimulator/NexGenSpec.app"
BUNDLE_ID="com.nexgenspec.app"

# Device → preferred simulator name. Apple's required screenshot sizes map to these.
# 6.9" required, 6.3" required, iPad 13" required (per T-01366 spec).
declare -A DEVICE_SIM=(
  [iphone-pro-max]="iPhone 17 Pro Max"   # 6.9", 1320x2868
  [iphone-pro]="iPhone 17 Pro"           # 6.3", 1206x2622
  [ipad-13]="iPad Pro 13-inch (M5)"      # 13",  2048x2732
)

CURRENT_DEVICE_FILE="/tmp/ngs-screenshot-current-device"
CURRENT_APPEARANCE_FILE="/tmp/ngs-screenshot-current-appearance"

die() { echo "error: $*" >&2; exit 1; }

ensure_app_built() {
  [[ -d "$APP_PATH_SIM" ]] || die "Simulator .app not found at $APP_PATH_SIM. Build it first: xcodebuild -project NexGenSpec.xcodeproj -scheme NexGenSpec -configuration Debug -destination 'generic/platform=iOS Simulator' build"
}

cmd_prep() {
  local device="${1:-}" appearance="${2:-light}"
  [[ -n "$device" ]] || die "usage: $0 prep <iphone-pro-max|iphone-pro|ipad-13> [light|dark]"
  local sim_name="${DEVICE_SIM[$device]:-}"
  [[ -n "$sim_name" ]] || die "unknown device '$device'. choices: ${!DEVICE_SIM[*]}"
  [[ "$appearance" == "light" || "$appearance" == "dark" ]] || die "appearance must be light or dark"

  ensure_app_built

  echo "→ Shutting down any booted sims..."
  xcrun simctl shutdown all 2>/dev/null || true

  echo "→ Booting '$sim_name'..."
  xcrun simctl boot "$sim_name"

  echo "→ Waiting for boot..."
  xcrun simctl bootstatus "$sim_name" -b >/dev/null

  echo "→ Setting appearance: $appearance"
  xcrun simctl ui booted appearance "$appearance"

  echo "→ Installing NexGenSpec..."
  xcrun simctl install booted "$APP_PATH_SIM"

  echo "→ Launching app..."
  xcrun simctl launch booted "$BUNDLE_ID" >/dev/null

  echo "→ Opening Simulator.app..."
  open -a Simulator

  echo "$device" > "$CURRENT_DEVICE_FILE"
  echo "$appearance" > "$CURRENT_APPEARANCE_FILE"

  mkdir -p "$ASSETS_DIR/$device-$appearance"

  cat <<EOF

✓ Ready.

Current target: $device ($sim_name) / $appearance
Output folder:  $ASSETS_DIR/$device-$appearance/

Drive the UI on the simulator. After each screen:
  ./scripts/screenshots.sh shot <name>

Example:
  ./scripts/screenshots.sh shot 01-dashboard
  ./scripts/screenshots.sh shot 02-overview
  ...
EOF
}

cmd_shot() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: $0 shot <name> (e.g. 01-dashboard)"
  [[ -f "$CURRENT_DEVICE_FILE" && -f "$CURRENT_APPEARANCE_FILE" ]] || die "no active session. run: $0 prep <device> <appearance> first"

  local device appearance
  device=$(cat "$CURRENT_DEVICE_FILE")
  appearance=$(cat "$CURRENT_APPEARANCE_FILE")
  local out_dir="$ASSETS_DIR/$device-$appearance"
  mkdir -p "$out_dir"
  local out="$out_dir/$name.png"

  xcrun simctl io booted screenshot "$out"
  local size
  size=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | awk '/pixelWidth|pixelHeight/{print $2}' | paste -sd× -)
  echo "✓ $out  ($size)"
}

cmd_status() {
  if [[ -f "$CURRENT_DEVICE_FILE" ]]; then
    echo "device:     $(cat "$CURRENT_DEVICE_FILE")"
    echo "appearance: $(cat "$CURRENT_APPEARANCE_FILE")"
    echo "output:     $ASSETS_DIR/$(cat "$CURRENT_DEVICE_FILE")-$(cat "$CURRENT_APPEARANCE_FILE")/"
  else
    echo "no active session. run: $0 prep <device> <appearance>"
  fi
  echo ""
  echo "current booted sim(s):"
  xcrun simctl list devices booted | grep -E "iPhone|iPad" || echo "  (none)"
}

cmd_clean() {
  echo "→ Shutting down all sims..."
  xcrun simctl shutdown all 2>/dev/null || true
  rm -f "$CURRENT_DEVICE_FILE" "$CURRENT_APPEARANCE_FILE"
  echo "✓ cleaned"
}

cmd_help() {
  cat <<EOF
NexGenSpec screenshot capture helper.

Usage:
  $0 prep <device> <appearance>   boot + install + set appearance + launch
  $0 shot <name>                  capture booted sim → marketing/screenshots/<device>-<appearance>/<name>.png
  $0 status                       show current session
  $0 clean                        shut down all sims, clear session
  $0 help                         this message

Devices:
  iphone-pro-max   6.9"  (iPhone 17 Pro Max,  1320x2868) — REQUIRED
  iphone-pro       6.3"  (iPhone 17 Pro,      1206x2622) — REQUIRED
  ipad-13          13"   (iPad Pro 13" M5,    2048x2732) — REQUIRED

Appearance: light | dark

Example flow (60 screenshots, 6 sessions):
  ./scripts/screenshots.sh prep iphone-pro-max light
  ./scripts/screenshots.sh shot 01-dashboard
  ./scripts/screenshots.sh shot 02-overview
  ... (10 shots) ...
  ./scripts/screenshots.sh prep iphone-pro-max dark
  ... (10 shots) ...
  ./scripts/screenshots.sh prep iphone-pro light
  ...
EOF
}

case "${1:-help}" in
  prep)   shift; cmd_prep "$@" ;;
  shot)   shift; cmd_shot "$@" ;;
  status) cmd_status ;;
  clean)  cmd_clean ;;
  help|--help|-h) cmd_help ;;
  *) cmd_help; exit 1 ;;
esac
