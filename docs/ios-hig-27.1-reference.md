# Cuven Native iOS & iPhone Duo — Apple HIG & iOS 27.1 SDK Authoritative Reference

> **Document Path**: `docs/ios-hig-27.1-reference.md`
> **Target SDK & Toolchain**: `Xcode 27.1` (`/Applications/Xcode_27.1.app`, Build `27A9275`, Swift `6.4`) · `iphoneos27.1` / `iphonesimulator27.1` (`LC_BUILD_VERSION` **`sdk 27.1`**, `minos 26.0`)
> **Target Hardware**: **iPhone Duo** (`closed` `466×678pt`, `halfBook` `951×669pt` split, `halfLaptop` `669×951pt` tabletop, `open` `951×669pt` flat) & **Standard iPhone** (`iPhone 18 Pro` `402×874pt`, `iPhone 18 Pro Max` `440×956pt` / `956×440pt`, `iPhone 17` `393×852pt`)
> **Mandate (`ORIGINAL_REQUEST.md` & `PROJECT.md`)**: 100% Native SwiftUI + UIKit iOS application grounded in explicit **Apple Human Interface Guidelines** and **iOS 27.1 Apple Developer Documentation**, achieving **Beyond-Apple First-Party UI/UX Polish** while preserving **1:1 visual and behavioral fidelity with Cuven Web**.

---

## Section 1 — iOS 27.1 SDK (`iphoneos27.1`) & iPhone Duo Platform Foundations

### 1.1 Why `iOS 27.1 SDK` (`sdk 27.1`) Is Technically Gated & Mandatory

Per Apple's official *[Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)* and *[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)* (published September 9, 2026), iOS inspects the Mach-O `LC_BUILD_VERSION` load command (`sdk` field) of every app binary at launch to determine display geometry and system chrome behavior on iPhone Duo:

| Linked SDK in `LC_BUILD_VERSION` | System Behavior on iPhone Duo (Outer `466×678pt` & Inner `951×669pt`) | Status for Cuven |
|---|---|---|
| **`sdk <= 26.x`** (Xcode 26 or earlier) | App runs in a letterboxed/pillarboxed compatibility frame; cannot fill either iPhone Duo display. | **FORBIDDEN** |
| **`sdk 27.0`** (Xcode 27.0 / `iphoneos27.0`) | App resizes dynamically across outer and inner displays, **but the system still withholds the right-edge status bar & camera column outside the app scene** (`84–91pt` blank strip) and omits iOS 27.1 foldable APIs. | **INSUFFICIENT** |
| **`sdk 27.1`** (`Xcode_27.1.app` / `iphoneos27.1`) | **Full Native iPhone Duo Unlock**: Scene extends **edge-to-edge underneath the right-edge status bar, Dynamic Island, and camera column** on both displays; system automatically adapts navigation/tab/toolbar chrome to the vertical right-edge axis (`toolbarVerticalEdge`) and exposes `ReservedRegion`, `ArrangementView`, `onHingeChange(isEnabled:_:)`, and `toolbarVerticalBehavior(_:)`. | **MANDATORY** |

#### Deterministic Toolchain, Deployment Target & `Info.plist` Contract (`PROJECT.md` §1, §5)
1. **Xcode 27.1 Pinning on `runs-on: xcode-27`**:
   - On GitHub Actions `xcode-27` (`macOS 27.0.1` Arm64, Image `20261104.0337.1`), three Xcode versions coexist: `Xcode_27.app` (`27.0`), **`Xcode_27.1.app` (`27.1`, Build `27A9275`, Swift `6.4`, Apple Clang `21.0.0`)**, and `Xcode_27.2.app` (`27.2`).
   - CI **MUST** explicitly select `sudo xcode-select -s /Applications/Xcode_27.1.app` and pass `-sdk iphoneos27.1` (device `.ipa`) / `-sdk iphonesimulator27.1` (Simulator tests). Selecting `Xcode_27.2.app` stamps `sdk 27.2` instead of `sdk 27.1` and can hang `CoreSimulatorService` if mismatched with `27.1` runtimes.
2. **Dual-Simulator Runtime Strategy (`IPHONEOS_DEPLOYMENT_TARGET = 26.0` + `SDKROOT = iphoneos27.1`)**:
   - Mach-O `LC_BUILD_VERSION` records **two independent fields**: `sdk 27.1` (compile SDK — unlocks full iPhone Duo behavior on iOS 27.1) and `minos 26.0` (minimum OS deployment target).
   - Under `Xcode_27.1.app`, `com.apple.CoreSimulator.SimRuntime.iOS-27-1` provides **`iPhone Duo`**, while `com.apple.CoreSimulator.SimRuntime.iOS-27-0` provides standard iPhones (**`iPhone 18 Pro`**, **`iPhone 18 Pro Max`**, **`iPhone 17`**). Setting `IPHONEOS_DEPLOYMENT_TARGET = 26.0` makes all **`iOS 26.0+` Liquid Glass APIs** unconditionally available with zero `#available` boilerplate, runs the exact same test binary on **both** `iOS 27.0` standard iPhones and `iOS 27.1` `iPhone Duo`, and gates `iOS 27.1`-exclusive foldable symbols cleanly behind `if #available(iOS 27.1, *)`.
3. **Mandatory iOS 27 SDK `Info.plist` & Lifecycle Keys**:
   - **`UIApplicationSceneManifest` (`UIScene` lifecycle)**: Mandatory in iOS 27 SDK (*UIKit Release Notes*: *"Apps built with the latest SDK must adopt the scene-based life cycle or they fail to launch"*). Set `UIApplicationSupportsMultipleScenes = true` (`SwiftUI` `WindowGroup`) so iPhone Duo multitasking & Split View work natively.
   - **`UILaunchScreen`**: Mandatory dictionary key in `Info.plist` for iOS 27 SDK App Store validation; matches theme canvas (`#FFFFFF` light / `#000000` dark) for zero cold-start flash (`README.md:484-485`).
   - **`UIRequiresFullScreen = false`**: Required by *Preparing your app for iPhone Duo* so iOS dynamically resizes scenes across cover/inner displays and Split View halves.
   - **`UISupportedInterfaceOrientations`**: All 4 orientations (`UIInterfaceOrientationPortrait`, `PortraitUpsideDown`, `LandscapeLeft`, `LandscapeRight`) so `duoClosed` landscape (`678×466`), `duoHalfLaptop` (`669×951`), and `duoOpen` (`951×669`) transition seamlessly.
   - **No `UIDesignRequiresCompatibility`**: Ignored completely when linked against iOS 27 SDK (*Apple Developer Documentation*); Liquid Glass is always active.
4. **Mach-O `sdk 27.1` Binary Audit Commands**:
   - **macOS (`xcode-27` CI)**: `vtool -show-build Payload/Cuven.app/Cuven | grep -E "sdk 27\.1$"` and `otool -l Payload/Cuven.app/Cuven | grep -A 5 LC_BUILD_VERSION`.
   - **Linux (`llvm-objdump`)**: `llvm-objdump --macho --private-headers Payload/Cuven.app/Cuven` → asserts `cmd LC_BUILD_VERSION`, `platform ios`, `sdk 27.1`, `minos 26.0`.

---

### 1.2 Verbatim Official Apple DocC API Signatures (`iOS 27.1` & `iOS 26.0+`)

All declarations below are verified directly against Apple's official DocC JSON specifications (`developer.apple.com/tutorials/data/documentation/...`) for `iphoneos27.1`:

```swift
// ============================================================================
// A. iOS 26.0+ Liquid Glass APIs (Unconditional with deploymentTarget = 26.0)
// ============================================================================
public struct Glass {
    public static var regular: Glass { get }
    public static var clear: Glass { get }
    public static var identity: Glass { get }
    public func tint(_ color: Color?) -> Glass
    public func interactive(_ isEnabled: Bool = true) -> Glass
}

extension View {
    nonisolated public func glassEffect(
        _ glass: Glass = .regular,
        in shape: some Shape = DefaultGlassEffectShape() // Capsule by default
    ) -> some View

    nonisolated public func glassEffectID(
        _ id: (some Hashable & Sendable)?,
        in namespace: Namespace.ID
    ) -> some View

    @MainActor @preconcurrency public func glassEffectUnion(
        id: (some Hashable & Sendable)?,
        namespace: Namespace.ID
    ) -> some View

    @MainActor @preconcurrency public func glassEffectTransition(
        _ transition: GlassEffectTransition // .matchedGeometry, .materialize, .identity
    ) -> some View

    @MainActor @preconcurrency public func backgroundExtensionEffect() -> some View
}

@MainActor @preconcurrency public struct GlassEffectContainer<Content: View>: View {
    @MainActor @preconcurrency public init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    )
}

extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    nonisolated public static var glass: GlassButtonStyle { get }
    nonisolated public static func glass(_ glass: Glass) -> GlassButtonStyle
}
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle {
    @MainActor @preconcurrency public static var glassProminent: GlassProminentButtonStyle { get }
}

// UIKit Liquid Glass — @available(iOS 26.0, *) (Use with UIVisualEffectView(effect:))
@MainActor public class UIGlassEffect: UIVisualEffect {
    public init(style: UIGlassEffect.Style) // .regular, .clear
    public var isInteractive: Bool
    public var tintColor: UIColor?
}
@MainActor public class UIGlassContainerEffect: UIVisualEffect {
    public var spacing: CGFloat
}

// ============================================================================
// B. iOS 27.1 iPhone Duo Foldable, Hinge & Vertical Bar APIs
// ============================================================================

// 1. Fold Division & Camera/Status Occlusion Regions — @available(iOS 27.1, *)
public struct ReservedRegion: Identifiable {
    public struct Kind {
        public static var division: ReservedRegion.Kind { get }   // Hinge / fold split region
        public static var occlusion: ReservedRegion.Kind { get }  // Outer camera / active inner camera / status cluster
    }
    @frozen public struct QueryOptions: OptionSet {
        public static var includeInactive: ReservedRegion.QueryOptions { get }
    }
    public var id: ReservedRegion.ID { get }
    public var kind: ReservedRegion.Kind { get }
    public var frame: CGRect { get }
    public var margins: EdgeInsets { get }
    public var isActive: Bool { get }
}

extension GeometryProxy {
    @available(iOS 27.1, *)
    public func reservedRegions(
        kind: ReservedRegion.Kind,
        options: ReservedRegion.QueryOptions = [],
        layoutDirectionBehavior: LayoutDirectionBehavior = .mirrors
    ) -> [ReservedRegion]
}

// 2. Continuous Hinge Angle & Posture Stream — @available(iOS 27.1, *)
// APPLE DOC MANDATE: Use onHingeChange ONLY for continuous visual/sensory effects
// (e.g., crease binding shadow opacity), NEVER to compute pane layout bounds!
public struct DeviceHinge {
    public struct Status: Equatable, Sendable {
        public static var closed: DeviceHinge.Status { get }
        public static var partiallyOpen: DeviceHinge.Status { get }
        public static var fullyOpen: DeviceHinge.Status { get }
    }
    public var angle: Angle { get }        // Read via angle.degrees -> Double
    public var status: DeviceHinge.Status { get }
}

public struct DeviceHingeContext {
    public var hinge: DeviceHinge? { get }
}

extension View {
    @available(iOS 27.1, *)
    nonisolated public func onHingeChange(
        isEnabled: Bool = true,
        _ action: @escaping (DeviceHingeContext, DeviceHingeContext) -> Void // (oldContext, newContext)
    ) -> some View
}

// 3. Adaptive 2-Pane Duo Arrangement Containers — @available(iOS 27.1, *)
nonisolated public struct ArrangementView<Primary: View, Secondary: View>: View {
    nonisolated public init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    )
}
public struct SplitArrangementViewStyle: ArrangementViewStyle {
    public init()
    public func axes(_ axes: Axis.Set) -> SplitArrangementViewStyle
}
public struct OverlayArrangementViewStyle: ArrangementViewStyle {
    public init()
    public func axes(_ axes: Axis.Set) -> OverlayArrangementViewStyle
}
extension View {
    @available(iOS 27.1, *)
    nonisolated public func arrangementViewStyle(_ style: some ArrangementViewStyle) -> some View
    @available(iOS 27.1, *)
    nonisolated public func splitArrangementLayoutRatio(_ ratio: CGFloat?) -> some View
    @available(iOS 27.1, *)
    nonisolated public func splitArrangementLayoutSize(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil
    ) -> some View
}

// 4. Vertical Toolbars, Overflow Priority & Sheet Placement — @available(iOS 27.0 / 27.1, *)
extension EnvironmentValues {
    @available(iOS 27.1, *)
    public var toolbarVerticalEdge: HorizontalEdge? { get } // Non-nil (.leading / .trailing) when system bar is vertical
}
extension View {
    @available(iOS 27.1, *)
    nonisolated public func toolbarVerticalBehavior(_ behavior: ToolbarVerticalBehavior) -> some View // .automatic, .disabled
    @available(iOS 27.1, *)
    nonisolated public func toolbarVerticalCompressionBehavior(_ behavior: ToolbarVerticalCompressionBehavior) -> some View // .automatic, .prefersTabBar, .prefersToolbarItems
    @available(iOS 27.0, *)
    nonisolated public func presentationPlacement(_ placement: PresentationPlacement) -> some View // .automatic, .center, .leading, .trailing
}
extension ToolbarContent {
    @available(iOS 27.1, *)
    nonisolated public func axisBehavior(_ behavior: ToolbarItemAxisBehavior) -> some ToolbarContent // .automatic, .horizontalOnly, .verticalPreferred
    @available(iOS 27.0, *)
    @MainActor @preconcurrency public func visibilityPriority(_ priority: ToolbarItemVisibilityPriority) -> some ToolbarContent // .high, .standard, .low
}
@available(iOS 27.0, *)
nonisolated public struct ToolbarOverflowMenu<Content: View>: ToolbarContent {
    public init(@ViewBuilder content: () -> Content)
}
extension ToolbarItemPlacement {
    @available(iOS 27.0, *)
    public static let topBarPinnedTrailing: ToolbarItemPlacement
}

// 5. UIKit Equivalents — @available(iOS 27.1, *)
// UIView.reservedRegions(kind:options:) -> [UIView.ReservedRegion]
// UIHingeInteraction(updateHandler:), UIHinge (angle: CGFloat, status: UIHinge.Status)
// UIArrangementViewController, UISplitArrangement, UIOverlayArrangement
// UITraitCollection.verticalBarEdge: UIVerticalBarEdge (.unspecified, .leading, .trailing)
// UIViewController.preferredVerticalBarBehavior: UIVerticalBarBehavior (.automatic, .disabled)
// UISheetPresentationController.preferredPlacement (iOS 27.0+): .automatic, .center, .leading, .trailing
```

#### Zero-Hallucination Swift 6.4 Compiler Rules
1. **Two-Argument `onHingeChange`**: Always write `.onHingeChange { oldCtx, newCtx in guard let h = newCtx.hinge else { ... } }` — a 1-parameter closure fails compilation.
2. **`DeviceHinge.Status` Is a Struct, NOT an Enum**: Compare `h.status == .partiallyOpen` (or `switch h.status` with a mandatory `default:` branch) and read `h.angle.degrees` separately.
3. **Mandatory `kind:` Argument Label**: Always call `proxy.reservedRegions(kind: .division)` / `proxy.reservedRegions(kind: .occlusion)`.
4. **Chain `.interactive()` & `.tint(_:)` on `Glass`**: Write `.glassEffect(.regular.interactive(), in: .capsule)` — `glassEffect` has **no** `interactive:` or `isEnabled:` parameter.
5. **Never Branch on `UIDevice.current.userInterfaceIdiom` or `UIScreen.main`**: `UIScreen.main` is deprecated in iOS 27 and iPhone Duo reports `.phone` idiom on both displays.

---

### 1.3 Six Canonical `DuoPosture` States, Safe Areas & Zero-Reflow Column Math (`DuoLayoutMetrics`)

Cuven models the entire primary workspace as a **single 4-column horizontal sliding strip** (`0: Sidebar | 1: ChatList | 2: Thread | 3: Artifact`, `public/js/ui/strip.js:20`, `public/js/ui/columns.js:19-88`) mapped across the 6 canonical `DuoPosture` states in `PROJECT.md` §5.1:

| `DuoPosture` (`CuvenCore`) | Logical Viewport (`pt`) | System Safe Area Insets (`pt`) | Active Columns & Exact Widths | Bar Axis & Control Placement | Apple HIG & Repo Basis |
|---|---|---|---|---|---|
| **`.iPhoneCompact`** | `390×844` / `393×852` / `402×874` / `440×956` (`< 700pt`) | Top `~59–62` (Dynamic Island), Bottom `34` (Home), Left/Right `0` | **1 col** (`100%` width; page margin `16pt` `<430pt`, `20pt` `≥430pt`) | **Horizontal**: `56pt` floating Liquid Glass bottom dock (`bottom = max(safeBottom, 16pt)`); `PagesCapsuleView` hidden | *[HIG: Layout]*; `tokens.css:238`, `duo-layout.css:1-60` |
| **`.iPhoneSplit`** | `956×440` (`iPhone 18 Pro Max` Landscape, `≥ 700pt`) | **Symmetric** Left `~62` & Right `~62` (`abs(right - left) <= 16` → **`hasRightSystemColumn = false`!**) | **2 cols**: `narrowWidth(956) = 344pt` leading \| `612pt` trailing | **Horizontal** `56pt` bottom dock on **both** columns; rows/notes/grids inset by `safeLeft` & `safeRight` | *[HIG: Split views]*; `viewport.js:35-36`, `README.md:76-77` |
| **`.duoClosed`** | Outer Cover: `466×678` (`1398×2034px @3x`) Portrait; `678×466` Landscape | Asymmetric Right `~90–91` (`safeRight >= 64 && abs(right - left) > 8`); Silent-mode bell pushes signal ring to `y = 158` | **1 col** (`466pt` full-bleed backdrop; content stops clear of `railContent`) | **Vertical**: `52pt` `DuoRailView` centered **`49pt` from physical right edge**; top reserve **`170pt`** portrait (`12pt` top / **`64pt`** bottom camera reserve in landscape, `rail.css:50`) + `52×282pt` `PagesCapsuleView` at foot | *[HIG: Designing for iPhone Duo › Outer display & Vertical controls]*; `rail.css:26,41,50`, `design-qa.md:975-979, 1184-1190` |
| **`.duoHalfBook`** | Inner Book Fold: `951×669` with vertical `.division` (`462 \| 28..40 \| 461`, or `475.5` crease when `status == .partiallyOpen`) | Right `~84` + active vertical `hingeDivisionRect` | **2 cols** meeting hinge (`leading = division.minX`, `gap = division.width`, `trailing = 951 - division.maxX`) + **`26pt` bilateral book-spine gradient shadow** (`5%` black light / `38%` black dark, modulated by `hinge.angle`) | **Hybrid**: Leading col = `56pt` horizontal bottom dock; Trailing col = `52pt` vertical `DuoRailView` (`118pt` top reserve) + `PagesCapsuleView`. Sheets/menus/calls stay strictly on originating half (`.leading` / `.trailing`) | *[HIG: Designing for iPhone Duo › Device poses & Sheets]*; `columns.js:36-41`, `posture.js:34-48`, `fold.js:1-77`, `design-qa.md:928-974` |
| **`.duoHalfLaptop`** | Inner Tabletop / Laptop Fold: `669×951` (or horizontal `.division` `top \| crease \| bottom`) | Active horizontal `hingeDivisionRect` (`width > height`) | **Top / Bottom Split** across crease: watched stage (`0 ..< division.minY`) above bend; touched controls (`division.maxY ..< height`) flat on table | **Horizontal** (inner portrait bars return horizontal per HIG). Thread: messages above, composer below; Call: remote video (`36pt` soft bottom fade) above, controls below; Lightbox: photo above, close/share/strip below (`520ms` smooth morph on pose turn) | *[HIG: Designing for iPhone Duo › Device poses]*; `posture.css:26-74`, `README.md:59-60` |
| **`.duoOpen`** | Inner Open Flat: `951×669` (`2853×2007px @3x`) *(alt grid `890×626`; inner upright `669×951` = 1 col horizontal bars)* | Asymmetric Right `~84` (under-display inner camera hides when inactive; Silent bell signal ring ends at `y = 105`) | **2 cols** (`zero` gap):<br>• `ChatList \| Thread`: **`342pt \| 609pt`** (`525pt` content + `84pt` rail)<br>• `Thread \| Artifact`: **`525pt \| 426pt`** (`342pt` details + `84pt` rail)<br>→ **`threadContentWidth == 525pt` constant (ZERO text reflow!)** | **Hybrid**: Leading col = `56pt` horizontal bottom dock; Trailing col = `52pt` vertical `DuoRailView` (**`118pt`** top reserve = `105 + 12pt`) + `PagesCapsuleView`. Sheets center on **physical screen midpoint (`475.5pt`)** clamped `8pt` clear of `84pt` right column (`max 520×680pt`) | *[HIG: Designing for iPhone Duo › Inner display & Split views]*; `columns.js:19-45`, `overlays.css:75-94`, `design-qa.md:832-835, 970-973, 1223-1229` |

#### Exact `DuoLayoutMetrics` Equations (`public/js/ui/columns.js`, `rail.css`, `strip.js`)
1. **Narrow Column & Constant-Width Thread Math**:
   $$\text{narrow}(W) = \min\!\Big(\lfloor W / 2 \rfloor,\; \text{round}\big(\text{clamp}(300,\; 0.36 \cdot W,\; 380)\big)\Big), \qquad \text{edge} = \text{clamp}(0,\; \text{safeRight},\; W - 2 \cdot \text{narrow})$$
   - When `activePairStartsAtThread == false` (`Sidebar|List` or `List|Thread`): `leading = narrow` (`342pt`), `trailing = W - narrow` (`609pt`), `threadContentWidth = trailing - edge` (`609 - 84 = 525pt`).
   - When `activePairStartsAtThread == true` (`Thread|Artifact`): `leading = W - narrow - edge` (`951 - 342 - 84 = 525pt`), `trailing = narrow + edge` (`342 + 84 = 426pt`), `threadContentWidth = leading` (`525pt`).
2. **Right-Edge Clock Centerline Alignment (`rail.css:35-45`, `design-qa.md:975-979`)**:
   - Measured on hardware, the status bar clock center sits **`48.2–48.5pt` (`49pt`) from the physical right edge** on **both** displays despite `safeRight` changing (`91pt` closed vs `84pt` open). Centering relative to `safeRight / 2` shifts outer controls `9pt` left of the clock!
   - `DuoRailView` (`railWidth = 52pt`) and `PagesCapsuleView` (`52×282pt`) anchor at `railTrailingInset = max(4, min(49, safeRight - 34) - 26)`.
3. **Stationary Counter-Translated `Back` Pill (`strip.js:71-120`, `design-qa.md:856-874`)**:
   - During `1`-column strip pan (`pos` continuous in `0...3`), pane `i`'s `Back` button applies horizontal offset `(pos - CGFloat(i)) * paneWidth` inside a pane-clipped container so `Back` stays physically stationary (`≤ 1pt` variance) while columns wipe underneath. In `2`-column `Thread | Artifact`, `Thread`'s `Back` hides because `Artifact`'s `Close` is the single unambiguous exit.

---

## Section 2 — Complete Component-by-Component Apple HIG + Developer API + Cuven Web Traceability Matrix

### 2.1 High-Level 10-Domain Apple HIG & iOS 27.1 SDK Grounding Overview

| Domain | Official Apple HIG Reference | Official Apple Developer API / Doc Reference | Cuven Web Source & Beyond-Apple Target |
|---|---|---|---|
| **1. iPhone Duo Dual-Display & Postures** | *[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)* (*Outer display*, *Inner display*, *Device poses*, *Dynamic layouts*) | *[Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)*; `GeometryProxy.reservedRegions(kind:options:)`; `ArrangementView`; `onHingeChange(isEnabled:_:)` (`iOS 27.1+`) | `columns.js:19-88`, `posture.js:1-69`, `posture.css:1-77`: 4-column strip, `duoHalfBook` (`26pt` spine shadow), `duoHalfLaptop` tabletop split, `duoOpen` zero-reflow `525pt` thread, `0.52s` (`damping 0.88`) divider spring. |
| **2. Vertical Side Rail & Page Capsule vs. 56pt Dock** | *[Designing for iPhone Duo #Vertical-controls](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo#Vertical-controls)*; *[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)*; *[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)* | `@Environment(\.toolbarVerticalEdge)`; `toolbarVerticalBehavior(_:)`; `axisBehavior(_:)`; `visibilityPriority(_:)`; `ToolbarOverflowMenu` (`iOS 27.0/27.1+`) | `rail.css:18-157`, `pages.css:1-96`, `bars.js:1-200`: `52pt` rail at `49pt` right centerline (`170pt`/`118pt` Silent-bell reserve) + 6-slot `PagesCapsuleView` (`Chats, Moments, Memories, Friends, You, Menu`); bottom-up priority overflow (`Back` never overflows). |
| **3. Liquid Glass, Paper Surfaces & Diffuse Glow** | *[Materials › Liquid Glass](https://developer.apple.com/design/human-interface-guidelines/materials)*; *[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)* | *[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)*; `Glass` (`.regular`, `.clear`, `.tint`, `.interactive`); `glassEffect(_:in:)`; `GlassEffectContainer` (`iOS 26.0+`) | `tokens.css:15-124`, `liquid.css:1-244`, `docs/style-spec.md:1-94`, `liquid-glass/*`: Paper `#FFFFFF`/`#F5F5F7` & OLED `#000000` with `0.5pt` hairlines; Liquid Glass strictly on floating chrome over `50%` frosted base; solid fallback on Reduce Transparency; 4-blob `ComposerGlowView`. |
| **4. Layout, Safe Areas & Concentricity** | *[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)*; *[Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)* | `GeometryProxy.safeAreaInsets`; `safeAreaInset(edge:content:)`; concentric corner math (`r_inner = r_outer - pad`) | `tokens.css:149-175`, `hig-audit.md:44-49, 159-168`: 6 concentric radius tiers (`8..30pt` + `Capsule`); symmetric Pro Max landscape (`62pt` L/R) distinguished from Duo right column; `composerHeight + 14pt` thread bottom clearance. |
| **5. Motion, Interruptible Springs & Frequency Tiers** | *[Motion](https://developer.apple.com/design/human-interface-guidelines/motion)*; *Designing Fluid Interfaces* | `Spring(response:dampingRatio:)`; `matchedGeometryEffect(id:in:)`; `@Environment(\.accessibilityReduceMotion)` | `spring.js:1-102`, `morph.js:1-95`, `docs/ux-plan.md:50-126`, `design-qa.md:407-445`: Daily actions ultra-light (`160ms` split chat switch, `0` bounce); spatial origin morphs rich (`+` → `×` tray, hero lightbox, avatar → Settings, stationary `Back`). |
| **6. Direct-Manipulation Gestures & Undo** | *[Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)*; *[Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo)* | `DragGesture`; interactive pan velocity projection (`project(v, 0.998)`); `rubberband(overshoot, dim, 0.55)` | `strip.js:262-347`, `corners.js:1-89`, `float.js:1-174`, `chatList.js:355-590`: 1:1 edge-swipe back, zero-bleed clipped swipe-to-delete (`55%` threshold + mid-flight re-grab + cancel safety + Undo), 4-corner/edge-stash PiP. |
| **7. Menus and Actions, Context Menus, Card Alerts & Sheets** | *[Menus and actions](https://developer.apple.com/design/human-interface-guidelines/menus-and-actions)*; *[Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)*; *[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)*; *[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)*; *[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)* | `presentationPlacement(_:)` (`iOS 27.0+`); `presentationDetents(_:)`; custom 1:1 lift overlay | `overlays.css:1-120`, `overlay.js:126-670`, `docs/ux-plan.md:221-250`, `design-qa.md:541-565, 697-710, 969-974`: `460ms` hold lifts exact `1:1` non-reflowed bubble over `26pt` blur with 6 tapbacks + `52pt`-row card (release never auto-selects!); physical-center (`475.5pt`) Duo sheets; dirty discard guards. |
| **8. Typography (`Clarinetta` + `21pt` Cap)** | *[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)* (*Custom fonts*, *Dynamic Type*) | `Font.custom(_:size:relativeTo:)`; `UIFontMetrics`; `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`; `.monospacedDigit()` | `fonts.css:1-113`, `steady.js:20,49-51`, `hig-audit.md:90-113`: 14 `Clarinetta` `.ttf` faces (`400i` → `MediumItalic`), `17pt` base capped at `21pt` (`11pt` floor), zero font bloat on Duo unfold (`≤27em` measure). |
| **9. Sensory Haptics & Synthesized Audio** | *[Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)* | `.sensoryFeedback(_:trigger:)`; `UIImpactFeedbackGenerator`; `UISelectionFeedbackGenerator`; `AVAudioEngine` | `haptics.js:1-34`, `tones.js:1-131`, `design-qa.md:647`: Gated by user `Haptics` preference; crisp selection ticks, `55%` swipe rigid impact, `450Hz` call ringback & `E5-G5-B5` / `E5→A4` chimes. |
| **10. Accessibility & WCAG AA Compliance** | *[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)* | `.contentShape(.rect)`; `.accessibilityLabel(_:)`; `@Environment(\.colorSchemeContrast)`; `@Environment(\.accessibilityReduceTransparency)` | `hig-audit.md:24-146`, `quality-bar.md:1-36`: Universal `≥44×44pt` hit targets, `≥4.5:1` text contrast (`#0062CC`, `#D70015`, `#007A4D`), High Contrast border/label boosts, VoiceOver single-step PiP expand & live announcements. |

---

### 2.2 Milestone-by-Milestone Component, API & Web Source Traceability Matrix (`M3`–`M12`)

Every canonical Swift component in `PROJECT.md` §5 is mapped below to its Apple HIG chapter, iOS 27.1 API, and exact Cuven Web implementation:

| Milestone & Swift Component (`PROJECT.md` §5) | Apple HIG & Developer API Basis | Cuven Web Source (`file:line`) | Native Behavioral Contract & Beyond-Apple Craft |
|---|---|---|---|
| **M3 · `CuvenAPIClient`, `CuvenWebSocketClient`, `BootCache`, `PersistentOutbox`, `AppStore`** | *URLSession*, `URLSessionWebSocketTask`, *Keychain Services*, *Background Tasks* | `src/hub.js:120-720`, `public/js/store.js:1-348`, `public/js/outbox.js:1-207`, `public/js/main.js:65-160` | Connects to `https://wechat.cuven.us` (`Origin` header + `cfm_session` cookie + `x-tz`), handles all 16 `/api/ws` realtime events (`hello, msg, read, keys, edit, react, presence, typing, profile, prefs, rooms-dirty, contacts-dirty, note, call, moment, moment-changed, moment-deleted`), boots frame-1 from `BootCache` (`snap:v1`), flushes offline `PersistentOutbox` in strict FIFO order with `(sender, room, localID)` idempotency, and provides deterministic `--uitest-demo` rich persona dataset (`Tokio, Coisini, Hong, Gang, Design Team, Alani, Sofie, Mira, Yueee`). |
| **M4 · `CuvenColors`, `CuvenFonts`, `cuvenLiquidGlass`, `ComposerGlowView`, `VoiceBeamView`, `CuvenBackdropView`, `cuvenAdaptiveModal`** | *HIG: Materials › Liquid Glass*, *Color*, *Typography*, *Sheets*; `Glass`, `.glassEffect(_:in:)`, `GlassEffectContainer`, `TimelineView`, `Canvas` | `tokens.css:1-449`, `liquid.css:1-244`, `backdrops.css:1-194`, `voice.css:1-60`, `ui/voice-beam.js:1-304`, `overlays.css:25-120` | Implements `Clear`/`Tinted` Liquid Glass over `50%` frost (`Reduce Transparency` solid fallback); `ComposerGlowView` (`Ocean, Dawn, Aurora, Off` 4-blob `17s/23s/29s/19s` sinusoidal drift, zero layout bleed); `VoiceBeamView` (7-lobe RMS-reactive additive bloom); 8 `BackdropPreset` surfaces (`mist, dawn, mint, sand, ocean, dusk, dots, night`); and `cuvenAdaptiveModal` (bottom `30pt` sheet w/ `.app` `0.965` scale recession in stack; `475.5pt` physical-center `520×680pt` card in `duoOpen`; half-confined in `duoHalfBook`; blurred Card Prompts w/ focus on `Cancel`). |
| **M5 · `StripContainer`, `DuoPostureMonitor`, `BottomDockView`, `DuoRailView`, `PagesCapsuleView`** | *HIG: Designing for iPhone Duo*, *Split views*, *Toolbars*; `reservedRegions(kind:)`, `onHingeChange`, `toolbarVerticalEdge`, `ToolbarOverflowMenu` | `ui/viewport.js:1-421`, `ui/posture.js:1-69`, `ui/columns.js:1-88`, `ui/strip.js:1-379`, `ui/bars.js:1-236`, `ui/pages.js:1-165`, `rail.css:1-157`, `pages.css:1-96` | Drives 4-column `120Hz` velocity-inheriting strip (`Spring(0.34, 1.0)`), `duoHalfBook ↔ duoOpen` divider glide (`Spring(0.52, 0.88)`), `56pt` horizontal dock w/ stationary `Back` pill, `52pt` `DuoRailView` (`49pt` right clock centerline, `170pt`/`118pt` Silent-bell reserve, bottom-up priority overflow + `BADGE_BOOST = +10`), and `52×282pt` 6-item `PagesCapsuleView` (`Chats, Moments, Memories, Friends, You, Menu` w/ `0.266s` gliding circular thumb, red count on `Friends`, red dot on `Moments`, in-place page cross-fade, auto-hidden on keyboard/single-pane Thread/Drawing). |
| **M6 · `AuthRootView`, `InviteCodeTrack`, `SidebarColumnView`, `OnboardingGuides` & `SkeletonShimmer`** | *HIG: Managing accounts*, *Text fields*, *Sidebars*, *Onboarding*, *Loading*; `TextContentType`, `FocusState` | `views/auth.js:1-139`, `ui/invite-code.js:1-77`, `views/sidebar.js:1-115`, `columns.css:5-62`, `ui/skeleton.js:1-58`, `ui/guides.js:1-183` | `Clarinetta` `CUVEN` wordmark (`0.34em` tracking), `Sign in` / `Create account` segmented capsule, password eye toggle (`44×44pt`), `"At least 6 characters"` hint on Register only, OTP-style segmented invite-code boxes backed by native pasteable `TextField`, and Demo button. `SidebarColumnView` (`"Home"` in `#1877F2`): profile card → `SettingsRootSheet` morph, scopes `All, Unread [green badge], Direct, Groups` w/ `#1877F2` SF Symbols, `Moments` & `Memories` links. `250ms`-delayed geometry-matched shimmer skeletons + 4-card Welcome sheet & 1-at-a-time coachmarks (`--uitest` quiet). |
| **M7 · `ChatListColumnView`, `NotesStrip`, `ForYouInsightsDeck`, `PinnedGrid`, `SwipeRow`, `FriendRequestsAndPeopleSheet`** | *HIG: Lists and tables*, *Search fields*, *Gestures*, *Undo and redo* | `views/chatList.js:1-968`, `views/people.js:1-422`, `views/insights.js:1-305`, `list.css:1-286`, `people.css:1-227`, `insights.css:1-172`, `src/insights.js:1-253` | `#1877F2` `"Messages"` title (hides header `Moments` icon when `PagesCapsuleView` visible); `24h` `60`-char **Notes** strip (`100pt` cells, `60pt` avatar + overlapping 2-line bubble w/ 2-dot tail, inline DM note-reply); self-appearing **For you** Smart Insights (`Plans, People, Photos, Weather` chips + dashed-rule action cards); gliding `#1877F2` filter pills + `Requests` red badge; **4-col even Pinned grid** (never straddles Duo fold!); left-swipe `Delete` clipped strictly to uncovered width (`0` corner bleed, `55%` rigid haptic + `1.14×` icon pop, mid-flight catch, cancel-safe, server `hidden: 1` + Undo); `460ms` long-press menu (`Mark Unread/Read, Pin, Mute, Delete`); `Suggested` (`Tap to chat`), `People you may know` (`Add → Requested`, `×` dismiss), unified `Friends` sheet, and scroll-restoring instant Search. |
| **M8 · `ConversationColumnView`, `CurvedTailBubbles`, `PhotoStack`, `LiftedTapbackMenu`, `HonkGhost`, `Composer`, `WordPickerExplainSheet`** | *HIG: Designing for iPhone Duo*, *Menus and actions*, *Context menus*, *Edit menus*, *Text fields*; `ScrollViewReader`, `matchedGeometryEffect` | `views/thread.js:1-2326`, `views/bubbles.js:1-263`, `views/composer.js:1-763`, `views/predict.js:1-214`, `views/explain-pick.js:1-438`, `views/explain.js:1-256`, `views/time-reveal.js:1-163`, `chat.css:1-158`, `thread.css:1-1219`, `docs/ux-plan.md:44-250` | `92pt` symmetric 3-col header (`Voice+Video` capsule left; centered `58pt` avatar + overlapping `Name · Status · (i)` pill). Sender runs (`5m`), Bezier foot-tail bubbles (`22pt` radius, `≤27em`), `1–6` jumbo emoji, AI keyword highlights (`≤3`), `@mention` picker & atomic backspace, `PhotoStack` (`2–6` fanned cards), collapsible missed-call group (`260ms` upward), `15m/5x` in-place `Edit` (stashing draft + version history sheet), `2m` `Unsend` tombstone, `68pt` left-drag timestamp reveal, `composerHeight + 14pt` bottom clearance, unread divider + `↓ N` / `@` jump pills, `180ms`-throttled **Honk live-typing ghost bubble** (isolated from AI & edits), `1:1` non-reflowed `460ms` lifted context menu + 6 tapbacks + double-tap `❤️` (touch-up anti-autoselect guard!), `1–5`-line frosted composer w/ `450ms` gray AI ghost completion (`Tab`/tap, IME-safe) + Whisper `16kHz` WAV mic dictation, and Unicode-safe word/CJK **Search & Explain** NDJSON streaming sheet. |
| **M9 · `MomentsRootView`, `MomentsProfileView`, `MomentsEditorView`** | *HIG: Scroll views*, *Collections*, *Images*, *Accessibility (ALT descriptions)*; `CoreImage` (`CIFilter`), `PhotosPicker` | `views/moments.js:1-794`, `views/moments-editor.js:1-582`, `moments.css:1-515`, `moments-editor.css:1-236`, `src/hub.js:880-1120` | Sky-blue `#0099FF`/`#4CC2FF` `"Moments"` header (frosted on scroll), `74pt` conic-gradient Story rings (`+person` badge for strangers), `4:5..1.91:1` edge-to-edge cards (`paging` multi-photo carousel w/ `n/N` pill + pips, `60%`-visible muted looping video w/ shared speaker toggle, frosted `Heart/Comment/Share` pills over photo, `96pt` double-tap heart, strict `Everyone` vs mutual-DM `Friends` privacy). Profile: full-bleed cover + `104pt` avatar + `Posts \| Media` (2-col aspect-preserving waterfall masonry). Full-page Editor: `2000`-char ring (`#FF9500` `<100`), `≤9` photos / `1` video w/ `90°` rotate, `Original·1:1·4:5·16:9` crop, **6 CoreImage filters** (`Original, Vivid, Warm, Cool, Mono, Fade` non-destructive), `+ALT` (`1000`-char → `✓ ALT`), `@Tag` (`≤10` friends), comment policy, `Schedule` (`1m..30d`), `200`-step Undo/Redo, and `"Discard this moment?"` guard. |
| **M10 · `ArtifactColumnView` (`RoomInfo` & `DrawingBoard`), `StickerPickerDrawerView`, `MemoriesRootView`, `FullscreenMediaLightboxView`** | *HIG: Apple Pencil and Scribble*, *Sheets*, *Collections*, *Images*; `Canvas`, `Zoomable` pinch/pan | `views/artifact.js:1-104`, `views/draw.js:1-295`, `views/draw-guard.js:1-57`, `views/stickers.js:1-341`, `views/memories.js:1-183`, `views/viewer.js:1-542`, `draw.css:1-227`, `memories.css:1-101` | Column 3 hosts **Room Info** (`#1877F2` icons, per-chat Smart Insights, Mute/Pin, Group members, Leave/Delete) OR **Drawing Board** (sketch beside live chat on unfolded Duo!): `Plain / Lines / Grid` multiply paper (excluded from exported white PNG), pen-rack dock w/ **5 illustrated tips** (`Pen` velocity-smoothed, `Marker`, `Highlighter` uniform `35%` offscreen layer so crossings never darken, `Pencil`, `Eraser` — active pen rises higher w/ color nib & size), 5 swatches + wheel (`44pt` targets + VoiceOver names), `200`-step Undo/Redo, Duo vertical rail mode (`Close`, symbol `Send`, `Undo/Clear` capsule), and `"Discard this drawing?"` guard. **Stickers**: 14 Telegram packs (`WebP`, `WebM` video, `.tgs` Lottie viewport-gated), `120ms` zero-flash decode pipeline. **Memories**: monthly flashback slideshow hero + **4-col even square grid** + search/filter. **Lightbox**: hero morph, `1×–4×` focal zoom, `1:1` drag-dismiss, `duoHalfLaptop` split. |
| **M11 · `CallOverlayContainerView`, `WebRTCSFUClient`, `CallKit` & `CallPiPTile`** | *HIG: Designing for iPhone Duo*, *CallKit*, *AVAudioSession* (`.playAndRecord`, `.allowBluetooth`, `.defaultToSpeaker`) | `views/call.js:1-1483`, `src/call.js:1-527`, `ui/float.js:1-174`, `ui/corners.js:1-89`, `ui/tones.js:1-131`, `call.css:1-422` | Cloudflare Realtime SFU client (`POST /rtc/sessions/new` w/ empty body, serialized `publish → pull → renegotiate`, port-53 TURN filter + STUN fallback, `45s` ring + `2.5s` push fallback, synthesized `450Hz` ringback & `E5-G5-B5` / `E5→A4` chimes). Full-column dark glass UI: custom Call Backdrop (`56pt` fade + `112pt` blur beside Duo status col), top pill (`avatar + tabular timer + name + minimize`), `104×150pt` full-bleed self-preview, voice-level `call-ring` until live unmuted video arrives, bottom dark glass capsule (`Camera, Flip, Mute [Magic Replace slash], Red Hangup`). `duoHalfLaptop` places remote video above fold & controls below. Back on folded full-screen minimizes to PiP (never declines incoming ring!); PiP throws to 4 corners (`0.998` projection, `Spring(0.38, 0.84)`) or stashes off-edge (`0.990` projection, `28–44pt` handle; single-step expand on VoiceOver). |
| **M12 · `ProfileAvatarCoverEditorSheet`, `SettingsRootSheet`, `AIMemoryRoutineView`, `QuickReplyBanner` & `CuvenTests`** | *HIG: Settings*, *Privacy*, *Notifications*; `UNUserNotificationCenter`, `XCTest` | `views/avatar-editor.js:1-372`, `ui/framing.js:1-77`, `views/sheets.js:1-474`, `views/memory.js:1-198`, `src/routine.js:1-331`, `views/banner.js:1-214` | **Avatar/Cover Editor**: `×` / `Avatar \| Cover` / `✓` glass header; `232pt` zero-gap `1×–4×` cropper (`512×512` JPEG) + `8` recent avatars + `8` cover presets; **whole sheet dynamically tints** to desaturated photo average (`L=80%` light / `L=17%` dark, live-updating on theme toggle, preserving avatar URL if image load fails offline). **Settings**: Appearance (`System/Light/Dark`), Liquid Glass (`Clear/Tinted` + Reduce Transparency), Composer Glow, Motion, Haptics, live `Screen Posture` readout, Call Backdrop, Read Receipts (`sharesReceipts` symmetric), Password (`epoch` global revoke), and **AI Memory & Routine** (`04:00` day boundary, `45`-day half-life, `24h` histogram w/ quiet hours & current hour marker, wake/sleep medians `≥2` days, style words `≥2` own msgs, confirm-to-forget). **Top Banner**: pull-down (`≥34pt`) inline quick-reply (`15s` timer paused while typing). |

---

## Section 3 — Beyond-Apple Craft, Design Tokens, Motion Physics & Edge-Case Invariants

### 3.1 Authoritative Design Tokens (`CuvenColors`, `CuvenFonts`, Concentric Radii & Glows)

#### A. Semantic Color Palette (`public/css/tokens.css:14-449`, `docs/style-spec.md:71-94`, `chat.css:86,103,142`, `columns.css:54,74`, `list.css:53`, `PROJECT.md` §1 & §5.3)

| `CuvenColors` / CSS Token | Light Mode | Dark Mode (`OLED Pure Black`) | High Contrast (`colorSchemeContrast == .increased`) | Exact Usage & Token Reconciliation Note |
|---|---|---|---|---|
| `canvas` / `paperBackground` | `#FFFFFF` / `#F5F5F7` | `#000000` / `#000000` | `#FFFFFF` / `#000000` | Conversation plain paper canvas (`--wallpaper: #FFFFFF`/`#000000`) & grouped sheet background (`--paper`). |
| `elevatedSurface` / `field` | `#FFFFFF` / `#F2F2F5` | `#121214` (card `#1C1C1E`) / `#111113` | `#FFFFFF` / `#1C1C1E` | Cards, grouped cells, floating thread header pill, recessed search/input wells. |
| `inkPrimary` / `onInk` | `#000000` (label `#0B0B0D`) / `#FFFFFF` | `#F5F5FA` / `#000000` | `#000000` / `#FFFFFF` | Primary text (`>18:1`), primary CTA capsules (`Sign in`, `Post`, `Add`), active Composer **`Send`** circle (`chat.css:142`). |
| `inkSecondary` / `labelTertiary` | `#6E6E73` / `#8E8E93` | `rgba(240,240,250,0.60)` / `0.34` | `#3A3A3C` / `#6C6C70` (dark `0.80` / `0.60`) | Subtitles, timestamps, placeholders (`≥4.9:1` standard, `>7:1` High Contrast, `tokens.css:428-448`). |
| `hairlineSeparator` / `line` | `#E5E5EA` / `rgba(60,60,67,0.22)` | `rgba(240,240,250,0.13)` / `0.16` | `#C7C7CC` / `rgba(240,240,250,0.30)` | `0.5pt` (`1px` physical `@2x/@3x`) crisp borders replacing heavy drop shadows. |
| `sidebarBlue` / `fbBlueTitle` | `#1877F2` | `#1877F2` (titles `#2D88FF`) | `#0062CC` / `#409CFF` | Sidebar scope icons, Room Info icons, `"Messages"` & `"Home"` large titles, Thread `(i)` button, active filter thumb. |
| `momentsSkyTitle` | `#0099FF` | `#4CC2FF` | `#0062CC` / `#64D2FF` | `"Moments"` feed wordmark (`tokens.css:62,285`). |
| `outgoingBubble` / `Text` | **`#18181B`** (`PROJECT.md` §1) *or* **`#1877F2`** (`chat.css:103`) / `#FFFFFF` | **`#27272A`** (`PROJECT.md` §1) *or* **`#1877F2`** (`chat.css:103`) / `#FFFFFF` | High-alpha `#FFFFFF` (`0.88` meta) | **Unified Token Note**: `PROJECT.md` §1 specifies `#18181B`/`#27272A` dark ink outgoing bubbles (matching `ORIGINAL_REQUEST.md:26` `"墨色气泡与弯尾巴"`), while live `chat.css:103` sets `--bubble-out: #1877F2`. Centralize in `CuvenColors.outgoingBubble` (defaulting to `#18181B`/`#27272A` per `PROJECT.md` §1 with `#FFFFFF` text & read ticks, optionally selectable w/ `#1877F2` Classic Blue). |
| `incomingBubble` / `Text` | `#F0F0F2` (`#F4F4F5`) / `#111B21` | `#232626` / `#E9EDEF` | `+ 1px` `hairlineSeparator` | Incoming message bubble (`>15:1` text contrast). |
| `onlineGreen` / `badgeStrong` | Dot `#34C759` / Badge `#007A4D` (`#FFF` `5.4:1`) | Dot `#30D158` / Badge `#00C357` (`#000` `8.9:1`) | `#006840` / `#00D662` | Online presence indicator & unread count badges (`tokens.css:47-52, 275-279`). |
| `dangerRed` / `warningAmber` | Fill `#FF3B30`, Text `#D70015` (`5.4:1`) / Fill `#FF9500`, Text `#C93400` (`5.3:1`) | `#FF453A` / `#FF9F0A` | `#D70015` / `#FF6961` | Accessible system text variants (`tokens.css:38-43`) guaranteeing WCAG AA `≥4.5:1` on words while keeping vibrant fills on icons/buttons; accessible link text `#0062CC` (`5.8:1`) / `#0A84FF`. |

#### B. Liquid Glass, Composer Frost & 4-Blob Diffuse Glow (`tokens.css:98-124`, `liquid.css:203-244`, `thread.css:1177-1212`)
- **Floating Chrome Frosted Base**: `rgba(236,236,240,0.50)` (Light) / `rgba(72,72,78,0.50)` (Dark), `14pt` base blur + iOS 26/27.1 `.glassEffect(mode == .clear ? .clear.interactive() : .regular.interactive(), in: shape)` + `0.5pt` specular rim (`rgba(255,255,255,0.95)` light / `0.20` dark). Under `accessibilityReduceTransparency` or `colorSchemeContrast == .increased`, switches to opaque `#FFFFFF` / `#121214` + `1px` `hairlineSeparator`.
- **Non-Refractive Composer / Mic / Jump Pill Frost (`liquid.css:207-226`)**: `rgba(248,248,250,0.68)` (Light) / `rgba(44,44,48,0.62)` (Dark), `24pt` blur, `1.6×` saturation — zero lens distortion under typed text.
- **4-Blob `ComposerGlowView` Palettes** (drifting on `17s / 23s / 29s / 19s` cycles + `11s / 13s / 15s` breathe, `1.25×` alpha in Dark Mode, strictly `.clipped()`, static under Reduce Motion):
  - `.ocean` *(default)*: `rgba(38,128,140,0.70)`, `rgba(96,176,198,0.60)`, `rgba(150,210,212,0.50)`, `rgba(70,120,200,0.45)`
  - `.dawn`: `rgba(255,118,92,0.62)`, `rgba(255,186,104,0.56)`, `rgba(255,160,186,0.45)`, `rgba(240,120,170,0.40)`
  - `.aurora`: `rgba(102,90,255,0.58)`, `rgba(56,206,168,0.55)`, `rgba(184,110,255,0.42)`, `rgba(60,170,255,0.40)`

#### C. `Clarinetta` Font Asset Pipeline, Dynamic Type `21pt` Cap & Concentric Geometry
- **`.woff2` → `.ttf` Conversion & Duplicate-Italic Fix (`public/fonts/`, `fonts.css:35-39`, `test/fonts.test.js`)**: iOS `UIAppFonts` requires `.ttf`/`.otf` (CoreText ignores `.woff2`). Decompress all `Clarinetta-*.woff2` files into `ios/Cuven/Resources/Fonts/*.ttf` **and map Regular Italic (`400i`) to `Clarinetta-MediumItalic.ttf`** because `Clarinetta-RegularItalic.woff2` (`53,940 B`) is byte-identical to `Clarinetta-BlackItalic.woff2` (`53,940 B`)!
- **Type Scale & `DYNAMIC_TYPE_MAX = 21pt` (`steady.js:20,49-51`, `hig-audit.md:108`)**: `LargeTitle 34`, `Title1 28`, `Title2 22`, `Title3 20`, `Headline 17 semibold`, `Body 17`, `Callout 16`, `Subhead 15`, `Footnote 13`, `Caption1 12`, `Caption2 11` (**hard minimum `11pt`**; chrome/root Dynamic Type clamped at **`21pt` max body size** so `56pt` docks, `52pt` rails, and `76pt` rows never clip; `.monospacedDigit()` on all times, counts, and timers; zero font enlargement on Duo unfold).
- **Concentric Radii & Bezier Bubble Tails (`tokens.css:158-170`, `chat.css:109-126`)**:
  - Radii: `8pt` (`xs`), `12pt` (`s`), `18pt` (`m`/card/row), `22pt` (bubble) / `23pt` (`l`/tile), `26pt` (`xl`/menu/page-capsule), `30pt` (`sheet`), `999pt` (`Capsule`); nested elements obey `r_inner = max(0, r_outer - padding)`.
  - Curved foot tail on `.last` text bubble of a run (`12×16pt` flush `Path`, tightening corner to `6pt`): Incoming (`x = -7pt`) `M12 0 C12 8 7.5 14 0 16 L12 16 Z`; Outgoing (`x = +7pt`) `M0 0 C0 8 4.5 14 12 16 L0 16 Z`.

---

### 3.2 Motion Physics, Spring Constants, Velocity Projection & Haptics (`CuvenSprings`, `CuvenHaptics`)

#### A. Analytical Springs & Gesture Projection Equations (`public/js/ui/spring.js`, `strip.js`, `corners.js`, `float.js`, `tokens.css:184-229`)
1. **Canonical `CuvenSprings` Parameters (`PROJECT.md` §5.3 — `Animation.spring(response:dampingFraction:)` / `Spring(response:dampingRatio:)`)**:
   - `stripSlide`: `response: 0.34, dampingFraction: 1.0` (`dampingRatio: 1.0`) — critically damped, inherits finger velocity (`-vx / step`), zero overshoot (`strip.js:162`).
   - `sheetPresent`: `response: 0.40, dampingFraction: 0.86` (`dampingRatio: 0.86`) — adaptive bottom sheet (`30pt` radius + `.app` `0.965` scale recession) & Duo centered card presentation (`overlays.css:25-94`).
   - `bubblePop` (`bouncy` `~403ms` / `460ms` send): `response: 0.40, dampingFraction: 0.78` (`dampingRatio: 0.78`) — outgoing bubble rise (`translateY(26pt) scale(0.90) → identity`, `chat.css:146-155`), double-tap `❤️` burst (`560ms`), lifted context-menu `0.97 → 1.0` rebound (`docs/ux-plan.md:247`).
   - `railMorph` (`smooth` `~367ms`): `response: 0.36, dampingFraction: 0.96` (`dampingRatio: 0.96`) — `GlassEffectContainer` metaball merge/split, `BottomDockView ↔ DuoRailView` axis transition, medium surface glides (`tokens.css:202-215`).
   - `pressBounce` (`snappy` `~266ms` release): Touch-down `0ms` delay on buttons (`70ms` / `10pt` slop on scrollable rows) → `scale(0.98)` in `100ms`, release `response: 0.26, dampingFraction: 0.85` (`190–266ms` spring, also used for filter/segmented/`PagesCapsuleView` active thumb & reaction pill pop).
   - `duoDividerGlide`: `response: 0.52, dampingFraction: 0.88` (`dampingRatio: 0.88`) — smooth physical hinge settle across `duoHalfBook ↔ duoOpen` (`strip.js:226`).
   - `pipThrow`: `response: 0.38, dampingFraction: 0.84` (`dampingRatio: 0.84`) — subtle organic cushion into safe-area corner or edge stash (`float.js:59`).
2. **Velocity Projection & Rubberband Math (`VelocityProjector`)**:
   $$\text{project}(v,\; d = 0.998) = \frac{(v / 1000) \cdot d}{1 - d}, \qquad \text{rubberband}(\Delta,\; L,\; c = 0.55) = \text{sign}(\Delta) \cdot \frac{|\Delta| \cdot L \cdot c}{L + c \cdot |\Delta|}$$
   - **Strip Interactive Back-Swipe (`strip.js:332`)**: Commits back iff `!cancelled && (dx + project(vx, 0.998) > step * 0.5 || vx > 900)`; `cancel` / scene backgrounding **always** restores current column.
   - **Call PiP Corner vs. Edge Stash (`corners.js:60-69`)**: If `at.x + project(vx, 0.990) + width/2` crosses `edge.left` or `edge.right`, stashes off-screen with `28–44pt` peek handle; otherwise snaps to `nearestCorner` of `at + project(v, 0.998)`.
   - **Mid-Flight Catch / Interruption & Immediate Hit-Test Release**: Every animated view (4-column strip pan, swipe-to-delete row, sheet pull-down, PiP throw, Duo divider glide) remains 1:1 re-grabbable mid-flight from its live presentation value and instantaneous velocity, and dismissing overlays/sheets releases underlying hit-testing on frame 1 of exit (`spring.js:26-69`, `design-qa.md:295, 788`).
   - **Reversible Deformation & Spatial Origin Morphing (`ui/morph.js:1-95`, `ui/liquid-glass/buttons.js:1-160`, `docs/ux-plan.md:66-126`, `README.md:47-49`)**: (a) Liquid Glass buttons deform from `50%` circle to `42%` squircle bead with touch-origin specular glare and reverse smoothly if released early; (b) Composer `+` rotates `45° → ×` while the attachment tray grows from its rect (tapping mid-bloom reverses from current progress), and `+ ↔ Send ↔ ✓` cross-scales inside a fixed `44pt` slot without shifting text or losing focus; (c) Composer pill grows smoothly `1 → 5` lines from `Capsule` into concentric rounded rect; (d) Hero clip morphs (`Bubble/Grid ↔ FullscreenMediaLightboxView`, `Avatar ↔ SettingsRootSheet`, `duoHalfLaptop ↔ duoOpen`) reverse seamlessly mid-transition with zero state snap.

#### B. SF Symbols 7 & Haptics Contract
- **SF Symbols 7**: `play.fill ↔ pause.fill` uses `.contentTransition(.symbolEffect(.replace.downUp))`; `mic.fill ↔ mic.slash.fill` & `video.fill ↔ video.slash.fill` use `.symbolEffect(.replace.magic(fallback: .downUp))`; incoming call buttons pulse `.symbolEffect(.bounce, options: .repeating, isActive: isRinging)`; reconnecting banner runs `.symbolEffect(.variableColor.cumulative)`; mute badge uses `.appear`/`.disappear`; routine toolbar taps **never** bounce (`design-qa.md:190-196, 439`).
- **Haptics (`CuvenHaptics`, gated by `prefs` / `ui:haptics`)**: `.selectionChanged()` on Page Capsule, scope, and segmented switches; `.rigidImpact()` when row left-swipe crosses `55%` delete threshold & on `460ms` message lift; `.softImpact()` on double-tap `❤️`; `.success()` / `.error` notification feedback on call connect & retry failure.

---

### 3.3 Accessibility & All 30 Critical Edge-Case Invariants

#### Universal Accessibility Gates (`docs/hig-audit.md`, `docs/quality-bar.md`)
- **`≥ 44 × 44 pt` Hit Targets**: Enforced on every interactive control (`30pt` swatches, `36pt` `Add`/`×` pills, `(i)` icon, `+ALT` badge expand hit bounds via `.frame(minWidth: 44, minHeight: 44).contentShape(.rect)`).
- **`Reduce Motion` (`accessibilityReduceMotion` + Settings)**: Replaces all spatial translations, scales, springs, symbol bounces, composer glow motion, and video/Lottie sticker playback with `≤ 100–160ms` opacity cross-fades.
- **`Reduce Transparency` & `Increase Contrast`**: Replaces translucent Liquid Glass/frost with solid opaque surfaces + `1px` borders, and boosts secondary/tertiary labels & hairlines (`≥ 4.5:1` text, `≥ 3:1` UI).
- **Complete VoiceOver Semantics**: Localized labels & `.isSelected` traits on all icons, swatches, pens, and tabs; live announcements on incoming call, message unsent, send failure, and PiP state changes; VoiceOver activation on stashed PiP expands directly to full-screen in one step (`P2-12`).

#### 30 Mandatory Edge-Case Invariants (Verified Against Repo Tests & `design-qa.md`)
1. **`Xcode_27.1.app` Lock**: Never select `Xcode_27.2.app` on `xcode-27` when targeting `sdk 27.1`; filter Simulator runtimes to `version <= 27.1`.
2. **Dual-Runtime Deployment Target**: Keep `IPHONEOS_DEPLOYMENT_TARGET = 26.0` with `-sdk iphoneos27.1` so builds install on both `iOS 27.0` standard iPhone Simulators and `iOS 27.1` `iPhone Duo` Simulator.
3. **Pro Max Symmetric Landscape (`956×440pt`, `~62pt` L/R)**: `abs(safeRight - safeLeft) <= 16` MUST NOT activate `DuoRailView`; use 2-col split with horizontal docks.
4. **Silent Mode Bell in Duo Right Column**: Reserve `170pt` top (outer portrait) and `118pt` top (inner split) so `Back` / `Call` never collide with lowered clock & signal ring.
5. **Right Clock Centerline (`49pt`)**: Anchor `DuoRailView` & `PagesCapsuleView` `49pt` from physical right screen edge, not `safeRight / 2`.
6. **Zero-Reflow `525pt` Thread**: Sliding `List|Thread` (`342|609`) ↔ `Thread|Artifact` (`525|426`) keeps `threadContentWidth == 525pt` so not a single chat line re-wraps.
7. **Zero-Gap Segments**: Touching segments (`0pt` gap) trigger `duoHalfBook` **only** when `DeviceHinge.Status == .partiallyOpen`, never when flat `.fullyOpen`.
8. **Fold/Unfold Mid-Draft Continuity**: Preserves active room, exact draft text, cursor selection, keyboard focus, scroll anchor, and multi-line composer height.
9. **Width Resize vs. Keyboard**: Any viewport change where `width` changes is a fold/rotation, never software keyboard (`kb` triggers on height-only shrink).
10. **CJK IME Composition**: Freeze `+ ↔ Send` morph and block `Enter`-to-send while `markedTextRange != nil` (`isComposing`).
11. **Whitespace / Zero-Width Input**: Spaces, `\n`, `\u3000`, and `\u200B-\u200D`/`\uFEFF` keep `Send` inactive.
12. **Long-Press Release Guard**: Lifting the finger that held `460ms` to open the lifted message menu MUST NEVER select/trigger any menu row or reaction shifted under the thumb.
13. **Revoke While Menu Open**: Immediately dismisses context menu, announces `"Message unsent"`, and restores focus safely.
14. **Revoke Run Split & Badge**: Tombstone splits neighboring sender runs (updating tails/avatars), never bumps chat to top, and decrements unread count.
15. **Edit Limits & Draft Stash**: Edits capped at `15 min` & `5` edits; stashes current unsent draft before editing and restores it on save/cancel/room switch; suppresses Honk typing during edit.
16. **Read Receipt vs. Failed/Sending**: `deliveryState` checks `.sending`/`.failed` before `peerRead` so unsent bubbles never show `"Read"` ticks.
17. **Offline `localID` Idempotency**: Queued messages retry in FIFO order with stable `localID` so reconnects never create duplicate bubbles.
18. **Unrecoverable Media Blob**: Shows `"Photo lost · Choose again"` inside bubble bounds if local binary was purged before upload completed.
19. **Swipe-to-Delete Zero Corner Bleed & Cancel Safety**: Red `Delete` background clips strictly to uncovered width (`0pt` at rest around `18pt` corners) and **never** deletes on `cancel`/backgrounding even past `55%`.
20. **Hidden Chat Resurrection**: Deleting/hiding a chat sets `hidden = 1`; an incoming message automatically clears `hidden` and surfaces the room with full history.
21. **Strict Mutual-DM `"Friends"` Moments Privacy**: Unilateral 1-way DM creation does NOT grant access to `audience == "friends"` Moments (requires accepted contact or 2-way messages).
22. **Scheduled Moments (`1m..30d`)**: Visible with `"Scheduled for …"` badge **only** to author until timestamp arrives (`404` to others).
23. **Dirty Canvas / Moment Discard Guards**: Intercepts `Close`, `Back`, scrim tap, and swipe-back with `"Discard this drawing?"` / `"Discard this moment?"` when dirty; closes immediately when untouched.
24. **Highlighter Single-Pass `35%` Composite**: Draws strokes at `100%` into an offscreen buffer composited at `0.35` alpha so self-crossing highlighter paths never darken.
25. **Unicode Surrogate-Safe Word/CJK Picker**: Iterates Unicode scalars/grapheme clusters so emoji/ZWJ sequences never split; snaps to whole words in Latin and single characters in CJK.
26. **AI Live-Typing & Style Memory Privacy**: Unsent peer Honk typing frames never touch AI/storage; style vocabulary requires `≥ 2` separate own messages to prevent 1-off secret leakage.
27. **Routine `04:00` Day Boundary & `≥ 2`-Day Floor**: Activity before `04:00` local time joins prior wake-day; wake/sleep medians require `≥ 2` active days (`45`-day half-life).
28. **Sticker `120ms` Quiet Decode & Removed-Pack History**: Waits `120ms` before showing emoji fallback (zero flash on cached stickers) and preserves R2-cached sticker rendering in old chats after pack removal.
29. **Call Back-Gesture & Port-53 TURN Safety**: Back on folded full-screen call minimizes to PiP; Back on incoming ring **never** declines; strips `:53` TURN URLs and releases mic immediately on hangup.
30. **`Clarinetta-RegularItalic` & Offline Avatar Guard**: Maps `400` italic to `Clarinetta-MediumItalic.ttf` (avoiding duplicate BlackItalic binary), and saving a Cover in `ProfileAvatarCoverEditorSheet` while current avatar fails to load offline never wipes `avatarURL`.
