//
//  CuvenFonts.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Typography › Using Custom Fonts & Supporting Dynamic Type
//  - Cuven Web Parity: `public/css/fonts.css:1-114`, `public/css/tokens.css:125-147`,
//    `public/js/ui/steady.js:20` (`DYNAMIC_TYPE_MAX = 21` — `xxLarge` ceiling so chrome bars never clip)
//

import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import UIKit

/// Typography system pairing bundled `Clarinetta` display/editorial faces with Dynamic-Type-scaled SF Pro
/// capped at `DYNAMIC_TYPE_MAX = 21pt` (`xxLarge`) on navigation & toolbar chrome.
public enum CuvenFonts: Sendable {

    /// Maximum Dynamic Type body point size on chrome bars (`steady.js:20` `DYNAMIC_TYPE_MAX = 21`).
    public static let DYNAMIC_TYPE_MAX: CGFloat = 21.0

    /// Alias in Swift naming style (`21.0pt`, corresponding to `DynamicTypeSize.xxLarge` vs `17.0pt` default `.large`).
    public static let dynamicTypeMaxPoints: CGFloat = 21.0

    /// Maximum `DynamicTypeSize` (`xxLarge` = `21pt` body) for chrome toolbars, capsules, and headers.
    public static let dynamicTypeCeiling: DynamicTypeSize = .xxLarge

    /// Wordmark tracking ratio (`tokens.css:141` `--track-wordmark: 0.34em`).
    public static let wordmarkTrackingRatio: CGFloat = 0.34

    /// Eyebrow section header tracking ratio (`tokens.css:142` `--track-eyebrow: 0.08em`).
    public static let eyebrowTrackingRatio: CGFloat = 0.08

    // MARK: - Clarinetta Custom Font Loader (`PROJECT.md § 5.3`)

    /// Loads the bundled `Clarinetta` face for the requested size, weight, and italic posture,
    /// falling back cleanly to Apple's system serif display design when font resources are absent.
    ///
    /// - Important: Per `public/css/fonts.css:35-39` and `test/fonts.test.js`, `Clarinetta-RegularItalic`
    ///   in the web font distribution is byte-identical to `Clarinetta-BlackItalic`; weight-400 italic
    ///   therefore maps intentionally to `Clarinetta-MediumItalic`.
    public static func clarinettaDisplay(
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        let stem = clarinettaResourceStem(for: weight, italic: italic)
        if let uiFont = resolveBundledFont(stem: stem, size: size) {
            return Font(uiFont)
        }
        let fallback = Font.system(size: size, weight: weight, design: .serif)
        return italic ? fallback.italic() : fallback
    }

    /// Loads the separate `ClarinettaUnicase-Bold` display face (`fonts.css:108-113`), with serif bold fallback.
    public static func clarinettaUnicase(size: CGFloat) -> Font {
        if let uiFont = resolveBundledFont(stem: "ClarinettaUnicase-Bold", size: size) {
            return Font(uiFont)
        }
        return Font.system(size: size, weight: .bold, design: .serif)
    }

    /// Loads `Clarinetta-UltraItalic` (`fonts.css:99-104`, weight 1000 italic), with black italic serif fallback.
    public static func clarinettaUltraItalic(size: CGFloat) -> Font {
        if let uiFont = resolveBundledFont(stem: "Clarinetta-UltraItalic", size: size) {
            return Font(uiFont)
        }
        return Font.system(size: size, weight: .black, design: .serif).italic()
    }

    /// UIKit counterpart for `clarinettaDisplay(size:weight:italic:)`, optionally scaled via `UIFontMetrics`
    /// up to `maximumPointSize`.
    public static func clarinettaUIFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false,
        relativeTo textStyle: UIFont.TextStyle? = nil,
        maximumPointSize: CGFloat? = nil
    ) -> UIFont {
        let stem = clarinettaResourceStem(for: weight, italic: italic)
        let baseFont = resolveBundledFont(stem: stem, size: size) ?? fallbackSerifUIFont(size: size, weight: weight, italic: italic)
        guard let textStyle else { return baseFont }
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        if let maximumPointSize {
            return metrics.scaledFont(for: baseFont, maximumPointSize: maximumPointSize)
        }
        return metrics.scaledFont(for: baseFont)
    }

    // MARK: - Capped SF Pro Dynamic Type Helpers (`PROJECT.md § 5.3` & `steady.js` Parity)

    /// Body (`17pt` base -> `21pt` ceiling, `--t-body: 1rem`).
    public static func cappedBody(weight: Font.Weight = .regular) -> Font {
        scaledSystemFont(baseSize: 17.0, weight: weight, textStyle: .body, ceilingOverride: DYNAMIC_TYPE_MAX)
    }

    /// Chrome & sheet title (`20pt` base -> `24.5pt` ceiling, `--t-title-3: 1.176rem`, `overlays.css:124`).
    public static func cappedTitle(weight: Font.Weight = .bold) -> Font {
        scaledSystemFont(baseSize: 20.0, weight: weight, textStyle: .title3)
    }

    /// Semibold headline (`17pt` base -> `21pt` ceiling, `--t-headline: 1rem`).
    public static func cappedHeadline(weight: Font.Weight = .semibold) -> Font {
        scaledSystemFont(baseSize: 17.0, weight: weight, textStyle: .headline, ceilingOverride: DYNAMIC_TYPE_MAX)
    }

    /// Caption 1 (`12pt` base -> `15pt` ceiling, `--t-caption: 0.706rem`).
    public static func cappedCaption(weight: Font.Weight = .regular) -> Font {
        scaledSystemFont(baseSize: 12.0, weight: weight, textStyle: .caption1)
    }

    /// Large column title (`34pt` base -> `42pt` ceiling, `--t-large-title: 2rem` for `"Messages"`, `"Home"`, `"Moments"`).
    public static func cappedLargeTitle(weight: Font.Weight = .bold) -> Font {
        scaledSystemFont(baseSize: 34.0, weight: weight, textStyle: .largeTitle)
    }

    /// Title 1 (`28pt` base -> `34.5pt` ceiling, `--t-title-1: 1.647rem`).
    public static func cappedTitle1(weight: Font.Weight = .bold) -> Font {
        scaledSystemFont(baseSize: 28.0, weight: weight, textStyle: .title1)
    }

    /// Title 2 (`22pt` base -> `27pt` ceiling, `--t-title-2: 1.294rem`).
    public static func cappedTitle2(weight: Font.Weight = .semibold) -> Font {
        scaledSystemFont(baseSize: 22.0, weight: weight, textStyle: .title2)
    }

    /// Callout (`16pt` base -> `20pt` ceiling, `--t-callout: 0.941rem`).
    public static func cappedCallout(weight: Font.Weight = .regular) -> Font {
        scaledSystemFont(baseSize: 16.0, weight: weight, textStyle: .callout)
    }

    /// Subheadline (`15pt` base -> `18.5pt` ceiling, `--t-subhead: 0.882rem`).
    public static func cappedSubheadline(weight: Font.Weight = .regular) -> Font {
        scaledSystemFont(baseSize: 15.0, weight: weight, textStyle: .subheadline)
    }

    /// Short name for `cappedSubheadline` (the list's rows and filters use it).
    public static func cappedSubhead(weight: Font.Weight = .regular) -> Font {
        cappedSubheadline(weight: weight)
    }

    /// Footnote (`13pt` base -> `16pt` ceiling, `--t-footnote: 0.765rem`).
    public static func cappedFootnote(weight: Font.Weight = .regular) -> Font {
        scaledSystemFont(baseSize: 13.0, weight: weight, textStyle: .footnote)
    }

    /// Caption 2 (`11pt` minimum HIG floor -> `13.5pt` ceiling, `--t-caption-2: 0.647rem`).
    public static func cappedCaption2(weight: Font.Weight = .medium) -> Font {
        scaledSystemFont(baseSize: 11.0, weight: weight, textStyle: .caption2)
    }

    // MARK: - Tabular / Monospaced-Digit Helpers (Timestamps, Counts, Timers & Invite Codes)

    /// Body (`17pt` base -> `21pt` ceiling) with `.monospacedDigit()` so numeric updates never shift horizontally.
    public static func monospacedBody(weight: Font.Weight = .regular) -> Font {
        cappedBody(weight: weight).monospacedDigit()
    }

    /// Semibold headline (`17pt` base -> `21pt` ceiling) with `.monospacedDigit()`.
    public static func monospacedHeadline(weight: Font.Weight = .semibold) -> Font {
        cappedHeadline(weight: weight).monospacedDigit()
    }

    /// Callout (`16pt` base -> `20pt` ceiling) with `.monospacedDigit()`.
    public static func monospacedCallout(weight: Font.Weight = .regular) -> Font {
        cappedCallout(weight: weight).monospacedDigit()
    }

    /// Subheadline (`15pt` base -> `18.5pt` ceiling) with `.monospacedDigit()`.
    public static func monospacedSubheadline(weight: Font.Weight = .regular) -> Font {
        cappedSubheadline(weight: weight).monospacedDigit()
    }

    /// Footnote (`13pt` base -> `16pt` ceiling) with `.monospacedDigit()`.
    public static func monospacedFootnote(weight: Font.Weight = .regular) -> Font {
        cappedFootnote(weight: weight).monospacedDigit()
    }

    /// Caption 1 (`12pt` base -> `15pt` ceiling) with `.monospacedDigit()` for row timestamps and badges.
    public static func monospacedCaption(weight: Font.Weight = .regular) -> Font {
        cappedCaption(weight: weight).monospacedDigit()
    }

    /// Caption 2 (`11pt` base -> `13.5pt` ceiling) with `.monospacedDigit()` for compact counts and ticks.
    public static func monospacedCaption2(weight: Font.Weight = .medium) -> Font {
        cappedCaption2(weight: weight).monospacedDigit()
    }

    /// Arbitrary base-size SF Pro font scaled up to the `21pt`-equivalent chrome ratio with `.monospacedDigit()`.
    public static func monospacedDigits(
        size: CGFloat,
        weight: Font.Weight = .medium,
        relativeTo textStyle: UIFont.TextStyle = .body
    ) -> Font {
        scaledSystemFont(baseSize: size, weight: weight, textStyle: textStyle).monospacedDigit()
    }

    /// Computes the capped point size matching `cappedRootSize(natural, DYNAMIC_TYPE_MAX)` in `steady.js:49-51`.
    public static func cappedChromePointSize(forBase baseSize: CGFloat) -> CGFloat {
        let scaleCeiling = DYNAMIC_TYPE_MAX / 17.0
        return (baseSize * scaleCeiling * 2.0).rounded() / 2.0
    }

    // MARK: - Internal Resolution & Thread-Safe CGFont Fallback Cache

    private static let fontCache = LockedCGFontCache()

    private static func clarinettaResourceStem(for weight: Font.Weight, italic: Bool) -> String {
        switch weight {
        case .ultraLight, .thin, .light:
            return italic ? "Clarinetta-LightItalic" : "Clarinetta-Light"
        case .regular:
            // Intentional stand-in per `public/css/fonts.css:35-39` (avoids duplicate BlackItalic twin)
            return italic ? "Clarinetta-MediumItalic" : "Clarinetta-Regular"
        case .medium:
            return italic ? "Clarinetta-MediumItalic" : "Clarinetta-Medium"
        case .semibold, .bold:
            return italic ? "Clarinetta-BoldItalic" : "Clarinetta-Bold"
        case .heavy:
            return italic ? "Clarinetta-ExtraBoldItalic" : "Clarinetta-ExtraBold"
        case .black:
            return italic ? "Clarinetta-BlackItalic" : "Clarinetta-Black"
        default:
            return italic ? "Clarinetta-MediumItalic" : "Clarinetta-Regular"
        }
    }

    private static func resolveBundledFont(stem: String, size: CGFloat) -> UIFont? {
        if let direct = UIFont(name: stem, size: size) {
            return direct
        }
        let condensedName = stem.replacingOccurrences(of: "-", with: "")
        if let condensed = UIFont(name: condensedName, size: size) {
            return condensed
        }
        // Dual registration & CGFont fallback: registers the bundled `.ttf`/`.otf` URL with CoreText
        // (`CTFontManagerRegisterFontURLs`) and instantiates directly from `CGFont` if needed.
        if let cgFont = fontCache.cgFont(forStem: stem) {
            if let registered = UIFont(name: stem, size: size) {
                return registered
            }
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            return ctFont as UIFont
        }
        return nil
    }

    private static func scaledSystemFont(
        baseSize: CGFloat,
        weight: Font.Weight,
        textStyle: UIFont.TextStyle,
        ceilingOverride: CGFloat? = nil
    ) -> Font {
        let uiWeight = uiFontWeight(from: weight)
        let baseFont = UIFont.systemFont(ofSize: baseSize, weight: uiWeight)
        let ceiling = max(baseSize, ceilingOverride ?? cappedChromePointSize(forBase: baseSize))
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont, maximumPointSize: ceiling)
        return Font(scaled)
    }

    private static func fallbackSerifUIFont(size: CGFloat, weight: Font.Weight, italic: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiFontWeight(from: weight))
        var traits: UIFontDescriptor.SymbolicTraits = italic ? [.traitItalic] : []
        if let serifDescriptor = base.fontDescriptor.withDesign(.serif) {
            if !traits.isEmpty, let styled = serifDescriptor.withSymbolicTraits(serifDescriptor.symbolicTraits.union(traits)) {
                return UIFont(descriptor: styled, size: size)
            }
            return UIFont(descriptor: serifDescriptor, size: size)
        }
        traits.insert(.traitUIOptimized)
        if italic, let italicDesc = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: italicDesc, size: size)
        }
        return base
    }

    private static func uiFontWeight(from weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}

private final class LockedCGFontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CGFont] = [:]
    private var missingStems: Set<String> = []

    func cgFont(forStem stem: String) -> CGFont? {
        lock.lock()
        if let existing = storage[stem] {
            lock.unlock()
            return existing
        }
        if missingStems.contains(stem) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let loaded = Self.loadCGFontFromBundle(stem: stem)

        lock.lock()
        defer { lock.unlock() }
        if let loaded {
            storage[stem] = loaded
            return loaded
        } else {
            missingStems.insert(stem)
            return nil
        }
    }

    private static func loadCGFontFromBundle(stem: String) -> CGFont? {
        let extensions = ["ttf", "otf"]
        let subdirectories: [String?] = [nil, "Fonts", "Resources/Fonts"]
        let candidateBundles: [Bundle] = [Bundle.main, Bundle(for: LockedCGFontCache.self)]

        for bundle in candidateBundles {
            for subdirectory in subdirectories {
                for ext in extensions {
                    if let url = bundle.url(forResource: stem, withExtension: ext, subdirectory: subdirectory) {
                        CTFontManagerRegisterFontURLs([url as CFURL] as CFArray, .process, true, nil)
                        if let provider = CGDataProvider(url: url as CFURL),
                           let font = CGFont(provider) {
                            return font
                        }
                    }
                }
            }
        }
        return nil
    }
}

extension View {
    /// Clamps Dynamic Type scaling on chrome bars, capsules, and vertical Duo rails to `DynamicTypeSize.xxLarge`
    /// (`21pt` body ceiling, matching `steady.js:20` `DYNAMIC_TYPE_MAX = 21`).
    public func cuvenCappedDynamicType() -> some View {
        self.dynamicTypeSize(...CuvenFonts.dynamicTypeCeiling)
    }

    /// Applies tabular monospaced digits so live timestamps, unread counts, and call timers never jitter horizontally.
    public func cuvenMonospacedDigits() -> some View {
        self.monospacedDigit()
    }
}
