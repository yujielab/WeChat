#!/usr/bin/env python3
"""
Convert Cuven web fonts (public/fonts/*.woff2) and app icon (public/icons/icon-512.png)
into native iOS bundle resources under ios/Cuven/Resources/.

Key invariants enforced:
1. Deduplicates Clarinetta-RegularItalic.woff2 (which is byte-identical to
   Clarinetta-BlackItalic.woff2 in the web repo; see public/css/fonts.css:35-39
   and test/fonts.test.js). Clarinetta-MediumItalic.ttf serves as both 400 Italic
   (RIBBI Italic) and 500 Medium Italic.
2. Restores OpenType/CoreText `name` table entries (nameIDs 1, 2, 3, 4, 6, 16, 17
   across Windows Unicode and Macintosh Roman platforms) from each font's embedded
   CFF TopDict metadata, replacing the webfont '*' placeholders so UIAppFonts /
   CTFontManager / SwiftUI Font.custom(...) resolve every face natively on iOS.
3. Generates Assets.xcassets with a 1024x1024 opaque sRGB PNG AppIcon upscaled via
   Lanczos from public/icons/icon-512.png, plus AccentColor (#007AFF / #0A84FF)
   and PaperBackground (#FFFFFF / #000000) dynamic color sets.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Dict, List, Tuple

from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont, newTable
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[2]
WEB_FONTS_DIR = REPO_ROOT / "public" / "fonts"
WEB_ICON_PATH = REPO_ROOT / "public" / "icons" / "icon-512.png"

IOS_RESOURCES_DIR = REPO_ROOT / "ios" / "Cuven" / "Resources"
IOS_FONTS_DIR = IOS_RESOURCES_DIR / "Fonts"
IOS_XCASSETS_DIR = IOS_RESOURCES_DIR / "Assets.xcassets"

# Canonical 13 unique faces from public/css/fonts.css (excluding the duplicate
# Clarinetta-RegularItalic.woff2 twin of Clarinetta-BlackItalic.woff2).
# Tuple: (source_woff2, output_ttf, typographic_family, typographic_subfamily, ribbi_family, ribbi_subfamily, expected_ps_name)
FONT_MANIFEST: List[Tuple[str, str, str, str, str, str, str]] = [
    (
        "Clarinetta-Light.woff2",
        "Clarinetta-Light.ttf",
        "Clarinetta",
        "Light",
        "Clarinetta Light",
        "Regular",
        "Clarinetta-Light",
    ),
    (
        "Clarinetta-LightItalic.woff2",
        "Clarinetta-LightItalic.ttf",
        "Clarinetta",
        "Light Italic",
        "Clarinetta Light",
        "Italic",
        "Clarinetta-LightItalic",
    ),
    (
        "Clarinetta-Regular.woff2",
        "Clarinetta-Regular.ttf",
        "Clarinetta",
        "Regular",
        "Clarinetta",
        "Regular",
        "Clarinetta-Regular",
    ),
    (
        "Clarinetta-Medium.woff2",
        "Clarinetta-Medium.ttf",
        "Clarinetta",
        "Medium",
        "Clarinetta Medium",
        "Regular",
        "Clarinetta-Medium",
    ),
    (
        # Stands in for 400 Regular Italic AND 500 Medium Italic (matching public/css/fonts.css:39).
        # Linking RIBBI (Clarinetta, Italic) lets SwiftUI Font.custom("Clarinetta", ...).italic()
        # resolve here automatically while PostScript name "Clarinetta-MediumItalic" also works directly.
        "Clarinetta-MediumItalic.woff2",
        "Clarinetta-MediumItalic.ttf",
        "Clarinetta",
        "Medium Italic",
        "Clarinetta",
        "Italic",
        "Clarinetta-MediumItalic",
    ),
    (
        "Clarinetta-Bold.woff2",
        "Clarinetta-Bold.ttf",
        "Clarinetta",
        "Bold",
        "Clarinetta",
        "Bold",
        "Clarinetta-Bold",
    ),
    (
        "Clarinetta-BoldItalic.woff2",
        "Clarinetta-BoldItalic.ttf",
        "Clarinetta",
        "Bold Italic",
        "Clarinetta",
        "Bold Italic",
        "Clarinetta-BoldItalic",
    ),
    (
        "Clarinetta-ExtraBold.woff2",
        "Clarinetta-ExtraBold.ttf",
        "Clarinetta",
        "ExtraBold",
        "Clarinetta ExtraBold",
        "Regular",
        "Clarinetta-ExtraBold",
    ),
    (
        "Clarinetta-ExtraBoldItalic.woff2",
        "Clarinetta-ExtraBoldItalic.ttf",
        "Clarinetta",
        "ExtraBold Italic",
        "Clarinetta ExtraBold",
        "Italic",
        "Clarinetta-ExtraBoldItalic",
    ),
    (
        "Clarinetta-Black.woff2",
        "Clarinetta-Black.ttf",
        "Clarinetta",
        "Black",
        "Clarinetta Black",
        "Regular",
        "Clarinetta-Black",
    ),
    (
        "Clarinetta-BlackItalic.woff2",
        "Clarinetta-BlackItalic.ttf",
        "Clarinetta",
        "Black Italic",
        "Clarinetta Black",
        "Italic",
        "Clarinetta-BlackItalic",
    ),
    (
        "Clarinetta-UltraItalic.woff2",
        "Clarinetta-UltraItalic.ttf",
        "Clarinetta",
        "Ultra Italic",
        "Clarinetta Ultra",
        "Italic",
        "Clarinetta-UltraItalic",
    ),
    (
        "ClarinettaUnicase-Bold.woff2",
        "ClarinettaUnicase-Bold.ttf",
        "Clarinetta Unicase",
        "Bold",
        "Clarinetta Unicase",
        "Bold",
        "ClarinettaUnicase-Bold",
    ),
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def set_font_names(
    tt: TTFont,
    typo_family: str,
    typo_subfamily: str,
    ribbi_family: str,
    ribbi_subfamily: str,
    ps_name: str,
    full_name: str,
) -> None:
    name_table = tt["name"]
    version_rec = name_table.getName(5, 3, 1, 0x409)
    version_str = version_rec.toUnicode() if version_rec else "Version 1.002"
    unique_id = f"{version_str};supe;{ps_name}"

    entries: Dict[int, str] = {
        1: ribbi_family,
        2: ribbi_subfamily,
        3: unique_id,
        4: full_name,
        6: ps_name,
        16: typo_family,
        17: typo_subfamily,
    }
    for name_id, value in entries.items():
        # Windows Unicode BMP (English US)
        name_table.setName(value, name_id, 3, 1, 0x0409)
        # Macintosh Roman (English) for legacy/CoreText tools
        name_table.setName(value, name_id, 1, 0, 0)


def convert_fonts() -> List[Path]:
    # Verify the known duplicate invariant before converting
    reg_italic_woff2 = WEB_FONTS_DIR / "Clarinetta-RegularItalic.woff2"
    blk_italic_woff2 = WEB_FONTS_DIR / "Clarinetta-BlackItalic.woff2"
    if reg_italic_woff2.exists() and blk_italic_woff2.exists():
        if sha256_file(reg_italic_woff2) == sha256_file(blk_italic_woff2):
            print(
                "[fonts] Confirmed Clarinetta-RegularItalic.woff2 is byte-identical to "
                "Clarinetta-BlackItalic.woff2; skipping twin and using Clarinetta-MediumItalic.ttf for 400i/500i."
            )

    if IOS_FONTS_DIR.exists():
        shutil.rmtree(IOS_FONTS_DIR)
    IOS_FONTS_DIR.mkdir(parents=True, exist_ok=True)

    seen_hashes: Dict[str, str] = {}
    seen_ps_names: Dict[str, str] = {}
    written: List[Path] = []

    for (
        src_name,
        dst_name,
        typo_fam,
        typo_sub,
        ribbi_fam,
        ribbi_sub,
        expected_ps,
    ) in FONT_MANIFEST:
        src_path = WEB_FONTS_DIR / src_name
        if not src_path.is_file():
            raise FileNotFoundError(f"Missing web font: {src_path}")

        tt = TTFont(str(src_path))
        # Decompress WOFF2 wrapper into uncompressed SFNT
        tt.flavor = None

        if "CFF " in tt:
            cff = tt["CFF "].cff
            actual_ps = cff.fontNames[0]
            top = cff.topDictIndex[0]
            full_name = getattr(top, "FullName", None) or f"{typo_fam} {typo_sub}"
            if actual_ps != expected_ps:
                raise ValueError(
                    f"CFF PostScript mismatch in {src_name}: got {actual_ps!r}, expected {expected_ps!r}"
                )

            # Convert cubic CFF splines into genuine TrueType quadratic outlines (glyf + loca, 0x00010000)
            glyph_order = tt.getGlyphOrder()
            glyph_set = tt.getGlyphSet()
            upm = tt["head"].unitsPerEm
            max_err = upm * 0.001

            glyf_glyphs = {}
            for gname in glyph_order:
                tt_pen = TTGlyphPen(glyph_set)
                cu2qu_pen = Cu2QuPen(tt_pen, max_err=max_err, reverse_direction=True)
                glyph_set[gname].draw(cu2qu_pen)
                glyf_glyphs[gname] = tt_pen.glyph()

            del tt["CFF "]
            tt.sfntVersion = "\x00\x01\x00\x00"

            glyf_table = newTable("glyf")
            glyf_table.glyphs = glyf_glyphs
            glyf_table.glyphOrder = glyph_order
            tt["glyf"] = glyf_table
            tt["loca"] = newTable("loca")

            tt["head"].glyphDataFormat = 0
            tt["post"].formatType = 2.0
            tt["post"].extraNames = []
            tt["post"].mapping = {}
            tt["post"].glyphOrder = glyph_order

            maxp_table = newTable("maxp")
            maxp_table.tableVersion = 0x00010000
            maxp_table.maxZones = 1
            maxp_table.maxTwilightPoints = 0
            maxp_table.maxStorage = 0
            maxp_table.maxFunctionDefs = 0
            maxp_table.maxInstructionDefs = 0
            maxp_table.maxStackElements = 0
            maxp_table.maxSizeOfInstructions = 0
            maxp_table.maxComponentElements = 0
            maxp_table.maxComponentDepth = 0
            tt["maxp"] = maxp_table
        else:
            actual_ps = expected_ps
            full_name = f"{typo_fam} {typo_sub}"

        if "OS/2" in tt:
            tt["OS/2"].fsType = 0

        set_font_names(
            tt=tt,
            typo_family=typo_fam,
            typo_subfamily=typo_sub,
            ribbi_family=ribbi_fam,
            ribbi_subfamily=ribbi_sub,
            ps_name=actual_ps,
            full_name=full_name,
        )

        dst_path = IOS_FONTS_DIR / dst_name
        tt.save(str(dst_path))
        tt.close()

        # Re-open & strictly verify genuine TrueType SFNT magic header + glyf/loca/cmap/name tables
        raw_magic = dst_path.read_bytes()[:4]
        if raw_magic != b"\x00\x01\x00\x00":
            raise ValueError(f"Expected TrueType SFNT magic 0x00010000 in {dst_name}, got {raw_magic!r}")

        verify_tt = TTFont(str(dst_path))
        ps_loaded = verify_tt["name"].getDebugName(6)
        fam_loaded = verify_tt["name"].getDebugName(16) or verify_tt["name"].getDebugName(1)
        cmap_table = verify_tt["cmap"].getBestCmap() or {}
        has_glyf = "glyf" in verify_tt and "loca" in verify_tt
        num_glyphs = verify_tt["maxp"].numGlyphs
        verify_tt.close()

        if not has_glyf or num_glyphs < 100:
            raise ValueError(f"Invalid TrueType glyf/loca tables in {dst_name} (numGlyphs={num_glyphs})")
        if ps_loaded != expected_ps or not fam_loaded:
            raise ValueError(f"Failed to verify PostScript/Family name for {dst_name}: {ps_loaded!r}")
        if ord("A") not in cmap_table or ord("a") not in cmap_table:
            raise ValueError(f"Broken cmap in {dst_name}")

        digest = sha256_file(dst_path)
        if digest in seen_hashes:
            raise ValueError(f"Duplicate output font binary: {dst_name} == {seen_hashes[digest]}")
        if ps_loaded in seen_ps_names:
            raise ValueError(f"Duplicate PostScript name {ps_loaded}: {dst_name} == {seen_ps_names[ps_loaded]}")

        seen_hashes[digest] = dst_name
        seen_ps_names[ps_loaded] = dst_name
        written.append(dst_path)
        print(
            f"[fonts] Wrote {dst_name:32s} ({dst_path.stat().st_size:6d} B, TrueType 0x00010000, glyphs={num_glyphs}, ps={ps_loaded})"
        )

    return written


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def build_xcassets() -> None:
    if not WEB_ICON_PATH.is_file():
        raise FileNotFoundError(f"Missing source icon: {WEB_ICON_PATH}")

    if IOS_XCASSETS_DIR.exists():
        shutil.rmtree(IOS_XCASSETS_DIR)
    IOS_XCASSETS_DIR.mkdir(parents=True, exist_ok=True)

    # Root Contents.json
    write_json(
        IOS_XCASSETS_DIR / "Contents.json",
        {"info": {"author": "xcode", "version": 1}},
    )

    # 1. AppIcon.appiconset — 1024x1024 opaque sRGB PNG upscaled via Lanczos from icon-512.png
    appicon_dir = IOS_XCASSETS_DIR / "AppIcon.appiconset"
    appicon_dir.mkdir(parents=True, exist_ok=True)

    with Image.open(WEB_ICON_PATH) as src_img:
        rgba = src_img.convert("RGBA")
        # Composite over pure paper-white (#FFFFFF) so iOS AppIcon has zero alpha channel
        # (matching apple-touch-icon.png & icon-maskable-512.png and satisfying Apple actool).
        white_bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        composited = Image.alpha_composite(white_bg, rgba).convert("RGB")
        upscaled = composited.resize((1024, 1024), Image.Resampling.LANCZOS)
        icon_out = appicon_dir / "AppIcon-1024.png"
        upscaled.save(icon_out, format="PNG", optimize=True)

    with Image.open(icon_out) as check_img:
        if check_img.size != (1024, 1024) or check_img.mode != "RGB":
            raise ValueError(f"Invalid generated AppIcon: size={check_img.size}, mode={check_img.mode}")

    write_json(
        appicon_dir / "Contents.json",
        {
            "images": [
                {
                    "filename": "AppIcon-1024.png",
                    "idiom": "universal",
                    "platform": "ios",
                    "size": "1024x1024",
                }
            ],
            "info": {"author": "xcode", "version": 1},
        },
    )
    print(f"[assets] Wrote AppIcon-1024.png ({icon_out.stat().st_size} B, 1024x1024 RGB)")

    # 2. AccentColor.colorset (#007AFF Light / #0A84FF Dark)
    write_json(
        IOS_XCASSETS_DIR / "AccentColor.colorset" / "Contents.json",
        {
            "colors": [
                {
                    "color": {
                        "color-space": "srgb",
                        "components": {
                            "alpha": "1.000",
                            "blue": "0xFF",
                            "green": "0x7A",
                            "red": "0x00",
                        },
                    },
                    "idiom": "universal",
                },
                {
                    "appearances": [
                        {"appearance": "luminosity", "value": "dark"}
                    ],
                    "color": {
                        "color-space": "srgb",
                        "components": {
                            "alpha": "1.000",
                            "blue": "0xFF",
                            "green": "0x84",
                            "red": "0x0A",
                        },
                    },
                    "idiom": "universal",
                },
            ],
            "info": {"author": "xcode", "version": 1},
        },
    )
    print("[assets] Wrote AccentColor.colorset (#007AFF / #0A84FF)")

    # 3. PaperBackground.colorset (#FFFFFF Light / #000000 Dark per public/css/tokens.css)
    write_json(
        IOS_XCASSETS_DIR / "PaperBackground.colorset" / "Contents.json",
        {
            "colors": [
                {
                    "color": {
                        "color-space": "srgb",
                        "components": {
                            "alpha": "1.000",
                            "blue": "0xFF",
                            "green": "0xFF",
                            "red": "0xFF",
                        },
                    },
                    "idiom": "universal",
                },
                {
                    "appearances": [
                        {"appearance": "luminosity", "value": "dark"}
                    ],
                    "color": {
                        "color-space": "srgb",
                        "components": {
                            "alpha": "1.000",
                            "blue": "0x00",
                            "green": "0x00",
                            "red": "0x00",
                        },
                    },
                    "idiom": "universal",
                },
            ],
            "info": {"author": "xcode", "version": 1},
        },
    )
    print("[assets] Wrote PaperBackground.colorset (#FFFFFF / #000000)")


def main() -> int:
    fonts = convert_fonts()
    build_xcassets()
    print(f"[done] Successfully generated {len(fonts)} SFNT fonts and Assets.xcassets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
