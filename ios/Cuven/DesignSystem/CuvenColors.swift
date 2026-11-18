//
//  CuvenColors.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Color & Dark Mode (dynamic Light/Dark & Increased Contrast adaptation)
//  - Human Interface Guidelines › Accessibility › Color and Contrast (WCAG AA >= 4.5:1 text variants)
//  - Cuven Web Parity: `public/css/tokens.css:14-450`, `public/css/chat.css:86,103`,
//    `public/css/columns.css:54,74`, `public/css/list.css:39,53,67`, `public/css/base.css:215-250,339-342`
//

import SwiftUI
import UIKit

/// Canonical dynamic Light, Dark, and High-Contrast color palette for Cuven.
///
/// Reflects the authoritative CSS cascade (`tokens.css` -> `thread.css` -> `chat.css` / `columns.css` / `list.css`):
/// - Pure paper-white (`#FFFFFF` / `#F5F5F7`) & pure OLED black (`#000000` / `#121214`) surfaces
/// - Live `.thread` outgoing bubbles in Facebook Blue `#1877F2` with `#FFFFFF` text (`chat.css:103`)
/// - Composer Send & primary solid CTAs in Ink (`#000000` light / `#F5F5FA` dark, `tokens.css:76,324`)
/// - `"Messages"` / `"Home"` large titles & Sidebar/Details icons in `#1877F2` light / `#2D88FF` dark (`list.css:53`, `columns.css:54,74`)
/// - `"Moments"` large title in Sky Blue `#0099FF` light / `#4CC2FF` dark (`tokens.css:62,285`)
public enum CuvenColors: Sendable {

    // MARK: - Canonical PROJECT.md § 5.3 Surface & Ink Tokens

    /// Primary canvas background (`--bg`): `#FFFFFF` (Light) / `#000000` (Dark).
    public static let paperBackground = Color(uiColor: uiPaperBackground)

    /// Elevated surface (`--paper` / `--bg-elevated`): `#F5F5F7` (Light) / `#121214` (Dark).
    public static let elevatedSurface = Color(uiColor: uiElevatedSurface)

    /// Primary label & editorial ink (`--label`): `#0B0B0D` (Light) / `#F5F5FA` (Dark).
    public static let inkPrimary = Color(uiColor: uiInkPrimary)

    /// Secondary metadata label (`--label-2`): `#6E6E73` (`#3A3A3C` High Contrast) in Light;
    /// `rgba(240, 240, 250, 0.60)` (`0.80` High Contrast) in Dark.
    public static let inkSecondary = Color(uiColor: uiInkSecondary)

    // MARK: - Canonical PROJECT.md § 5.3 Conversation Bubble Tokens

    /// Outgoing message bubble fill (`chat.css:103` `--bubble-out: var(--fb-blue)`): `#1877F2` in Light & Dark.
    public static let outgoingBubble = Color(uiColor: uiOutgoingBubble)

    /// Outgoing message bubble foreground text (`chat.css:103` `--bubble-out-text`): `#FFFFFF` in Light & Dark.
    public static let outgoingBubbleText = Color(uiColor: uiOutgoingBubbleText)

    /// Incoming message bubble fill (`tokens.css:81,297` `--bubble-in`): `#F0F0F2` (Light) / `#232626` (Dark).
    public static let incomingBubble = Color(uiColor: uiIncomingBubble)

    /// Incoming message bubble foreground text (`tokens.css:82,298` `--bubble-in-text`): `#111B21` (Light) / `#E9EDEF` (Dark).
    public static let incomingBubbleText = Color(uiColor: uiIncomingBubbleText)

    // MARK: - Canonical PROJECT.md § 5.3 Brand, Status & Chrome Tokens

    /// Sidebar (`"Home"`), `"Messages"` large title, Details icons & active filter accent
    /// (`--fb-blue` / `--fb-blue-title`): `#1877F2` (Light) / `#2D88FF` (Dark).
    public static let sidebarBlue = Color(uiColor: uiSidebarBlue)

    /// Live presence dot & active switch green (`--green`): `#34C759` (Light) / `#30D158` (Dark).
    public static let onlineGreen = Color(uiColor: uiOnlineGreen)

    /// Destructive action & missed-call icon fill (`--red`): `#FF3B30` (Light) / `#FF453A` (Dark).
    public static let dangerRed = Color(uiColor: uiDangerRed)

    /// The dot on the Moments button while friends have shared something new.
    public static let freshMomentsDot = dangerRed

    /// Warning & pending state fill (`--orange`): `#FF9500` (Light) / `#FF9F0A` (Dark).
    public static let warningAmber = Color(uiColor: uiWarningAmber)

    /// Retina `0.5pt` hairline separator (`--separator`):
    /// `rgba(60, 60, 67, 0.22)` (`0.50` HC) in Light / `rgba(240, 240, 250, 0.16)` (`0.32` HC) in Dark.
    public static let hairlineSeparator = Color(uiColor: uiHairlineSeparator)

    // MARK: - Live CSS Cascade Extended Tokens (Tokens.css / Chat.css / List.css / Moments.css)

    /// Pure Facebook Blue (`--fb-blue`): `#1877F2` across Light & Dark.
    public static let facebookBlue = Color(uiColor: UIColor(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0, alpha: 1.0))

    /// `"Messages"` & `"Home"` header title blue (`--fb-blue-title`): `#1877F2` (Light) / `#2D88FF` (Dark).
    public static let messagesTitleBlue = sidebarBlue

    /// `"Moments"` livelier Sky Blue title (`--sky-title`, `tokens.css:62,285`): `#0099FF` (Light) / `#4CC2FF` (Dark).
    public static let momentsSkyBlue = Color(uiColor: uiMomentsSkyBlue)

    /// Apple system blue (`--blue`): `#007AFF` (Light) / `#0A84FF` (Dark).
    public static let systemBlue = Color(uiColor: uiSystemBlue)

    /// WCAG AA (`>= 4.5:1`) readable blue text (`--blue-text`): `#0062CC` (Light) / `#0A84FF` (Dark).
    public static let accessibleBlueText = Color(uiColor: uiAccessibleBlueText)

    /// Outgoing message read double-tick blue (`--tick-read`): `#007DFF` (Light) / `#27A8FF` (Dark).
    public static let readTickBlue = Color(uiColor: uiReadTickBlue)

    /// Composer active Send circle & primary solid CTA fill (`--ink`, `tokens.css:76,324`, `chat.css:142`):
    /// `#000000` (Light) / `#F5F5FA` (Dark).
    public static let ctaInk = Color(uiColor: uiCtaInk)

    /// Foreground icon/label on `ctaInk` (`--on-ink`, `tokens.css:77,325`): `#FFFFFF` (Light) / `#000000` (Dark).
    public static let onCtaInk = Color(uiColor: uiOnCtaInk)

    /// Classic dark-ink outgoing bubble option (`#18181B` Light / `#27272A` Dark) for optional theme overrides.
    public static let outgoingBubbleInkClassic = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0, alpha: 1.0),
            dark: UIColor(red: 0x27 / 255.0, green: 0x27 / 255.0, blue: 0x2A / 255.0, alpha: 1.0)
        )
    )

    /// Outgoing bubble metadata/timestamp white (`chat.css:104`): `rgba(255, 255, 255, 0.72)`.
    public static let outgoingBubbleMeta = Color.white.opacity(0.72)

    /// Elevated card/sheet face (`--surface` / `--bg-elevated`): `#FFFFFF` (Light) / `#121214` (Dark).
    public static let cardSurface = Color(uiColor: uiCardSurface)

    /// Secondary grouped elevated surface (`#F2F2F7` Light / `#1C1C1E` Dark).
    public static let secondaryElevatedSurface = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0, alpha: 1.0),
            dark: UIColor(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1.0)
        )
    )

    /// Recessed input field & search well (`--field`): `#F2F2F5` (Light) / `#111113` (Dark).
    public static let fieldBackground = Color(uiColor: uiFieldBackground)

    /// Backdrop behind receded app shell during compact bottom-sheet presentation (`--recede`):
    /// `#D1D1D6` (Light) / `#000000` (Dark).
    public static let recedeBackground = Color(uiColor: uiRecedeBackground)

    /// Tertiary label / chevron (`--label-3`): `#8E8E93` (`#6C6C70` HC) in Light;
    /// `rgba(240, 240, 250, 0.34)` (`0.60` HC) in Dark.
    public static let inkTertiary = Color(uiColor: uiInkTertiary)

    /// Quaternary placeholder / subtle disabled stroke (`--label-4`).
    public static let inkQuaternary = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 60.0 / 255.0, green: 60.0 / 255.0, blue: 67.0 / 255.0, alpha: 0.18),
            dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.16)
        )
    )

    /// `1pt` card, sheet, and input border (`--line`): `#E5E5EA` (`#C7C7CC` HC) in Light;
    /// `rgba(240, 240, 250, 0.13)` (`0.30` HC) in Dark.
    public static let cardLine = Color(uiColor: uiCardLine)

    /// Opaque separator & sheet grabber pill (`--separator-opaque`): `#E3E3E8` (Light) / `#2A2A2E` (Dark).
    public static let opaqueSeparator = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0xE3 / 255.0, green: 0xE3 / 255.0, blue: 0xE8 / 255.0, alpha: 1.0),
            dark: UIColor(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0, alpha: 1.0)
        )
    )

    /// Brand icon/accent green (`--brand`): `#00AD59`.
    public static let brandGreen = Color(uiColor: UIColor(red: 0x00 / 255.0, green: 0xAD / 255.0, blue: 0x59 / 255.0, alpha: 1.0))

    /// WCAG-compliant unread count badge fill (`--badge-bg` / `--brand-strong`):
    /// `#007A4D` (`5.4:1` on white) in Light / `#00C357` (`8.9:1` with black text) in Dark.
    public static let unreadBadgeBackground = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0x00 / 255.0, green: 0x7A / 255.0, blue: 0x4D / 255.0, alpha: 1.0),
            dark: UIColor(red: 0x00 / 255.0, green: 0xC3 / 255.0, blue: 0x57 / 255.0, alpha: 1.0)
        )
    )

    /// Foreground text on `unreadBadgeBackground` (`--badge-text`): `#FFFFFF` (Light) / `#000000` (Dark).
    public static let unreadBadgeText = Color(
        uiColor: dynamicUIColor(
            light: .white,
            dark: .black
        )
    )

    /// WCAG-compliant unread row timestamp green (`--brand-text`): `#007A4D` (Light) / `#00C357` (Dark).
    public static let unreadTimestampGreen = unreadBadgeBackground

    /// WCAG-compliant destructive text (`--red-text`): `#D70015` (`5.4:1` Light) / `#FF453A` (Dark).
    public static let dangerRedText = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0xD7 / 255.0, green: 0x00 / 255.0, blue: 0x15 / 255.0, alpha: 1.0),
            dark: UIColor(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1.0)
        )
    )

    /// WCAG-compliant warning text (`--orange-text`): `#C93400` (`5.3:1` Light) / `#FF9F0A` (Dark).
    public static let warningAmberText = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0xC9 / 255.0, green: 0x34 / 255.0, blue: 0x00 / 255.0, alpha: 1.0),
            dark: UIColor(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0, alpha: 1.0)
        )
    )

    /// System notice / encryption banner pill fill (`--notice-bg`): `#FFEFD1` (Light) / `#232626` (Dark).
    public static let noticeBackground = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0xFF / 255.0, green: 0xEF / 255.0, blue: 0xD1 / 255.0, alpha: 1.0),
            dark: UIColor(red: 0x23 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0, alpha: 1.0)
        )
    )

    /// System notice foreground text (`--notice-text`): `#6B5525` (Light) / `rgba(240, 240, 250, 0.60)` (Dark).
    public static let noticeText = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 0x6B / 255.0, green: 0x55 / 255.0, blue: 0x25 / 255.0, alpha: 1.0),
            dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.60)
        )
    )

    /// Modal backdrop scrim (`--scrim`): `rgba(0, 0, 0, 0.32)` (Light) / `rgba(0, 0, 0, 0.60)` (Dark).
    public static let overlayScrim = Color(
        uiColor: dynamicUIColor(
            light: UIColor(white: 0.0, alpha: 0.32),
            dark: UIColor(white: 0.0, alpha: 0.60)
        )
    )

    /// iPhone Duo half-open book/laptop crease binding shadow (`--gutter-shade`, `base.css:190-192`):
    /// `5%` black in Light / `38%` black in Dark.
    public static let hingeGutterShade = Color(
        uiColor: dynamicUIColor(
            light: UIColor(white: 0.0, alpha: 0.05),
            dark: UIColor(white: 0.0, alpha: 0.38)
        )
    )

    /// Liquid Glass `50%` frosted base (`--glass-frost`, `tokens.css:101,305`):
    /// `rgba(236, 236, 240, 0.50)` (Light) / `rgba(72, 72, 78, 0.50)` (Dark).
    public static let glassFrostBase = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 236.0 / 255.0, green: 236.0 / 255.0, blue: 240.0 / 255.0, alpha: 0.50),
            dark: UIColor(red: 72.0 / 255.0, green: 72.0 / 255.0, blue: 78.0 / 255.0, alpha: 0.50)
        )
    )

    /// Solid opaque fallback for Liquid Glass under Reduce Transparency (`--glass-solid`, `tokens.css:110,311`):
    /// `#FFFFFF` (Light) / `#121214` (Dark).
    public static let glassSolidFallback = Color(
        uiColor: dynamicUIColor(
            light: .white,
            dark: UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
        )
    )

    /// Frosted composer pill & mic fill (`--frost`, `liquid.css:208,215`):
    /// `rgba(248, 248, 250, 0.68)` (Light) / `rgba(44, 44, 48, 0.62)` (Dark).
    public static let composerFrost = Color(
        uiColor: dynamicUIColor(
            light: UIColor(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.68),
            dark: UIColor(red: 44.0 / 255.0, green: 44.0 / 255.0, blue: 48.0 / 255.0, alpha: 0.62)
        )
    )

    // MARK: - Dynamic UIKit UIColor Counterparts

    public static let uiPaperBackground = dynamicUIColor(
        light: .white,
        dark: .black
    )

    public static let uiElevatedSurface = dynamicUIColor(
        light: UIColor(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
    )

    public static let uiCardSurface = dynamicUIColor(
        light: .white,
        dark: UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
    )

    public static let uiFieldBackground = dynamicUIColor(
        light: UIColor(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x13 / 255.0, alpha: 1.0)
    )

    public static let uiRecedeBackground = dynamicUIColor(
        light: UIColor(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0, alpha: 1.0),
        dark: .black
    )

    public static let uiInkPrimary = dynamicUIColor(
        light: UIColor(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0, alpha: 1.0),
        dark: UIColor(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xFA / 255.0, alpha: 1.0)
    )

    public static let uiCtaInk = dynamicUIColor(
        light: .black,
        dark: UIColor(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xFA / 255.0, alpha: 1.0)
    )

    public static let uiOnCtaInk = dynamicUIColor(
        light: .white,
        dark: .black
    )

    public static let uiInkSecondary = dynamicUIColor(
        light: UIColor(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0, alpha: 1.0),
        dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.60),
        highContrastLight: UIColor(red: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1.0),
        highContrastDark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.80)
    )

    public static let uiInkTertiary = dynamicUIColor(
        light: UIColor(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0, alpha: 1.0),
        dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.34),
        highContrastLight: UIColor(red: 0x6C / 255.0, green: 0x6C / 255.0, blue: 0x70 / 255.0, alpha: 1.0),
        highContrastDark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.60)
    )

    public static let uiOutgoingBubble = UIColor(
        red: 0x18 / 255.0,
        green: 0x77 / 255.0,
        blue: 0xF2 / 255.0,
        alpha: 1.0
    )

    public static let uiOutgoingBubbleText = UIColor.white

    public static let uiIncomingBubble = dynamicUIColor(
        light: UIColor(red: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF2 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x23 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0, alpha: 1.0)
    )

    public static let uiIncomingBubbleText = dynamicUIColor(
        light: UIColor(red: 0x11 / 255.0, green: 0x1B / 255.0, blue: 0x21 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0xE9 / 255.0, green: 0xED / 255.0, blue: 0xEF / 255.0, alpha: 1.0)
    )

    public static let uiSidebarBlue = dynamicUIColor(
        light: UIColor(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x2D / 255.0, green: 0x88 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    )

    public static let uiMomentsSkyBlue = dynamicUIColor(
        light: UIColor(red: 0x00 / 255.0, green: 0x99 / 255.0, blue: 0xFF / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x4C / 255.0, green: 0xC2 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    )

    public static let uiSystemBlue = dynamicUIColor(
        light: UIColor(red: 0x00 / 255.0, green: 0x7A / 255.0, blue: 0xFF / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    )

    public static let uiAccessibleBlueText = dynamicUIColor(
        light: UIColor(red: 0x00 / 255.0, green: 0x62 / 255.0, blue: 0xCC / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    )

    public static let uiReadTickBlue = dynamicUIColor(
        light: UIColor(red: 0x00 / 255.0, green: 0x7D / 255.0, blue: 0xFF / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x27 / 255.0, green: 0xA8 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    )

    public static let uiOnlineGreen = dynamicUIColor(
        light: UIColor(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0, alpha: 1.0)
    )

    public static let uiDangerRed = dynamicUIColor(
        light: UIColor(red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1.0)
    )

    public static let uiWarningAmber = dynamicUIColor(
        light: UIColor(red: 0xFF / 255.0, green: 0x95 / 255.0, blue: 0x00 / 255.0, alpha: 1.0),
        dark: UIColor(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0, alpha: 1.0)
    )

    public static let uiHairlineSeparator = dynamicUIColor(
        light: UIColor(red: 60.0 / 255.0, green: 60.0 / 255.0, blue: 67.0 / 255.0, alpha: 0.22),
        dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.16),
        highContrastLight: UIColor(red: 60.0 / 255.0, green: 60.0 / 255.0, blue: 67.0 / 255.0, alpha: 0.50),
        highContrastDark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.32)
    )

    public static let uiCardLine = dynamicUIColor(
        light: UIColor(red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xEA / 255.0, alpha: 1.0),
        dark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.13),
        highContrastLight: UIColor(red: 0xC7 / 255.0, green: 0xC7 / 255.0, blue: 0xCC / 255.0, alpha: 1.0),
        highContrastDark: UIColor(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.30)
    )

    // MARK: - Hex Color Parser

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` (with or without leading `#`) into a `SwiftUI.Color`.
    public static func color(hex: String, opacity: Double? = nil) -> Color {
        guard let rgba = parseHexComponents(hex) else {
            return .clear
        }
        let finalAlpha = opacity ?? Double(rgba.a)
        return Color(.sRGB, red: Double(rgba.r), green: Double(rgba.g), blue: Double(rgba.b), opacity: finalAlpha)
    }

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` (with or without leading `#`) into a `UIColor`.
    public static func uiColor(hex: String, alpha: CGFloat? = nil) -> UIColor {
        guard let rgba = parseHexComponents(hex) else {
            return .clear
        }
        return UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: alpha ?? rgba.a)
    }

    public static func parseHexComponents(_ rawHex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        let trimmed = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !cleaned.isEmpty else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }

        switch cleaned.count {
        case 3:
            let r = CGFloat((value >> 8) & 0xF) / 15.0
            let g = CGFloat((value >> 4) & 0xF) / 15.0
            let b = CGFloat(value & 0xF) / 15.0
            return (r, g, b, 1.0)
        case 4:
            let r = CGFloat((value >> 12) & 0xF) / 15.0
            let g = CGFloat((value >> 8) & 0xF) / 15.0
            let b = CGFloat((value >> 4) & 0xF) / 15.0
            let a = CGFloat(value & 0xF) / 15.0
            return (r, g, b, a)
        case 6:
            let r = CGFloat((value >> 16) & 0xFF) / 255.0
            let g = CGFloat((value >> 8) & 0xFF) / 255.0
            let b = CGFloat(value & 0xFF) / 255.0
            return (r, g, b, 1.0)
        case 8:
            let r = CGFloat((value >> 24) & 0xFF) / 255.0
            let g = CGFloat((value >> 16) & 0xFF) / 255.0
            let b = CGFloat((value >> 8) & 0xFF) / 255.0
            let a = CGFloat(value & 0xFF) / 255.0
            return (r, g, b, a)
        default:
            return nil
        }
    }

    // MARK: - Deterministic Avatar Tint (`public/js/ui/format.js:85-89`, `public/css/base.css:223-224,339`)

    /// Computes the exact 0..<360 degree hue matching `avatarHue(id)` in `public/js/ui/format.js:85-89`.
    public static func avatarHue(for identifier: String) -> CGFloat {
        var hash: UInt32 = 0
        for scalar in identifier.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return CGFloat(hash % 360)
    }

    /// Dynamic pastel avatar placeholder background:
    /// Light `hsl(hue, 20%, 90%)` / Dark `hsl(hue, 15%, 23%)` (`base.css:223, 339`).
    public static func avatarBackground(for identifier: String) -> Color {
        let hueDegrees = avatarHue(for: identifier)
        let light = uiColorFromHSL(hueDegrees: hueDegrees, saturation: 0.20, lightness: 0.90)
        let dark = uiColorFromHSL(hueDegrees: hueDegrees, saturation: 0.15, lightness: 0.23)
        return Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    /// Dynamic legible monogram foreground on `avatarBackground`:
    /// Light `hsl(hue, 20%, 34%)` / Dark `hsl(hue, 22%, 78%)` (`base.css:224, 339`).
    public static func avatarForeground(for identifier: String) -> Color {
        let hueDegrees = avatarHue(for: identifier)
        let light = uiColorFromHSL(hueDegrees: hueDegrees, saturation: 0.20, lightness: 0.34)
        let dark = uiColorFromHSL(hueDegrees: hueDegrees, saturation: 0.22, lightness: 0.78)
        return Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    // MARK: - Private Helpers

    private static func dynamicUIColor(
        light: UIColor,
        dark: UIColor,
        highContrastLight: UIColor? = nil,
        highContrastDark: UIColor? = nil
    ) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHighContrast = traits.accessibilityContrast == .high
            if isDark {
                return (isHighContrast ? highContrastDark : nil) ?? dark
            } else {
                return (isHighContrast ? highContrastLight : nil) ?? light
            }
        }
    }

    private static func uiColorFromHSL(hueDegrees: CGFloat, saturation: CGFloat, lightness: CGFloat, alpha: CGFloat = 1.0) -> UIColor {
        let h = ((hueDegrees.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0) / 360.0
        let s = min(max(saturation, 0.0), 1.0)
        let l = min(max(lightness, 0.0), 1.0)

        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - abs((h * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0

        let (rPrime, gPrime, bPrime): (CGFloat, CGFloat, CGFloat)
        switch h * 6.0 {
        case 0.0..<1.0: (rPrime, gPrime, bPrime) = (c, x, 0)
        case 1.0..<2.0: (rPrime, gPrime, bPrime) = (x, c, 0)
        case 2.0..<3.0: (rPrime, gPrime, bPrime) = (0, c, x)
        case 3.0..<4.0: (rPrime, gPrime, bPrime) = (0, x, c)
        case 4.0..<5.0: (rPrime, gPrime, bPrime) = (x, 0, c)
        default:        (rPrime, gPrime, bPrime) = (c, 0, x)
        }

        return UIColor(red: rPrime + m, green: gPrime + m, blue: bPrime + m, alpha: alpha)
    }
}

extension Color {
    /// Creates a `Color` from a hex string (`#RGB`, `#RRGGBB`, `#RRGGBBAA`).
    public init(cuvenHex: String, opacity: Double? = nil) {
        self = CuvenColors.color(hex: cuvenHex, opacity: opacity)
    }
}

extension UIColor {
    /// Creates a `UIColor` from a hex string (`#RGB`, `#RRGGBB`, `#RRGGBBAA`).
    public convenience init(cuvenHex: String, alpha: CGFloat? = nil) {
        if let rgba = CuvenColors.parseHexComponents(cuvenHex) {
            self.init(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: alpha ?? rgba.a)
        } else {
            self.init(white: 0.0, alpha: 0.0)
        }
    }
}
