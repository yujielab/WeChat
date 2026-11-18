#!/usr/bin/env bash
# =============================================================================
# Cuven Native iOS & iPhone Duo (iOS 27.2 SDK) — Master E2E Verification Suite
# =============================================================================
# Target Toolchain & Runtime Baseline (User Override 2026-11-18T04:56:54Z):
#   - Xcode: /Applications/Xcode_27.2.app (Build 27B52)
#   - SDKs:  iphoneos27.2 / iphonesimulator27.2 (Mach-O LC_BUILD_VERSION `sdk 27.2`)
#   - Sim:   com.apple.CoreSimulator.SimRuntime.iOS-27-2 (`iPhone Duo` & `iPhone`)
#
# Executes all mandatory automated verification gates across:
#   (a) Cuven Web 1:1 Reference Oracle Unit Tests (`node --test ...`)
#   (b) Local `CuvenCore` Pure-Swift Package Tests (`swift test --package-path ios/Packages/CuvenCore`)
#   (c) `docs/ios-hig-27.2-reference.md` (with `docs/ios-hig-27.1-reference.md` sync check) &
#       Opaque-Box `CuvenUITests` Integrity Audit
#   (d) `dist/Cuven.ipa` + `dist/WeChat.ipa` Mach-O `sdk 27.2` & `ARM64` & Zero-`WebKit` Forensic
#       Audit (`ios/scripts/verify-ipa-linux.py` + `llvm-objdump`) + Dual-Simulator (`iPhone Duo`
#       & standard `iPhone` on `SimRuntime.iOS-27-2`) `.xcresult` / PNG Screenshot Evidence Gate.
#
# Usage:
#   bash ios/scripts/run-e2e-suite.sh                     # Full mode (all 4 gates strictly enforced)
#   bash ios/scripts/run-e2e-suite.sh --local-precheck    # Pre-CI mode before dist/*.ipa is downloaded
#   bash ios/scripts/run-e2e-suite.sh --ipa-dir dist --sim-evidence-dir dist/sim-evidence
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOCAL_PRECHECK=0
IPA_DIR="${CUVEN_IPA_DIR:-$REPO_ROOT/dist}"
SIM_EVIDENCE_DIR="${CUVEN_SIM_EVIDENCE_DIR:-}"

usage() {
  cat <<'EOF'
Usage: ios/scripts/run-e2e-suite.sh [OPTIONS]

Options:
  --local-precheck          Run Stages (a)-(c) + Opaque-Box XCUITest audit locally before CI downloads dist/*.ipa
  --full                    Run all Stages (a)-(d) strictly enforcing iOS 27.2 SDK (`sdk 27.2`) (default)
  --ipa-dir <dir>           Directory containing Cuven.ipa and WeChat.ipa (default: ./dist)
  --sim-evidence-dir <dir>  Directory containing CI Simulator .xcresult / logs & PNG screenshots
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-precheck)
      LOCAL_PRECHECK=1
      shift
      ;;
    --full)
      LOCAL_PRECHECK=0
      shift
      ;;
    --ipa-dir)
      IPA_DIR="$2"
      shift 2
      ;;
    --sim-evidence-dir)
      SIM_EVIDENCE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Disk Hygiene: Never place temporary or scratch files in /tmp!
# -----------------------------------------------------------------------------
choose_scratch_root() {
  if [[ -n "${TMPDIR:-}" && "${TMPDIR}" != /tmp* ]]; then
    echo "${TMPDIR%/}/cuven_e2e_$$"
    return
  fi
  if [[ -d "/home/antigravity/.gemini/jetski" && -w "/home/antigravity/.gemini/jetski" ]]; then
    echo "/home/antigravity/.gemini/jetski/scratch/teamwork_tmp/cuven_e2e_$$"
    return
  fi
  echo "$REPO_ROOT/.cuven_e2e_scratch_$$"
}

E2E_SCRATCH="$(choose_scratch_root)"
mkdir -p "$E2E_SCRATCH"
cleanup_scratch() {
  rm -rf "$E2E_SCRATCH"
}
trap cleanup_scratch EXIT
export TMPDIR="$E2E_SCRATCH"

PASS_STAGES=0
TOTAL_STAGES=4

banner() {
  echo ""
  echo "============================================================================="
  echo "$1"
  echo "============================================================================="
}

# =============================================================================
# Stage (a): Cuven Web Reference Baseline Unit Tests (1:1 Parity Oracle)
# =============================================================================
banner "[Stage 1/4] Cuven Web Reference Baseline Unit Tests (Node Test Runner)"
(
  cd "$REPO_ROOT"
  node --test \
    test/columns.test.js \
    test/posture.test.js \
    test/viewport-boot.test.js \
    test/store.test.js \
    test/auth.test.js \
    test/outbox.test.js
)
echo "[PASS] Stage 1/4 — Cuven Web baseline unit tests passed."
PASS_STAGES=$((PASS_STAGES + 1))

# =============================================================================
# Stage (b): Local CuvenCore Pure-Swift Package Tests (Swift 6)
# =============================================================================
banner "[Stage 2/4] CuvenCore Pure-Swift Package Tests (Swift 6)"
if [[ -x "/home/antigravity/.local/swift/usr/bin/swift" ]]; then
  SWIFT_BIN="/home/antigravity/.local/swift/usr/bin/swift"
elif command -v swift >/dev/null 2>&1; then
  SWIFT_BIN="$(command -v swift)"
else
  echo "[FAIL] Stage 2/4 — Swift toolchain not found (/home/antigravity/.local/swift/usr/bin/swift or PATH)." >&2
  exit 1
fi

echo "Using Swift toolchain: $("$SWIFT_BIN" --version | head -n 1)"
SWIFTPM_ARGS=(--package-path "$REPO_ROOT/ios/Packages/CuvenCore")
if [[ -f "$REPO_ROOT/ios/Packages/CuvenCore/.build/.lock" ]]; then
  echo "[INFO] Detected active lock on ios/Packages/CuvenCore/.build; using isolated scratch path."
  SWIFTPM_ARGS+=(--scratch-path "$E2E_SCRATCH/swiftpm")
fi

if [[ -d "$REPO_ROOT/ios/Packages/CuvenCore/Tests" ]]; then
  "$SWIFT_BIN" test "${SWIFTPM_ARGS[@]}"
  echo "[PASS] Stage 2/4 — CuvenCore Swift package tests passed."
elif [[ "$LOCAL_PRECHECK" -eq 1 ]]; then
  echo "[INFO] ios/Packages/CuvenCore/Tests not yet populated; verifying CuvenCore target build in --local-precheck mode..."
  "$SWIFT_BIN" build "${SWIFTPM_ARGS[@]}" --target CuvenCore
  echo "[PASS] Stage 2/4 — CuvenCore library target compiled cleanly (--local-precheck)."
else
  echo "[FAIL] Stage 2/4 — Missing ios/Packages/CuvenCore/Tests in full verification mode!" >&2
  exit 1
fi
PASS_STAGES=$((PASS_STAGES + 1))

# =============================================================================
# Stage (c): Apple HIG & iOS 27.2 SDK Reference + Opaque-Box CuvenUITests Audit
# =============================================================================
banner "[Stage 3/4] Apple HIG & iOS 27.2 SDK Reference + Opaque-Box CuvenUITests Audit"
python3 - "$REPO_ROOT" "$LOCAL_PRECHECK" <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
local_precheck = int(sys.argv[2]) == 1

# 1. Verify docs/ios-hig-27.2-reference.md (primary) + docs/ios-hig-27.1-reference.md (fallback/sync)
hig_272 = repo / "docs" / "ios-hig-27.2-reference.md"
hig_271 = repo / "docs" / "ios-hig-27.1-reference.md"

common_hig_anchors = [
    ("Designing for iPhone Duo", r"Designing for iPhone Duo"),
    ("Preparing your app for iPhone Duo", r"Preparing your app for iPhone Duo"),
    ("UIRequiresFullScreen", r"UIRequiresFullScreen"),
    ("ReservedRegion", r"ReservedRegion"),
    ("onHingeChange", r"onHingeChange"),
    ("ArrangementView", r"ArrangementView"),
    ("toolbarVerticalEdge", r"toolbarVerticalEdge"),
    ("Liquid Glass (glassEffect)", r"glassEffect"),
    ("Clarinetta Typography", r"Clarinetta"),
    ("Dynamic Type", r"Dynamic Type"),
    ("Zero-Reflow 525pt Thread Mandate", r"525"),
]

sdk_272_anchors = [
    ("iOS 27.2 SDK (sdk 27.2)", r"sdk 27\.2|27\.2 SDK|iOS 27\.2"),
    ("iphoneos27.2 / Xcode_27.2", r"iphoneos27\.2|Xcode_27\.2"),
]

if hig_272.is_file():
    hig_text = hig_272.read_text(encoding="utf-8")
    if len(hig_text) < 8000:
        raise SystemExit(f"[FAIL] {hig_272} is unexpectedly short ({len(hig_text)} chars)")
    missing = [
        name for name, pat in (common_hig_anchors + sdk_272_anchors)
        if not re.search(pat, hig_text, re.IGNORECASE)
    ]
    if missing:
        raise SystemExit(f"[FAIL] docs/ios-hig-27.2-reference.md missing required anchors: {missing}")
    print(f"[OK] docs/ios-hig-27.2-reference.md verified ({len(hig_text)} chars, iOS 27.2 SDK + HIG anchors present).")
    if hig_271.is_file():
        legacy_txt = hig_271.read_text(encoding="utf-8")
        if "27.2" not in legacy_txt and not local_precheck:
            raise SystemExit("[FAIL] docs/ios-hig-27.1-reference.md exists but has not been synced to mention iOS 27.2 SDK!")
elif local_precheck and hig_271.is_file():
    hig_text = hig_271.read_text(encoding="utf-8")
    if len(hig_text) < 8000:
        raise SystemExit(f"[FAIL] {hig_271} is unexpectedly short ({len(hig_text)} chars)")
    missing = [name for name, pat in common_hig_anchors if not re.search(pat, hig_text, re.IGNORECASE)]
    if missing:
        raise SystemExit(f"[FAIL] Fallback {hig_271.name} missing required HIG anchors: {missing}")
    print(
        f"[INFO-PRECHECK] docs/ios-hig-27.2-reference.md still being finalized by M1; "
        f"verified {hig_271.name} ({len(hig_text)} chars). Full mode strictly requires docs/ios-hig-27.2-reference.md."
    )
else:
    raise SystemExit(
        f"[FAIL] Missing authoritative iOS 27.2 SDK HIG reference doc: expected {hig_272} "
        f"(Xcode_27.2.app / iphoneos27.2 / iphonesimulator27.2 / SimRuntime.iOS-27-2)."
    )

# 2. Verify Opaque-Box XCUITest Suite (ios/CuvenUITests/*.swift)
uitests_dir = repo / "ios" / "CuvenUITests"
expected_files = {
    "UITestHelpers.swift": 0,
    "CuvenTier1FeatureUITests.swift": 42,
    "CuvenTier2BoundaryUITests.swift": 40,
    "CuvenTier3CrossFeatureDuoUITests.swift": 12,
    "CuvenTier4RealWorldScenariosUITests.swift": 5,
}

total_tests = 0
counts = {}

for filename, min_required in expected_files.items():
    fpath = uitests_dir / filename
    if not fpath.is_file():
        raise SystemExit(f"[FAIL] Missing required XCUITest file: {fpath}")
    src = fpath.read_text(encoding="utf-8")

    # Enforce 100% Opaque-Box isolation & iOS 27.2 SDK alignment
    if re.search(r"@testable\s+import", src):
        raise SystemExit(f"[FAIL] Forbidden @testable import found in opaque-box UI test file {filename}")
    if re.search(r"^\s*import\s+(Cuven|CuvenCore)\b", src, re.MULTILINE):
        raise SystemExit(f"[FAIL] Forbidden internal module import found in opaque-box UI test file {filename}")
    if "XCUIDevice.shared.orientation" in src:
        raise SystemExit(
            f"[FAIL] Forbidden XCUIDevice.shared.orientation found in {filename} "
            f"(no-op on iOS 27.2 iPhone Duo Simulator; use --uitest-posture / shell.postureSwitcher)"
        )
    if re.search(r"\b27\.1\b", src):
        raise SystemExit(f"[FAIL] Stale 27.1 SDK reference found in {filename}; must target iOS 27.2 SDK!")

    test_funcs = re.findall(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(", src)
    counts[filename] = len(test_funcs)
    total_tests += len(test_funcs)
    if len(test_funcs) < min_required:
        raise SystemExit(
            f"[FAIL] {filename} has {len(test_funcs)} tests, below TEST_INFRA.md minimum of {min_required}"
        )

# Verify XCUIApplication.cuvenElement(_:) SwiftUI-resilient lookup in UITestHelpers.swift
helpers_src = (uitests_dir / "UITestHelpers.swift").read_text(encoding="utf-8")
if "func cuvenElement(" not in helpers_src or "descendants(matching: .any).matching(identifier:" not in helpers_src:
    raise SystemExit(
        "[FAIL] UITestHelpers.swift must define XCUIApplication.cuvenElement(_:) using descendants(matching: .any).matching(identifier:)"
    )

# Verify Tier 1 per-feature minimum (>= 5 per F1..F8) + XCTAttachment screenshot harvesting
tier1_src = (uitests_dir / "CuvenTier1FeatureUITests.swift").read_text(encoding="utf-8")
for fg in range(1, 9):
    fg_matches = re.findall(rf"\bfunc\s+testF{fg}_[A-Za-z0-9_]+\s*\(", tier1_src)
    if len(fg_matches) < 5:
        raise SystemExit(f"[FAIL] Tier 1 feature group F{fg} has {len(fg_matches)} tests (expected >= 5)")
if "attachScreenshot(" not in tier1_src:
    raise SystemExit("[FAIL] CuvenTier1FeatureUITests.swift must capture XCTAttachment Simulator screenshots")

if total_tests < 99:
    raise SystemExit(f"[FAIL] Total XCUITest count is {total_tests}, below TEST_INFRA.md minimum of 99")

print(
    f"[OK] Opaque-Box CuvenUITests (iOS 27.2 SDK) verified: total={total_tests} tests (>=99) | "
    f"Tier1={counts['CuvenTier1FeatureUITests.swift']} (>=42) | "
    f"Tier2={counts['CuvenTier2BoundaryUITests.swift']} (>=40) | "
    f"Tier3={counts['CuvenTier3CrossFeatureDuoUITests.swift']} (>=12) | "
    f"Tier4={counts['CuvenTier4RealWorldScenariosUITests.swift']} (>=5) | "
    f"zero @testable imports | zero XCUIDevice.orientation."
)
PY
echo "[PASS] Stage 3/4 — Apple HIG & iOS 27.2 SDK reference + Opaque-Box XCUITest audit passed."
PASS_STAGES=$((PASS_STAGES + 1))

# =============================================================================
# Stage (d): Binary .ipa (`sdk 27.2` + `ARM64` + Zero-`WebKit`) & Simulator Evidence
# =============================================================================
banner "[Stage 4/4] Binary .ipa (sdk 27.2 + ARM64 + Zero-WebKit) & Dual-Simulator Evidence"

CUVEN_IPA="$IPA_DIR/Cuven.ipa"
WECHAT_IPA="$IPA_DIR/WeChat.ipa"

if [[ ! -f "$CUVEN_IPA" || ! -f "$WECHAT_IPA" ]]; then
  if [[ "$LOCAL_PRECHECK" -eq 1 ]]; then
    echo "[SKIP-PRECHECK] $CUVEN_IPA / $WECHAT_IPA not yet downloaded from xcode-27 (Xcode_27.2.app / iphoneos27.2) CI."
    echo "                Re-run without --local-precheck after downloading CI artifacts into $IPA_DIR."
    echo ""
    echo "[SUMMARY] PRECHECK PASSED ($PASS_STAGES/$TOTAL_STAGES local stages passed; Stage 4 pending CI iOS 27.2 SDK .ipa download)."
    exit 0
  else
    echo "[FAIL] Stage 4/4 — Missing required .ipa artifacts: expected both '$CUVEN_IPA' and '$WECHAT_IPA'!" >&2
    exit 1
  fi
fi

# 4.1 Run primary forensic .ipa verifier (`ios/scripts/verify-ipa-linux.py`)
python3 "$REPO_ROOT/ios/scripts/verify-ipa-linux.py" \
  "$CUVEN_IPA" \
  "$WECHAT_IPA" \
  --json-out "$E2E_SCRATCH/ipa-verification.json"

# 4.2 Direct Mach-O `LC_BUILD_VERSION` `sdk 27.2` + `ARM64` + ZERO `WebKit.framework` Gate
python3 - "$CUVEN_IPA" "$WECHAT_IPA" "$E2E_SCRATCH" <<'PY'
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

objdump = shutil.which("llvm-objdump")
if not objdump:
    raise SystemExit("[FAIL] llvm-objdump not found in PATH for Mach-O sdk 27.2 & zero-WebKit audit")

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2


def decode_ver(raw: int) -> str:
    major = (raw >> 16) & 0xFFFF
    minor = (raw >> 8) & 0xFF
    patch = raw & 0xFF
    return f"{major}.{minor}" if patch == 0 else f"{major}.{minor}.{patch}"


scratch = Path(sys.argv[3])
for raw_ipa in sys.argv[1:3]:
    ipa = Path(raw_ipa)
    with zipfile.ZipFile(ipa, "r") as zf:
        info_entry = [n for n in zf.namelist() if re.match(r"^Payload/[^/]+\.app/Info\.plist$", n)][0]
        app_prefix = info_entry[: -len("Info.plist")]
        pl = plistlib.loads(zf.read(info_entry))
        exe_name = pl["CFBundleExecutable"]
        exe_bytes = zf.read(f"{app_prefix}{exe_name}")

    # Direct struct verification of MH_MAGIC_64, ARM64, and LC_BUILD_VERSION sdk == 27.2
    magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IIIIIIII", exe_bytes, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        raise SystemExit(f"[FAIL] {ipa}: Expected 64-bit ARM64 Mach-O (got magic={hex(magic)}, cpu={hex(cputype)})")

    offset = 32
    struct_sdk = None
    struct_platform = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", exe_bytes, offset)
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk, _ = struct.unpack_from("<IIII", exe_bytes, offset + 8)
            struct_platform = platform
            struct_sdk = decode_ver(sdk)
            break
        offset += cmdsize

    if struct_platform != PLATFORM_IOS:
        raise SystemExit(f"[FAIL] {ipa}: Expected LC_BUILD_VERSION platform=ios (2), got {struct_platform}")
    if struct_sdk not in ("27.2", "27.2.0"):
        raise SystemExit(
            f"[FAIL] {ipa}: Strict iOS 27.2 SDK check failed in Mach-O struct: got sdk={struct_sdk!r}, expected '27.2'"
        )

    bin_out = scratch / f"audit_{ipa.stem}_{exe_name}"
    bin_out.write_bytes(exe_bytes)
    try:
        headers_txt = subprocess.check_output(
            [objdump, "--macho", "--private-headers", str(bin_out)],
            text=True,
        )
        dylibs_txt = subprocess.check_output(
            [objdump, "--macho", "--dylibs-used", str(bin_out)],
            text=True,
        )
    finally:
        bin_out.unlink(missing_ok=True)

    m_sdk = re.search(r"cmd\s+LC_BUILD_VERSION[\s\S]*?\bsdk\s+([0-9.]+)", headers_txt)
    objdump_sdk = m_sdk.group(1) if m_sdk else None
    if objdump_sdk not in ("27.2", "27.2.0"):
        raise SystemExit(
            f"[FAIL] {ipa}: llvm-objdump LC_BUILD_VERSION sdk mismatch: got {objdump_sdk!r}, expected '27.2'"
        )
    if "WebKit.framework" in dylibs_txt:
        raise SystemExit(f"[FAIL] {ipa}: Forbidden WebKit.framework linkage detected in Mach-O binary!")

    print(
        f"[PASS] {ipa} — ARM64 Mach-O LC_BUILD_VERSION sdk={objdump_sdk} (iphoneos27.2) + "
        f"zero WebKit.framework linkage confirmed."
    )
PY

# 4.3 Verify Dual-Simulator (.xcresult / logs + iPhone Duo & standard iPhone PNG screenshots on SimRuntime.iOS-27-2)
if [[ -z "$SIM_EVIDENCE_DIR" ]]; then
  for candidate in \
    "$REPO_ROOT/dist/sim-evidence" \
    "$REPO_ROOT/dist/Cuven-sim-evidence" \
    "$REPO_ROOT/artifacts/sim-evidence" \
    "$REPO_ROOT/dist"
  do
    if [[ -d "$candidate" ]] && compgen -G "$candidate/*iphone*" >/dev/null 2>&1; then
      SIM_EVIDENCE_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$SIM_EVIDENCE_DIR" || ! -d "$SIM_EVIDENCE_DIR" ]]; then
  if [[ "$LOCAL_PRECHECK" -eq 1 ]]; then
    echo "[SKIP-PRECHECK] CI Simulator evidence directory (SimRuntime.iOS-27-2) not yet downloaded."
    exit 0
  fi
  echo "[FAIL] Stage 4/4 — Missing CI Dual-Simulator evidence directory (pass --sim-evidence-dir <dir> or place Cuven-sim-evidence in dist/sim-evidence)!" >&2
  exit 1
fi

python3 - "$SIM_EVIDENCE_DIR" <<'PY'
import struct
import sys
from pathlib import Path

ev_dir = Path(sys.argv[1])
all_files = list(ev_dir.rglob("*"))


def verify_png(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if len(data) < 1024:
        raise SystemExit(f"[FAIL] Screenshot PNG too small (<1KB): {path} ({len(data)} bytes)")
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"[FAIL] Invalid PNG header in screenshot: {path}")
    width, height = struct.unpack(">II", data[16:24])
    if width <= 0 or height <= 0:
        raise SystemExit(f"[FAIL] Invalid PNG dimensions ({width}x{height}) in {path}")
    return width, height, len(data)


pngs = [p for p in all_files if p.is_file() and p.suffix.lower() == ".png"]
duo_pngs = [p for p in pngs if "duo" in p.name.lower()]
std_pngs = [p for p in pngs if "iphone" in p.name.lower() and "duo" not in p.name.lower()]

if not duo_pngs:
    raise SystemExit(f"[FAIL] No iPhone Duo Simulator PNG screenshots found in {ev_dir}")
if not std_pngs:
    raise SystemExit(f"[FAIL] No standard iPhone Simulator PNG screenshots found in {ev_dir}")

for p in duo_pngs + std_pngs:
    w, h, sz = verify_png(p)
    print(f"[OK] Verified Simulator PNG: {p.name} ({w}x{h}px, {sz} bytes)")

xcresults = [p for p in all_files if p.is_dir() and p.suffix == ".xcresult"]
test_logs = [p for p in all_files if p.is_file() and p.name.startswith("test-iphone") and p.suffix == ".log"]

if not xcresults and not test_logs:
    raise SystemExit(f"[FAIL] Expected .xcresult bundles or test-iphone*.log evidence in {ev_dir}")

for log_file in test_logs:
    txt = log_file.read_text(encoding="utf-8", errors="replace")
    if "** TEST FAILED **" in txt:
        raise SystemExit(f"[FAIL] Simulator test failure recorded in {log_file}")
    if "** TEST SUCCEEDED **" not in txt:
        raise SystemExit(f"[FAIL] Simulator log {log_file} did not record '** TEST SUCCEEDED **'")
    print(f"[OK] Verified Simulator test log: {log_file.name} (** TEST SUCCEEDED **)")

for xcr in xcresults:
    info_plist = xcr / "Info.plist"
    if not info_plist.is_file():
        raise SystemExit(f"[FAIL] Incomplete .xcresult bundle (missing Info.plist): {xcr}")
    print(f"[OK] Verified Simulator .xcresult bundle: {xcr.name}")
PY

PASS_STAGES=$((PASS_STAGES + 1))
banner "[PASS] ALL $PASS_STAGES/$TOTAL_STAGES CUVEN E2E VERIFICATION GATES PASSED (iOS 27.2 SDK)"
