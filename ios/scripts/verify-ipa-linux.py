#!/usr/bin/env python3
"""
Standalone Linux `.ipa` forensic verifier for Cuven (iOS 27.2 SDK).

Uses Python stdlib (`zipfile`, `plistlib`, `struct`) + `/usr/bin/llvm-objdump`
(`--macho --private-headers --dylibs-used`) to verify without macOS:
  1. Valid ZIP archive containing `Payload/<App>.app/`
  2. Mach-O 64-bit (`MH_MAGIC_64` = 0xFEEDFACF) ARM64 (`CPU_TYPE_ARM64` = 0x0100000C) executable
  3. `LC_BUILD_VERSION` strictly compiled with `platform ios` and `sdk 27.2`
     (verified via BOTH binary struct nibbles `0x001B0200` AND `llvm-objdump --macho --private-headers`)
  4. `LC_CODE_SIGNATURE` load command + valid `_CodeSignature/CodeResources` plist
  5. Native `SwiftUI.framework` and `UIKit.framework` linkage + ZERO `WebKit` dylib linkage (`--dylibs-used` & load commands)
  6. Compiled `Info.plist` (`UIRequiresFullScreen == False`, `UIApplicationSupportsMultipleScenes == True`,
     `UILaunchScreen` dict, all 4 orientations for iPhone & iPad/Duo, 13 `Clarinetta` fonts in `UIAppFonts`)
  7. Compiled `Assets.car` (`BOMStore` header, non-empty)
  8. All bundled `Clarinetta*.ttf` fonts present with valid SFNT headers (`OTTO` / TrueType)

Usage:
  python3 ios/scripts/verify-ipa-linux.py dist/Cuven.ipa [dist/WeChat.ipa ...]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
DYLIB_LOAD_CMDS = {0x0C, 0x80000018, 0x8000001F, 0x20}
PLATFORM_IOS = 2

EXPECTED_ORIENTATIONS = {
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
}

EXPECTED_FONTS = [
    "Clarinetta-Light.ttf",
    "Clarinetta-LightItalic.ttf",
    "Clarinetta-Regular.ttf",
    "Clarinetta-Medium.ttf",
    "Clarinetta-MediumItalic.ttf",
    "Clarinetta-Bold.ttf",
    "Clarinetta-BoldItalic.ttf",
    "Clarinetta-ExtraBold.ttf",
    "Clarinetta-ExtraBoldItalic.ttf",
    "Clarinetta-Black.ttf",
    "Clarinetta-BlackItalic.ttf",
    "Clarinetta-UltraItalic.ttf",
    "ClarinettaUnicase-Bold.ttf",
]


class VerificationError(RuntimeError):
    pass


def decode_macho_version(raw: int) -> str:
    major = (raw >> 16) & 0xFFFF
    minor = (raw >> 8) & 0xFF
    patch = raw & 0xFF
    return f"{major}.{minor}" if patch == 0 else f"{major}.{minor}.{patch}"


def inspect_macho_struct(data: bytes) -> Dict[str, Any]:
    if len(data) < 32:
        raise VerificationError(f"Executable too small to be Mach-O 64-bit ({len(data)} bytes)")

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _reserved = struct.unpack_from(
        "<IIIIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise VerificationError(f"Expected MH_MAGIC_64 (0xFEEDFACF), got 0x{magic:08X}")
    if cputype != CPU_TYPE_ARM64:
        raise VerificationError(f"Expected CPU_TYPE_ARM64 (0x0100000C), got 0x{cputype:08X}")

    offset = 32
    end_cmds = 32 + sizeofcmds
    if end_cmds > len(data):
        raise VerificationError("Truncated Mach-O load commands")

    build_version: Optional[Dict[str, Any]] = None
    has_code_sig = False
    loaded_dylibs: List[str] = []

    for _ in range(ncmds):
        if offset + 8 > end_cmds:
            raise VerificationError("Malformed Mach-O load command bounds")
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > end_cmds:
            raise VerificationError(f"Invalid Mach-O load command size {cmdsize} for cmd 0x{cmd:X}")

        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                raise VerificationError("Malformed LC_BUILD_VERSION command")
            platform, minos, sdk, ntools = struct.unpack_from("<IIII", data, offset + 8)
            build_version = {
                "platform_id": platform,
                "minos": decode_macho_version(minos),
                "sdk": decode_macho_version(sdk),
                "sdk_raw_hex": f"0x{sdk:08X}",
                "ntools": ntools,
            }
        elif cmd == LC_CODE_SIGNATURE:
            has_code_sig = True
        elif cmd in DYLIB_LOAD_CMDS and cmdsize >= 24:
            str_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if 8 <= str_offset < cmdsize:
                raw_name = data[offset + str_offset : offset + cmdsize].split(b"\x00", 1)[0]
                loaded_dylibs.append(raw_name.decode("utf-8", errors="replace"))

        offset += cmdsize

    if build_version is None:
        raise VerificationError("Missing LC_BUILD_VERSION load command in Mach-O binary")
    if build_version["platform_id"] != PLATFORM_IOS:
        raise VerificationError(
            f"Expected Mach-O PLATFORM_IOS ({PLATFORM_IOS}), got {build_version['platform_id']}"
        )
    if build_version["sdk"] not in ("27.2", "27.2.0"):
        raise VerificationError(
            f"Strict iOS 27.2 SDK check failed in binary struct: got sdk={build_version['sdk']!r} ({build_version['sdk_raw_hex']}), expected '27.2'"
        )
    if not has_code_sig:
        raise VerificationError("Missing LC_CODE_SIGNATURE load command in Mach-O binary")

    webkit_dylibs = [d for d in loaded_dylibs if "webkit" in d.lower()]
    if webkit_dylibs:
        raise VerificationError(
            f"Forbidden WebKit dylib linkage detected in Mach-O load commands (app must be 100% pure native): {webkit_dylibs}"
        )
    if not any("SwiftUI.framework/SwiftUI" in d for d in loaded_dylibs):
        raise VerificationError("Mach-O load commands missing native SwiftUI.framework/SwiftUI")
    if not any("UIKit.framework/UIKit" in d for d in loaded_dylibs):
        raise VerificationError("Mach-O load commands missing native UIKit.framework/UIKit")

    return {
        "magic": "MH_MAGIC_64",
        "cputype": "ARM64",
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "ncmds": ncmds,
        "flags": f"0x{flags:08X}",
        "build_version": build_version,
        "has_lc_code_signature": has_code_sig,
        "loaded_dylibs_count": len(loaded_dylibs),
        "zero_webkit_linkage": True,
    }


def inspect_with_llvm_objdump(bin_path: Path) -> Dict[str, Any]:
    objdump = shutil.which("llvm-objdump")
    if not objdump:
        raise VerificationError("llvm-objdump not found in PATH")

    priv = subprocess.run(
        [objdump, "--macho", "--private-headers", str(bin_path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    if "MH_MAGIC_64" not in priv:
        raise VerificationError("llvm-objdump --private-headers did not report MH_MAGIC_64")
    if "ARM64" not in priv:
        raise VerificationError("llvm-objdump --private-headers did not report ARM64")
    if "LC_CODE_SIGNATURE" not in priv:
        raise VerificationError("llvm-objdump --private-headers did not report LC_CODE_SIGNATURE")

    # Parse LC_BUILD_VERSION block from llvm-objdump output
    in_lc_build = False
    detected_platform: Optional[str] = None
    detected_sdk: Optional[str] = None
    detected_minos: Optional[str] = None

    for raw_line in priv.splitlines():
        line = raw_line.strip()
        if line.startswith("Load command "):
            in_lc_build = False
        elif line == "cmd LC_BUILD_VERSION":
            in_lc_build = True
        elif in_lc_build:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "platform":
                detected_platform = parts[1].lower()
            elif len(parts) >= 2 and parts[0] == "sdk":
                detected_sdk = parts[1]
            elif len(parts) >= 2 and parts[0] == "minos":
                detected_minos = parts[1]

    if detected_platform != "ios":
        raise VerificationError(
            f"llvm-objdump LC_BUILD_VERSION platform mismatch: expected 'ios', got {detected_platform!r}"
        )
    if detected_sdk not in ("27.2", "27.2.0"):
        raise VerificationError(
            f"llvm-objdump LC_BUILD_VERSION sdk mismatch: expected '27.2', got {detected_sdk!r}"
        )

    dylibs_out = subprocess.run(
        [objdump, "--macho", "--dylibs-used", str(bin_path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    dylibs = [
        ln.strip().split(" (compatibility")[0]
        for ln in dylibs_out.splitlines()
        if ln.startswith("\t") or "/System/Library/" in ln or "@rpath/" in ln
    ]
    joined_dylibs = "\n".join(dylibs)
    if "webkit" in joined_dylibs.lower():
        raise VerificationError(
            f"Forbidden WebKit dylib linkage detected via llvm-objdump --dylibs-used: {[d for d in dylibs if 'webkit' in d.lower()]}"
        )
    if "SwiftUI.framework/SwiftUI" not in joined_dylibs:
        raise VerificationError("Binary does not link native SwiftUI.framework/SwiftUI")
    if "UIKit.framework/UIKit" not in joined_dylibs:
        raise VerificationError("Binary does not link native UIKit.framework/UIKit")

    return {
        "llvm_objdump_platform": detected_platform,
        "llvm_objdump_sdk": detected_sdk,
        "llvm_objdump_minos": detected_minos,
        "linked_dylibs_count": len(dylibs),
        "links_swiftui": True,
        "links_uikit": True,
        "zero_webkit_linkage": True,
    }


def choose_scratch_parent(ipa_path: Path) -> Path:
    # Respect disk hygiene: never write to /tmp unless caller explicitly placed TMPDIR elsewhere
    env_tmp = os.environ.get("TMPDIR")
    if env_tmp and not env_tmp.startswith("/tmp"):
        p = Path(env_tmp)
        p.mkdir(parents=True, exist_ok=True)
        return p
    return ipa_path.resolve().parent


def verify_single_ipa(ipa_path: Path) -> Dict[str, Any]:
    if not ipa_path.is_file():
        raise VerificationError(f"IPA file does not exist: {ipa_path}")
    if not zipfile.is_zipfile(ipa_path):
        raise VerificationError(f"File is not a valid ZIP/.ipa archive: {ipa_path}")

    ipa_sha256 = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    ipa_size = ipa_path.stat().st_size

    with zipfile.ZipFile(ipa_path, "r") as zf:
        names = set(zf.namelist())
        info_candidates = [
            n for n in names if re.match(r"^Payload/[^/]+\.app/Info\.plist$", n)
        ]
        if len(info_candidates) != 1:
            raise VerificationError(
                f"Expected exactly one Payload/<App>.app/Info.plist inside {ipa_path}, found: {info_candidates}"
            )

        info_entry = info_candidates[0]
        app_prefix = info_entry[: -len("Info.plist")]  # e.g., "Payload/Cuven.app/"

        # 1. Verify Info.plist
        info_bytes = zf.read(info_entry)
        try:
            pl = plistlib.loads(info_bytes)
        except Exception as exc:
            raise VerificationError(f"Malformed Info.plist in {ipa_path}: {exc}") from exc

        executable_name = pl.get("CFBundleExecutable")
        bundle_id = pl.get("CFBundleIdentifier")
        display_name = pl.get("CFBundleDisplayName")
        requires_fullscreen = pl.get("UIRequiresFullScreen")
        scene_manifest = pl.get("UIApplicationSceneManifest")
        launch_screen = pl.get("UILaunchScreen")
        orientations_iphone = set(pl.get("UISupportedInterfaceOrientations") or [])
        orientations_ipad = set(pl.get("UISupportedInterfaceOrientations~ipad") or [])
        app_fonts = list(pl.get("UIAppFonts") or [])

        if not executable_name or not isinstance(executable_name, str):
            raise VerificationError(f"Missing CFBundleExecutable in Info.plist: {executable_name!r}")
        if not bundle_id or "$(" in str(bundle_id):
            raise VerificationError(f"Unexpanded or missing CFBundleIdentifier: {bundle_id!r}")
        if display_name != "Cuven":
            raise VerificationError(f"Expected CFBundleDisplayName == 'Cuven', got {display_name!r}")
        if requires_fullscreen is not False:
            raise VerificationError(
                f"iPhone Duo requires UIRequiresFullScreen == False, got {requires_fullscreen!r}"
            )
        if not isinstance(scene_manifest, dict) or scene_manifest.get("UIApplicationSupportsMultipleScenes") is not True:
            raise VerificationError(
                f"iPhone Duo requires UIApplicationSupportsMultipleScenes == True, got {scene_manifest!r}"
            )
        if not isinstance(launch_screen, dict):
            raise VerificationError(f"Missing UILaunchScreen dictionary in Info.plist: {launch_screen!r}")
        if not EXPECTED_ORIENTATIONS.issubset(orientations_iphone):
            raise VerificationError(
                f"Missing iPhone orientations: {EXPECTED_ORIENTATIONS - orientations_iphone}"
            )
        if not EXPECTED_ORIENTATIONS.issubset(orientations_ipad):
            raise VerificationError(
                f"Missing iPad/Duo orientations: {EXPECTED_ORIENTATIONS - orientations_ipad}"
            )
        if "Clarinetta-RegularItalic.ttf" in app_fonts:
            raise VerificationError(
                "Duplicate Clarinetta-RegularItalic.ttf must NOT be bundled; use Clarinetta-MediumItalic.ttf"
            )
        missing_plist_fonts = [f for f in EXPECTED_FONTS if f not in app_fonts]
        if missing_plist_fonts:
            raise VerificationError(f"Missing Clarinetta fonts in UIAppFonts: {missing_plist_fonts}")

        # 2. Verify Assets.car
        assets_entry = f"{app_prefix}Assets.car"
        if assets_entry not in names:
            raise VerificationError(f"Missing compiled asset catalog: {assets_entry}")
        assets_bytes = zf.read(assets_entry)
        if len(assets_bytes) < 1024 or not assets_bytes.startswith(b"BOMStore"):
            raise VerificationError(
                f"Invalid Assets.car ({len(assets_bytes)} bytes, magic={assets_bytes[:8]!r})"
            )

        # 3. Verify bundled Clarinetta .ttf fonts
        for font_file in EXPECTED_FONTS:
            font_entry = f"{app_prefix}{font_file}"
            if font_entry not in names:
                font_entry_sub = f"{app_prefix}Fonts/{font_file}"
                if font_entry_sub in names:
                    font_entry = font_entry_sub
                else:
                    raise VerificationError(f"Missing font resource in bundle: {font_file}")
            font_head = zf.read(font_entry)[:4]
            if font_head not in (b"OTTO", b"\x00\x01\x00\x00", b"true"):
                raise VerificationError(f"Invalid SFNT header in bundled font {font_file}: {font_head!r}")

        # 4. Verify _CodeSignature/CodeResources
        coderes_entry = f"{app_prefix}_CodeSignature/CodeResources"
        if coderes_entry not in names:
            raise VerificationError(f"Missing code signature manifest: {coderes_entry}")
        try:
            coderes_pl = plistlib.loads(zf.read(coderes_entry))
        except Exception as exc:
            raise VerificationError(f"Malformed CodeResources plist: {exc}") from exc
        if not isinstance(coderes_pl, dict) or not (coderes_pl.get("files") or coderes_pl.get("files2")):
            raise VerificationError("CodeResources plist has empty files/files2 hashes")

        # 5. Extract Mach-O executable and run struct + llvm-objdump verification
        exec_entry = f"{app_prefix}{executable_name}"
        if exec_entry not in names:
            raise VerificationError(f"Missing Mach-O executable in bundle: {exec_entry}")
        exec_bytes = zf.read(exec_entry)

    struct_report = inspect_macho_struct(exec_bytes)

    scratch_dir = choose_scratch_parent(ipa_path) / f".verify_ipa_bin_{os.getpid()}"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    extracted_bin = scratch_dir / executable_name
    try:
        extracted_bin.write_bytes(exec_bytes)
        objdump_report = inspect_with_llvm_objdump(extracted_bin)
    finally:
        shutil.rmtree(scratch_dir, ignore_errors=True)

    return {
        "ipa_path": str(ipa_path),
        "ipa_size_bytes": ipa_size,
        "ipa_sha256": ipa_sha256,
        "app_bundle": app_prefix,
        "bundle_id": bundle_id,
        "executable": executable_name,
        "ui_requires_full_screen": requires_fullscreen,
        "supports_multiple_scenes": True,
        "assets_car_bytes": len(assets_bytes),
        "verified_fonts_count": len(EXPECTED_FONTS),
        "code_resources_present": True,
        "macho_struct": struct_report,
        "llvm_objdump": objdump_report,
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify genuine ARM64 iOS 27.1 SDK (.ipa) bundle & Mach-O headers on Linux."
    )
    parser.add_argument(
        "ipas",
        nargs="*",
        help="Path(s) to .ipa file(s) to verify (e.g., dist/Cuven.ipa dist/WeChat.ipa)",
    )
    parser.add_argument(
        "--ipa",
        dest="extra_ipas",
        action="append",
        default=[],
        help="Additional .ipa file path to verify",
    )
    parser.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="Optional path to write JSON verification report",
    )
    args = parser.parse_args(argv)

    targets = [Path(p) for p in (list(args.ipas) + list(args.extra_ipas))]
    if not targets:
        parser.error("At least one .ipa path is required (e.g., python3 ios/scripts/verify-ipa-linux.py dist/Cuven.ipa)")

    reports: List[Dict[str, Any]] = []
    for target in targets:
        try:
            rep = verify_single_ipa(target)
        except VerificationError as err:
            print(f"[FAIL] {target}: {err}", file=sys.stderr)
            return 1
        reports.append(rep)
        sdk_ver = rep["llvm_objdump"]["llvm_objdump_sdk"]
        minos_ver = rep["llvm_objdump"]["llvm_objdump_minos"]
        print(
            f"[PASS] {target} — ARM64 MH_MAGIC_64 | platform=ios sdk={sdk_ver} minos={minos_ver} | "
            f"SwiftUI+UIKit linked (0 WebKit) | UIRequiresFullScreen=False | Assets.car={rep['assets_car_bytes']}B | "
            f"fonts={rep['verified_fonts_count']} | sha256={rep['ipa_sha256'][:16]}…"
        )

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(reports, indent=2) + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    sys.exit(main())
