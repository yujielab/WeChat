#!/usr/bin/env bash
# Build, ad-hoc sign, package, and verify genuine ARM64 Cuven.ipa (+ WeChat.ipa alias)
# strictly against Xcode 27.2 (/Applications/Xcode_27.2.app) and iphoneos27.2 SDK.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"

if [ -z "${XCODE_APP:-}" ]; then
  if [ -d "/Applications/Xcode_27.2.app" ]; then
    XCODE_APP="/Applications/Xcode_27.2.app"
  else
    XCODE_APP="$(ls -d /Applications/Xcode_27.2*.app 2>/dev/null | head -n 1 || echo "/Applications/Xcode_27.2.app")"
  fi
fi
TARGET_SDK="${TARGET_SDK:-iphoneos27.2}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-Cuven}"

WORK_ROOT="${RUNNER_TEMP:-${TMPDIR:-$REPO_ROOT/artifacts/build-work}}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$WORK_ROOT/dd-device}"
STAGE_DIR="${STAGE_DIR:-$WORK_ROOT/ipa-stage}"
VERIFY_UNPACK_DIR="${VERIFY_UNPACK_DIR:-$WORK_ROOT/ipa-verify}"
OUT_DIR="${1:-${OUT_DIR:-$REPO_ROOT/dist}}"

echo "=== [1/6] Selecting & Verifying Xcode 27.2 (${TARGET_SDK}) ==="
if [ ! -d "$XCODE_APP" ]; then
  echo "ERROR: Required Xcode 27.2 installation not found at $XCODE_APP" >&2
  ls -d /Applications/Xcode*.app 2>/dev/null || true
  exit 1
fi

export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
xcodebuild -version

IPHONEOS_DEFAULT_SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
IPHONESSIM_DEFAULT_SDK_VER="$(xcrun --sdk iphonesimulator --show-sdk-version)"
RESOLVED_SDK_VERSION="$(xcrun --sdk "$TARGET_SDK" --show-sdk-version)"
echo "Resolved SDK versions — iphoneos: $IPHONEOS_DEFAULT_SDK_VER, iphonesimulator: $IPHONESSIM_DEFAULT_SDK_VER, $TARGET_SDK: $RESOLVED_SDK_VERSION"
if [ "$IPHONEOS_DEFAULT_SDK_VER" != "27.2" ] || [ "$IPHONESSIM_DEFAULT_SDK_VER" != "27.2" ] || [ "$RESOLVED_SDK_VERSION" != "27.2" ]; then
  echo "ERROR: Expected SDK 27.2 (got iphoneos='$IPHONEOS_DEFAULT_SDK_VER', iphonesimulator='$IPHONESSIM_DEFAULT_SDK_VER', $TARGET_SDK='$RESOLVED_SDK_VERSION')" >&2
  exit 1
fi

echo "=== [2/6] Ensuring Cuven.xcodeproj via XcodeGen ==="
mkdir -p "$WORK_ROOT" "$OUT_DIR"
if [ ! -d "$IOS_DIR/Cuven.xcodeproj" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$IOS_DIR" && xcodegen generate)
  elif [ -n "${XCODEGEN_BIN:-}" ] && [ -x "${XCODEGEN_BIN}" ]; then
    (cd "$IOS_DIR" && "$XCODEGEN_BIN" generate)
  else
    XCODEGEN_ZIP="$WORK_ROOT/xcodegen-2.47.0.zip"
    XCODEGEN_DIR="$WORK_ROOT/xcodegen-2.47.0"
    curl -fsSL --retry 3 "https://github.com/yonaskolb/XcodeGen/releases/download/2.47.0/xcodegen.zip" -o "$XCODEGEN_ZIP"
    unzip -qo "$XCODEGEN_ZIP" -d "$XCODEGEN_DIR"
    (cd "$IOS_DIR" && "$XCODEGEN_DIR/xcodegen/bin/xcodegen" generate)
  fi
fi

echo "=== [3/6] Compiling Native ARM64 Cuven.app (-sdk ${TARGET_SDK}, minos ${DEPLOYMENT_TARGET}) ==="
BUILD_LOG="$OUT_DIR/xcodebuild-device.log"
BUILD_ARGS=(
  build
  -project "$IOS_DIR/Cuven.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk "$TARGET_SDK"
  -derivedDataPath "$DERIVED_DATA_DIR"
  "IPHONEOS_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  AD_HOC_CODE_SIGNING_ALLOWED=YES
)

if command -v xcbeautify >/dev/null 2>&1; then
  set +e
  xcodebuild "${BUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG" | xcbeautify
  BUILD_RC=${PIPESTATUS[0]}
  set -e
else
  set +e
  xcodebuild "${BUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
  BUILD_RC=${PIPESTATUS[0]}
  set -e
fi

if [ "$BUILD_RC" -ne 0 ]; then
  echo "ERROR: xcodebuild failed with exit code $BUILD_RC. Compiler errors from $BUILD_LOG:" >&2
  grep -E "(error:|fatal error:)" -C 3 "$BUILD_LOG" || tail -n 120 "$BUILD_LOG"
  exit "$BUILD_RC"
fi

APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-iphoneos/Cuven.app"
APP_BINARY="$APP_BUNDLE/Cuven"
if [ ! -f "$APP_BINARY" ]; then
  echo "ERROR: Expected compiled binary missing at $APP_BINARY" >&2
  exit 1
fi

echo "=== [4/6] Ad-Hoc CodeSigning Cuven.app & Embedded Frameworks ==="
if [ -d "$APP_BUNDLE/Frameworks" ]; then
  find "$APP_BUNDLE/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' fw; do
    /usr/bin/codesign --force --sign - --timestamp=none "$fw"
  done
fi
if [ -d "$APP_BUNDLE/PlugIns" ]; then
  find "$APP_BUNDLE/PlugIns" -name "*.appex" -print0 | while IFS= read -r -d '' appex; do
    /usr/bin/codesign --force --sign - --timestamp=none "$appex"
  done
fi
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "=== [5/6] Packaging Payload/Cuven.app -> Cuven.ipa & WeChat.ipa ==="
rm -rf "$STAGE_DIR" "$VERIFY_UNPACK_DIR"
mkdir -p "$STAGE_DIR/Payload" "$OUT_DIR"
ditto "$APP_BUNDLE" "$STAGE_DIR/Payload/Cuven.app"

rm -f "$OUT_DIR/Cuven.ipa" "$OUT_DIR/WeChat.ipa"
(cd "$STAGE_DIR" && zip -qry "$OUT_DIR/Cuven.ipa" Payload)
cp -f "$OUT_DIR/Cuven.ipa" "$OUT_DIR/WeChat.ipa"

echo "=== [6/6] Auditing Mach-O LC_BUILD_VERSION (sdk 27.2), ARM64, Native Linkage & Zero WebKit ==="
mkdir -p "$VERIFY_UNPACK_DIR"
unzip -q "$OUT_DIR/Cuven.ipa" -d "$VERIFY_UNPACK_DIR"
UNPACKED_APP="$VERIFY_UNPACK_DIR/Payload/Cuven.app"
UNPACKED_BIN="$UNPACKED_APP/Cuven"

# 1. Strict SDK 27.2 assertion via vtool & otool
VTOOL_OUT="$(vtool -show-build "$UNPACKED_BIN")"
echo "$VTOOL_OUT" | grep -Eq "platform IOS$"
echo "$VTOOL_OUT" | grep -Eq "sdk 27\.2$"

OTOOL_BUILD_OUT="$(otool -l "$UNPACKED_BIN" | grep -A 6 "LC_BUILD_VERSION")"
echo "$OTOOL_BUILD_OUT" | grep -Eq "^[[:space:]]*sdk 27\.2$"

# 2. Strict ARM64 Mach-O assertion
LIPO_ARCHS="$(lipo -archs "$UNPACKED_BIN")"
if [ "$LIPO_ARCHS" != "arm64" ]; then
  echo "ERROR: Expected arm64 binary, got '$LIPO_ARCHS'" >&2
  exit 1
fi

# 3. Native SwiftUI + UIKit linkage AND strict absence of WebKit assertion
OTOOL_LIBS="$(otool -L "$UNPACKED_BIN")"
echo "$OTOOL_LIBS" | grep -q "SwiftUI.framework/SwiftUI"
echo "$OTOOL_LIBS" | grep -q "UIKit.framework/UIKit"
if echo "$OTOOL_LIBS" | grep -qi "WebKit"; then
  echo "ERROR: Forbidden WebKit framework linkage detected in $UNPACKED_BIN! App must be 100% pure native." >&2
  echo "$OTOOL_LIBS" >&2
  exit 1
fi

# 4. Info.plist, Assets.car, Fonts, and CodeResources assertions
plutil -lint "$UNPACKED_APP/Info.plist"
test -s "$UNPACKED_APP/Assets.car"
test -s "$UNPACKED_APP/Clarinetta-Regular.ttf"
test -s "$UNPACKED_APP/Clarinetta-MediumItalic.ttf"
test -s "$UNPACKED_APP/_CodeSignature/CodeResources"

{
  echo "=== IPA ARTIFACT SIZES & SHA-256 ==="
  ls -lh "$OUT_DIR/Cuven.ipa" "$OUT_DIR/WeChat.ipa"
  (cd "$OUT_DIR" && shasum -a 256 Cuven.ipa WeChat.ipa) | tee "$OUT_DIR/SHA256SUMS.txt"
  echo ""
  echo "=== VTOOL -SHOW-BUILD (STRICT SDK 27.2 PROOF) ==="
  echo "$VTOOL_OUT"
  echo ""
  echo "=== OTOOL -L LC_BUILD_VERSION ==="
  echo "$OTOOL_BUILD_OUT"
  echo ""
  echo "=== MACH-O HEADER & ARCH ==="
  file "$UNPACKED_BIN"
  lipo -info "$UNPACKED_BIN"
  otool -hv "$UNPACKED_BIN"
  echo ""
  echo "=== LINKED FRAMEWORKS ==="
  echo "$OTOOL_LIBS"
  echo ""
  echo "=== CODESIGN & BUNDLE CONTENTS ==="
  codesign -dvvv "$UNPACKED_APP" 2>&1
  ls -lh "$UNPACKED_APP/Assets.car" "$UNPACKED_APP"/Clarinetta*.ttf
} | tee "$OUT_DIR/ipa-verification.txt"

rm -rf "$STAGE_DIR" "$VERIFY_UNPACK_DIR"
echo "SUCCESS: Genuine ARM64 iOS 27.2 SDK artifacts written to $OUT_DIR/Cuven.ipa and $OUT_DIR/WeChat.ipa"
