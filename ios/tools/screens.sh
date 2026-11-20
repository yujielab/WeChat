#!/usr/bin/env bash
# Runs the Simulator build against the seeded local hub and photographs each
# screen on one device. Usage: screens.sh <udid> phone|pad   Output: ios/screens/*.png
set -uo pipefail
U=$1
KIND=$2
APP=ios/build/sim/Build/Products/Debug-iphonesimulator/Cuven.app
OUT=ios/screens
mkdir -p "$OUT"

# Nothing here may hang the job: every simulator call has a time limit.
t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

# The device was booted at the start of the job; wait until it's ready.
t 900 xcrun simctl bootstatus "$U" -b >/dev/null || echo "boot wait timed out"
t 30 xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
t 300 xcrun simctl install "$U" "$APP" || { echo "install failed"; exit 1; }

shoot() { # name screen [appearance] [wait] [signin]
  local N=$1 S=$2 L=${3:-light} W=${4:-6} SIGN=${5:-1}
  t 30 xcrun simctl terminate "$U" us.cuven.app 2>/dev/null || true
  local envs=(SIMCTL_CHILD_CUVEN_SERVER=http://localhost:8787 SIMCTL_CHILD_CUVEN_SCREEN="$S" SIMCTL_CHILD_CUVEN_APPEARANCE="$L")
  [ "$SIGN" = 1 ] && envs+=(SIMCTL_CHILD_CUVEN_USER=alice SIMCTL_CHILD_CUVEN_PASS=cuven-demo)
  if ! env "${envs[@]}" perl -e 'alarm shift; exec @ARGV' 180 xcrun simctl launch "$U" us.cuven.app >/dev/null; then
    echo "launch failed for $N"
    return
  fi
  sleep "$W"
  t 60 xcrun simctl io "$U" screenshot "$OUT/$KIND-$N.png" >/dev/null 2>&1 && echo "shot $KIND-$N" || echo "no shot $KIND-$N"
}

if [ "$KIND" = phone ]; then
  shoot 01-auth auth light 6 0
  shoot 02-list list light 12
  shoot 03-thread thread
  shoot 04-focus focus light 8
  shoot 05-plus plus light 7
  shoot 06-info info light 7
  shoot 07-sidebar sidebar
  shoot 08-moments moments light 7
  shoot 09-me me light 7
  shoot 10-requests requests
  shoot 11-group group
  shoot 12-draw draw light 7
  shoot 13-thread-dark thread dark
  shoot 14-list-dark list dark
  shoot 15-settings settings light 7
  shoot 16-newchat newchat light 7
else
  shoot 21-list list light 12
  shoot 22-thread thread
  shoot 23-info info light 7
  shoot 24-sidebar sidebar
  shoot 25-moments moments light 7
  shoot 26-thread-dark thread dark
fi

# Crash reports, if any, go with the screenshots.
mkdir -p "$OUT/crashes"
cp ~/Library/Logs/DiagnosticReports/Cuven* "$OUT/crashes/" 2>/dev/null || true
ls -la "$OUT"
