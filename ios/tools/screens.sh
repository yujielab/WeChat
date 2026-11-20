#!/usr/bin/env bash
# Runs the Simulator build against the seeded local hub and photographs each
# screen. Usage: screens.sh <udid> phone|duo   Output: ios/screens/*.png
#   phone: the one-column layout on an iPhone.
#   duo:   the iPhone Duo's outer and inner displays, laid out by the app
#          itself (CUVEN_EMULATE) inside an iPad, then cropped to size.
set -uo pipefail
U=$1
KIND=$2
APP=ios/build/sim/Build/Products/Debug-iphonesimulator/Cuven.app
OUT=ios/screens
mkdir -p "$OUT"

# Nothing here may hang the job: every simulator call has a time limit.
t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

t 900 xcrun simctl bootstatus "$U" -b >/dev/null || echo "boot wait timed out"
t 30 xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
t 300 xcrun simctl install "$U" "$APP" || { echo "install failed"; exit 1; }

# Crops the emulated display out of the top-left corner (points × 2 or 3).
crop() { # file width height
  python3 - "$1" "$2" "$3" <<'PY' || true
import sys
from PIL import Image
f, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
im = Image.open(f)
scale = round(im.width / 1032) if im.width >= 1500 else 2
im.crop((0, 0, w * scale, h * scale)).save(f)
PY
}

shoot() { # name screen [appearance] [wait] [signin] [emulate]
  local N=$1 S=$2 L=${3:-light} W=${4:-6} SIGN=${5:-1} E=${6:-}
  t 30 xcrun simctl terminate "$U" us.cuven.app 2>/dev/null || true
  local envs=(SIMCTL_CHILD_CUVEN_SERVER=http://localhost:8787 SIMCTL_CHILD_CUVEN_SCREEN="$S" SIMCTL_CHILD_CUVEN_APPEARANCE="$L")
  [ "$SIGN" = 1 ] && envs+=(SIMCTL_CHILD_CUVEN_USER=alice SIMCTL_CHILD_CUVEN_PASS=cuven-demo)
  [ -n "$E" ] && envs+=(SIMCTL_CHILD_CUVEN_EMULATE="$E")
  if ! env "${envs[@]}" perl -e 'alarm shift; exec @ARGV' 180 xcrun simctl launch "$U" us.cuven.app >/dev/null; then
    echo "launch failed for $N"
    return
  fi
  sleep "$W"
  local F="$OUT/$KIND-$N.png"
  if t 60 xcrun simctl io "$U" screenshot "$F" >/dev/null 2>&1; then
    case "$E" in
      outer) crop "$F" 466 678 ;;
      inner) crop "$F" 951 669 ;;
    esac
    echo "shot $KIND-$N"
  else
    echo "no shot $KIND-$N"
  fi
}

if [ "$KIND" = phone ]; then
  shoot 01-auth auth light 6 0
  shoot 02-list list light 12
  shoot 03-thread thread
  shoot 04-focus focus light 8
  shoot 05-plus plus light 7
  shoot 06-info info light 7
  shoot 07-sidebar sidebar
  shoot 08-search search light 7
  shoot 09-thread-dark thread dark
else
  # The outer display (folded).
  shoot outer-00-auth auth light 6 0 outer
  shoot outer-01-list list light 12 1 outer
  shoot outer-01-list-dark list dark 8 1 outer
  shoot outer-02-sidebar sidebar light 6 1 outer
  shoot outer-03-search search light 7 1 outer
  shoot outer-04-thread thread light 6 1 outer
  shoot outer-04-thread-dark thread dark 6 1 outer
  shoot outer-05-plus plus light 7 1 outer
  shoot outer-07-menu focus light 8 1 outer
  shoot outer-08-details info light 7 1 outer
  shoot outer-10-moments moments light 7 1 outer
  shoot outer-11-memories memories light 7 1 outer
  shoot outer-12-friends friends light 7 1 outer
  shoot outer-13-you me light 7 1 outer
  shoot outer-15-settings settings light 7 1 outer
  shoot outer-16-note note light 7 1 outer
  shoot outer-18-group group light 6 1 outer
  shoot outer-19-filters filters light 7 1 outer
  shoot outer-20-profile profile light 7 1 outer
  shoot outer-21-editprofile editprofile light 7 1 outer
  # The inner display (open).
  shoot inner-01-list list light 12 1 inner
  shoot inner-02-thread thread light 6 1 inner
  shoot inner-02-thread-dark thread dark 6 1 inner
  shoot inner-03-details info light 7 1 inner
  shoot inner-04-draw draw light 14 1 inner
  shoot inner-10-moments moments light 7 1 inner
  shoot inner-14-menu sidebar light 6 1 inner
  shoot inner-15-settings settings light 7 1 inner
fi

# Crash reports, if any, go with the screenshots.
mkdir -p "$OUT/crashes"
cp ~/Library/Logs/DiagnosticReports/Cuven* "$OUT/crashes/" 2>/dev/null || true
ls -la "$OUT"
