#!/usr/bin/env bash
# Runs the Simulator build against the seeded local hub and photographs each
# screen (an iPhone for one column, an iPad for two). Output: ios/screens/*.png
set -uo pipefail
APP=ios/build/sim/Build/Products/Debug-iphonesimulator/Cuven.app
OUT=ios/screens
mkdir -p "$OUT"

pick() { xcrun simctl list devices available -j | jq -r --arg p "$1" '[.devices[][] | select(.name | test($p))][0].udid // empty'; }
PHONE=$(pick "iPhone.*Pro Max")
[ -z "$PHONE" ] && PHONE=$(pick "iPhone")
PAD=$(pick "iPad Pro")
[ -z "$PAD" ] && PAD=$(pick "iPad")
echo "phone=$PHONE pad=$PAD"

for U in $PHONE $PAD; do
  xcrun simctl boot "$U" 2>/dev/null || true
  xcrun simctl bootstatus "$U" -b >/dev/null
  xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
  xcrun simctl install "$U" "$APP"
done

shoot() { # udid name screen [appearance] [wait] [signin]
  local U=$1 N=$2 S=$3 L=${4:-light} W=${5:-6} SIGN=${6:-1}
  xcrun simctl terminate "$U" us.cuven.app 2>/dev/null || true
  if [ "$SIGN" = 1 ]; then
    SIMCTL_CHILD_CUVEN_SERVER=http://localhost:8787 SIMCTL_CHILD_CUVEN_USER=alice SIMCTL_CHILD_CUVEN_PASS=cuven-demo \
    SIMCTL_CHILD_CUVEN_SCREEN="$S" SIMCTL_CHILD_CUVEN_APPEARANCE="$L" xcrun simctl launch "$U" us.cuven.app >/dev/null
  else
    SIMCTL_CHILD_CUVEN_SERVER=http://localhost:8787 SIMCTL_CHILD_CUVEN_SCREEN="$S" SIMCTL_CHILD_CUVEN_APPEARANCE="$L" \
      xcrun simctl launch "$U" us.cuven.app >/dev/null
  fi
  sleep "$W"
  xcrun simctl io "$U" screenshot "$OUT/$N.png" >/dev/null 2>&1 && echo "shot $N"
}

shoot "$PHONE" 01-phone-auth auth light 5 0
shoot "$PHONE" 02-phone-list list light 10
shoot "$PHONE" 03-phone-thread thread
shoot "$PHONE" 04-phone-focus focus light 8
shoot "$PHONE" 05-phone-plus plus light 7
shoot "$PHONE" 06-phone-info info light 7
shoot "$PHONE" 07-phone-sidebar sidebar
shoot "$PHONE" 08-phone-moments moments light 7
shoot "$PHONE" 09-phone-me me light 7
shoot "$PHONE" 10-phone-requests requests
shoot "$PHONE" 11-phone-group group
shoot "$PHONE" 12-phone-draw draw light 7
shoot "$PHONE" 13-phone-thread-dark thread dark
shoot "$PHONE" 14-phone-list-dark list dark
shoot "$PHONE" 15-phone-settings settings light 7
shoot "$PHONE" 16-phone-newchat newchat light 7

shoot "$PAD" 21-pad-list list light 10
shoot "$PAD" 22-pad-thread thread
shoot "$PAD" 23-pad-info info light 7
shoot "$PAD" 24-pad-sidebar sidebar
shoot "$PAD" 25-pad-moments moments light 7
shoot "$PAD" 26-pad-thread-dark thread dark

# Crash reports, if any, go with the screenshots.
mkdir -p "$OUT/crashes"
cp ~/Library/Logs/DiagnosticReports/Cuven* "$OUT/crashes/" 2>/dev/null || true
ls -la "$OUT"
