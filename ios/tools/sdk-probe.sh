#!/usr/bin/env bash
set -uo pipefail
XC=/Applications/Xcode_27.2.app
[ -d "$XC" ] || XC=$(ls -d /Applications/Xcode_27*.app | sort -V | tail -1)
sudo xcode-select -s "$XC"
mkdir -p probe
{ xcodebuild -version; xcrun --sdk iphoneos --show-sdk-version; xcrun --sdk iphoneos --show-sdk-path; sw_vers; } > probe/versions.txt 2>&1
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TERMS='Arrangement|ReservedRegion|VisibilityPriority|ToolbarOverflow|OverflowMenu|VerticalCompression|BarCompression|Posture|Hinge|[Ff]olding|FoldState|DisplaySegment|additionalOverflowItems'
for fw in SwiftUI SwiftUICore UIKit; do
  for f in $(find "$SDK/System/Library/Frameworks/$fw.framework" -name "*.swiftinterface" 2>/dev/null | grep -E "arm64e?-apple-ios.swiftinterface$" | head -1); do
    echo "== $f" > "probe/$fw-swiftinterface.txt"
    grep -nE -B3 -A12 "$TERMS" "$f" >> "probe/$fw-swiftinterface.txt" 2>/dev/null
    cp "$f" "probe/$fw.swiftinterface" 2>/dev/null || true
  done
done
grep -rnE -B2 -A8 "$TERMS" "$SDK/System/Library/Frameworks/UIKit.framework/Headers" > probe/UIKit-headers.txt 2>/dev/null || true
grep -rlE "$TERMS" "$SDK/System/Library/Frameworks/UIKit.framework/Headers" > probe/UIKit-header-files.txt 2>/dev/null || true
xcrun simctl help > probe/simctl-help.txt 2>&1
for c in io ui status_bar boot; do xcrun simctl help $c > "probe/simctl-help-$c.txt" 2>&1; done
xcrun simctl list devicetypes > probe/devicetypes.txt 2>&1
xcrun simctl list devices available > probe/devices.txt 2>&1
find "$XC" /Library/Developer/CoreSimulator -path "*DeviceTypes*" -iname "*Duo*" -maxdepth 12 2>/dev/null > probe/duo-paths.txt
while read -r d; do
  [ -f "$d/Contents/Resources/profile.plist" ] && plutil -p "$d/Contents/Resources/profile.plist" > "probe/duo-profile.txt" 2>&1
  [ -f "$d/Contents/Info.plist" ] && plutil -p "$d/Contents/Info.plist" > "probe/duo-info.txt" 2>&1
  ls -R "$d" > probe/duo-tree.txt 2>&1
done < probe/duo-paths.txt
# Boot the Duo and photograph its home screen (where the system column is).
DUO=$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name | test("Duo"))][0].udid // empty')
echo "duo=$DUO" >> probe/versions.txt
if [ -n "$DUO" ]; then
  perl -e 'alarm shift; exec @ARGV' 600 xcrun simctl bootstatus "$DUO" -b > probe/boot.txt 2>&1
  sleep 10
  xcrun simctl io "$DUO" screenshot probe/duo-home.png > /dev/null 2>&1
  xcrun simctl io "$DUO" enumerate > probe/duo-io-enumerate.txt 2>&1
  for disp in internal external; do xcrun simctl io "$DUO" screenshot --display=$disp "probe/duo-home-$disp.png" > /dev/null 2>&1; done
fi
ls -la probe
