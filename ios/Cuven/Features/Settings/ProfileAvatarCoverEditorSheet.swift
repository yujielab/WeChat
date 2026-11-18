import CoreGraphics
import CuvenCore
import PhotosUI
import SwiftUI
import UIKit

/// Tab selector inside `ProfileAvatarCoverEditorSheet` (`Avatar | Cover`).
public enum ProfileEditorTab: String, CaseIterable, Identifiable, Sendable {
    case avatar
    case cover

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .avatar: return "Avatar"
        case .cover: return "Cover"
        }
    }
}

/// Unified Avatar (`512×512` circular crop) & Cover (`1200×462` banner framing) editor with live
/// `DominantColorExtractor` tinting and 8-item Recent Avatars quick-switch shelf.
///
/// Grounded in:
/// - Canonical Contract: `PROJECT.md § 5.4` (`public struct ProfileAvatarCoverEditorSheet: View { public init(store: AppStore) }`)
/// - Apple HIG: *Sheets*, *Materials / Liquid Glass*, *PhotosPicker*, *Gestures* (1:1 pan + focal pinch-to-zoom)
/// - Cuven Web Reference: `public/js/views/avatar-editor.js`, `public/js/ui/framing.js`, `public/css/avatar-editor.css`
public struct ProfileAvatarCoverEditorSheet: View {
    private enum AvatarSourceState: Equatable {
        case existingRemote(String, UIImage?)
        case studioPreset(StudioAvatarPreset, UIImage)
        case recentSelected(String, UIImage?)
        case pickedCustom(UIImage)
        case removedToInitials
    }

    private enum CoverSourceState: Equatable {
        case existingRemote(String)
        case preset(BackdropPreset)
        case pickedCustom(UIImage)
        case none
    }

    private let store: AppStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var modeSwitchNamespace

    @State private var selectedTab: ProfileEditorTab
    @State private var avatarSource: AvatarSourceState
    @State private var coverSource: CoverSourceState

    @State private var avatarCropFrame = CircularCropFrame(
        imageWidth: 768,
        imageHeight: 768,
        viewportDiameter: 232
    )
    @State private var coverCropFrame = RectangularCropFrame(
        imageWidth: 1200,
        imageHeight: 462,
        viewportSize: CGSize(width: 340, height: 131)
    )

    @State private var isAdjustingAvatar: Bool = false
    @State private var hasModifiedAvatarFraming: Bool = false
    @State private var isActivelyDraggingCrop: Bool = false

    // Gesture baseline state for simultaneous 1:1 pan + pinch zoom
    @State private var gestureStartOffset: CGSize?
    @State private var gestureStartZoom: CGFloat?
    @State private var coverGestureStartOffset: CGSize?
    @State private var coverGestureStartZoom: CGFloat?

    // PhotosPicker selections
    @State private var selectedAvatarPickerItem: PhotosPickerItem?
    @State private var selectedCoverPickerItem: PhotosPickerItem?

    // Extracted dominant tint palette & active hex choice
    @State private var extractedPalette: ExtractedColorPalette = .neutralDefault
    @State private var selectedTintHex: String = "#1877F2"
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    /// Canonical initializer required by `PROJECT.md § 5.4`.
    public init(store: AppStore) {
        self.init(store: store, initialTab: .avatar)
    }

    /// Extended initializer allowing direct opening onto `.avatar` or `.cover`.
    public init(store: AppStore, initialTab: ProfileEditorTab) {
        self.store = store
        self._selectedTab = State(initialValue: initialTab)

        let user = store.currentUser
        var initialDemoCGImage: CGImage?
        if let existingAvatar = user?.avatarURL, !existingAvatar.isEmpty {
            if let demoCG = AvatarCoverCropEngine.renderDemoAvatarCGImage(forURLString: existingAvatar) {
                initialDemoCGImage = demoCG
                self._avatarSource = State(initialValue: .existingRemote(existingAvatar, UIImage(cgImage: demoCG)))
                self._avatarCropFrame = State(
                    initialValue: CircularCropFrame(
                        imageWidth: CGFloat(demoCG.width),
                        imageHeight: CGFloat(demoCG.height),
                        viewportDiameter: 232
                    )
                )
            } else {
                self._avatarSource = State(initialValue: .existingRemote(existingAvatar, nil))
            }
        } else {
            self._avatarSource = State(initialValue: .removedToInitials)
        }

        if let existingCover = user?.coverURL, !existingCover.isEmpty {
            if existingCover.hasPrefix("preset:"),
               let preset = BackdropPreset(rawValue: String(existingCover.dropFirst(7))) {
                self._coverSource = State(initialValue: .preset(preset))
            } else if let directPreset = BackdropPreset(rawValue: existingCover) {
                self._coverSource = State(initialValue: .preset(directPreset))
            } else {
                self._coverSource = State(initialValue: .existingRemote(existingCover))
            }
        } else {
            self._coverSource = State(initialValue: .none)
        }

        if let demoCG = initialDemoCGImage {
            let sampled = DominantColorExtractor.extract(from: demoCG)
            let effectiveTint = user?.dominantTintHex ?? sampled.dominantTintHex
            self._extractedPalette = State(initialValue: sampled)
            self._selectedTintHex = State(initialValue: effectiveTint)
        } else {
            let initialTint = user?.dominantTintHex ?? "#1877F2"
            self._selectedTintHex = State(initialValue: initialTint)
            if let (r, g, b) = DominantColorExtractor.rgbComponents(fromHex: initialTint) {
                let (h, s, _) = DominantColorExtractor.rgbToHSL(r: r, g: g, b: b)
                self._extractedPalette = State(
                    initialValue: ExtractedColorPalette(
                        dominantTintHex: initialTint,
                        averageHex: initialTint,
                        sheetLightHex: DominantColorExtractor.sheetTintHex(r: r, g: g, b: b, isDark: false),
                        sheetDarkHex: DominantColorExtractor.sheetTintHex(r: r, g: g, b: b, isDark: true),
                        hueDegrees: Double(h),
                        saturation: s,
                        brightness: 0.65
                    )
                )
            }
        }
    }

    private var displayName: String {
        let raw = store.currentUser?.display.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return raw }
        return store.currentUser?.username ?? "Me"
    }

    private var usernameText: String {
        "@\(store.currentUser?.username ?? "cuven")"
    }

    private var sheetTintBackground: Color {
        let hex = colorScheme == .dark ? extractedPalette.sheetDarkHex : extractedPalette.sheetLightHex
        return DominantColorExtractor.color(fromHex: hex) ?? CuvenColors.elevatedSurface
    }

    private var activeAccentColor: Color {
        DominantColorExtractor.color(fromHex: selectedTintHex) ?? CuvenColors.sidebarBlue
    }

    private var activeAvatarUIImage: UIImage? {
        switch avatarSource {
        case .pickedCustom(let img):
            return img
        case .studioPreset(_, let img):
            return img
        case .recentSelected(_, let loaded):
            return loaded
        case .existingRemote(_, let demoLoaded):
            return demoLoaded
        case .removedToInitials:
            return nil
        }
    }

    private var hasAnyAvatar: Bool {
        if case .removedToInitials = avatarSource { return false }
        return true
    }

    public var body: some View {
        ZStack {
            sheetTintBackground
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.42), value: extractedPalette)

            VStack(spacing: 0) {
                editorHeaderBar
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        if selectedTab == .avatar {
                            avatarEditorPane
                        } else {
                            coverEditorPane
                        }

                        dominantTintPreviewCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 32)
                }
            }
        }
        .accessibilityIdentifier("avatarEditor.root")
        .onChange(of: selectedAvatarPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedAvatar(from: newItem) }
        }
        .onChange(of: selectedCoverPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedCover(from: newItem) }
        }
    }

    // MARK: - Top Header (`Cancel` | `Avatar | Cover` | `Done`)

    private var editorHeaderBar: some View {
        HStack(spacing: 12) {
            Button {
                CuvenHaptics.lightTap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.cuvenGlassPill(mode: store.prefs.glassMode, cornerRadius: 22, triggersHaptic: false))
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("avatarEditor.cancel")

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                ForEach(ProfileEditorTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        guard selectedTab != tab else { return }
                        CuvenHaptics.selectionChanged()
                        withAnimation(reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.railMorph) {
                            selectedTab = tab
                            if tab != .avatar {
                                isAdjustingAvatar = false
                            }
                        }
                    } label: {
                        Text(tab.title)
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.18 : 0.11))
                                        .matchedGeometryEffect(id: "avatarCoverTabThumb", in: modeSwitchNamespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("avatarEditor.\(tab.rawValue)")
                }
            }
            .padding(4)
            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24)
            .accessibilityIdentifier("avatarEditor.modePicker")

            Spacer(minLength: 4)

            Button {
                Task { await commitSave() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(CuvenColors.onCtaInk)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(CuvenColors.onCtaInk)
                    }
                }
                .frame(width: 44, height: 44)
                .background(CuvenColors.ctaInk, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .opacity(isSaving ? 0.55 : 1.0)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("avatarEditor.done")
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - Avatar Tab (`232pt` Interactive `512×512` Cropper + Studio Swatches + `PhotosPicker` + `8` Recent Avatars)

    private var avatarEditorPane: some View {
        let stageDiameter: CGFloat = 232

        return VStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                avatarCircularCropStage(diameter: stageDiameter)
                    .accessibilityIdentifier("avatarEditor.cropStage")

                if hasAnyAvatar {
                    Button {
                        CuvenHaptics.softImpact()
                        withAnimation(reduceMotion ? nil : CuvenSprings.pressBounce) {
                            avatarSource = .removedToInitials
                            isAdjustingAvatar = false
                            hasModifiedAvatarFraming = false
                            gestureStartOffset = nil
                            gestureStartZoom = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle().strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: 6)
                    .accessibilityLabel("Remove photo")
                    .accessibilityIdentifier("avatarEditor.removeAvatarButton")
                }
            }
            .padding(.top, 6)

            // Always-accessible precision zoom slider (1.0x ... 4.0x) + framing guide toggle when a bitmap is loaded
            if activeAvatarUIImage != nil {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(CuvenColors.inkSecondary)

                        Slider(
                            value: Binding(
                                get: { Double(avatarCropFrame.zoom) },
                                set: { newVal in
                                    isAdjustingAvatar = true
                                    avatarCropFrame = avatarCropFrame.zooming(to: CGFloat(newVal))
                                    hasModifiedAvatarFraming = true
                                }
                            ),
                            in: 1.0...Double(AvatarCoverCropEngine.maxZoom),
                            step: 0.02
                        )
                        .tint(activeAccentColor)
                        .accessibilityLabel("Avatar zoom")
                        .accessibilityIdentifier("avatarEditor.zoomSlider")

                        Image(systemName: "photo.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(CuvenColors.inkPrimary)

                        if hasModifiedAvatarFraming {
                            Button {
                                CuvenHaptics.lightTap()
                                withAnimation(reduceMotion ? nil : CuvenSprings.sheetPresent) {
                                    avatarCropFrame = CircularCropFrame(
                                        imageWidth: avatarCropFrame.imageWidth,
                                        imageHeight: avatarCropFrame.imageHeight,
                                        viewportDiameter: stageDiameter,
                                        zoom: 1.0,
                                        offsetX: 0,
                                        offsetY: 0
                                    )
                                    isAdjustingAvatar = false
                                    hasModifiedAvatarFraming = false
                                }
                            } label: {
                                Text("Reset")
                                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkSecondary)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("avatarEditor.resetCropButton")
                        }
                    }
                    .frame(maxWidth: 310)

                    Text("Drag to move, pinch or slide to zoom · Exports crisp 512×512 px")
                        .font(CuvenFonts.cappedFootnote())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.dangerRedText)
            }

            // Curated Studio Portrait Swatches (deterministic 768x768 CoreGraphics art -> 512x512 crop + tint)
            studioPresetsStrip

            // Photo Picker Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Photo")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)

                PhotosPicker(
                    selection: $selectedAvatarPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(CuvenColors.inkPrimary.opacity(0.11))
                                .frame(width: 56, height: 56)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(activeAccentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose photo")
                                .font(CuvenFonts.cappedBody(weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                            Text("Choose a photo, then pinch & drag inside the 512×512 circle.")
                                .font(CuvenFonts.cappedFootnote())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkTertiary)
                    }
                    .padding(14)
                    .background(CuvenColors.cardSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("avatarEditor.choosePhotoButton")
            }

            // 8 Recent Avatars Quick-Switch Shelf (`store.recentAvatarURLs`)
            recentAvatarsShelf
        }
    }

    private var studioPresetsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Studio Swatches")
                .font(CuvenFonts.cappedHeadline(weight: .bold))
                .foregroundStyle(CuvenColors.inkPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(StudioAvatarPreset.allCases) { preset in
                        let isSelected: Bool = {
                            if case .studioPreset(let active, _) = avatarSource {
                                return active == preset
                            }
                            return false
                        }()
                        let (pri, sec, acc) = preset.paletteRGB
                        let c1 = Color(.sRGB, red: Double(pri.0) / 255.0, green: Double(pri.1) / 255.0, blue: Double(pri.2) / 255.0, opacity: 1)
                        let c2 = Color(.sRGB, red: Double(sec.0) / 255.0, green: Double(sec.1) / 255.0, blue: Double(sec.2) / 255.0, opacity: 1)
                        let c3 = Color(.sRGB, red: Double(acc.0) / 255.0, green: Double(acc.1) / 255.0, blue: Double(acc.2) / 255.0, opacity: 1)

                        Button {
                            CuvenHaptics.selectionChanged()
                            selectStudioPreset(preset)
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 52, height: 52)
                                    Circle()
                                        .fill(RadialGradient(colors: [c3, .clear], center: .topLeading, startRadius: 2, endRadius: 28))
                                        .frame(width: 34, height: 34)
                                        .offset(x: -3, y: -3)
                                }
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? CuvenColors.inkPrimary : CuvenColors.cardLine,
                                            lineWidth: isSelected ? 2.5 : 1.0
                                        )
                                }

                                Text(preset.title)
                                    .font(CuvenFonts.cappedCaption2(weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                            }
                            .frame(minWidth: 56, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Studio avatar \(preset.title)")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .accessibilityIdentifier("avatarEditor.studioPreset.\(preset.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("avatarEditor.studioShelf")
    }

    @ViewBuilder
    private func avatarCircularCropStage(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(CuvenColors.inkPrimary.opacity(0.08))
                .frame(width: diameter, height: diameter)

            if let uiImage = activeAvatarUIImage {
                let effectiveFrame = avatarCropFrame.resized(toDiameter: diameter)
                let box = effectiveFrame.displayRect()

                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: diameter, height: diameter)

                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .contentShape(Circle())
                .gesture(avatarSimultaneousCropGesture(diameter: diameter))
                .onTapGesture(count: 2) {
                    CuvenHaptics.lightTap()
                    let targetZoom: CGFloat = effectiveFrame.zoom > 1.3 ? 1.0 : 2.0
                    withAnimation(reduceMotion ? nil : CuvenSprings.sheetPresent) {
                        avatarCropFrame = effectiveFrame.zooming(to: targetZoom)
                        isAdjustingAvatar = true
                        hasModifiedAvatarFraming = targetZoom > 1.0
                    }
                }
            } else if case .existingRemote(let urlString, _) = avatarSource {
                CuvenAvatarView(
                    name: displayName,
                    urlString: urlString,
                    size: diameter,
                    isOnline: false
                )
                .clipShape(Circle())
            } else if case .recentSelected(let urlString, nil) = avatarSource {
                CuvenAvatarView(
                    name: displayName,
                    urlString: urlString,
                    size: diameter,
                    isOnline: false
                )
                .clipShape(Circle())
            } else {
                // Monogram fallback (`avatar-editor.js:143`)
                CuvenAvatarView(
                    name: displayName,
                    urlString: nil,
                    size: diameter,
                    isOnline: false
                )
                .clipShape(Circle())
            }

            // Rule-of-thirds circular guide while framing
            if isAdjustingAvatar || isActivelyDraggingCrop {
                circularFramingGridOverlay(diameter: diameter)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(
                    (isAdjustingAvatar || isActivelyDraggingCrop)
                        ? activeAccentColor
                        : CuvenColors.inkPrimary.opacity(0.18),
                    lineWidth: (isAdjustingAvatar || isActivelyDraggingCrop) ? 3.0 : 1.0
                )
        }
        .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 12)
    }

    private func circularFramingGridOverlay(diameter: CGFloat) -> some View {
        Canvas { context, size in
            let thirdW = size.width / 3.0
            let thirdH = size.height / 3.0
            var path = Path()
            for idx in 1...2 {
                let x = thirdW * CGFloat(idx)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = thirdH * CGFloat(idx)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 0.75)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private func avatarSimultaneousCropGesture(diameter: CGFloat) -> some Gesture {
        let pan = DragGesture(minimumDistance: 2)
            .onChanged { value in
                isAdjustingAvatar = true
                isActivelyDraggingCrop = true
                let base = gestureStartOffset ?? CGSize(width: avatarCropFrame.offsetX, height: avatarCropFrame.offsetY)
                if gestureStartOffset == nil {
                    gestureStartOffset = base
                }
                avatarCropFrame = CircularCropFrame(
                    imageWidth: avatarCropFrame.imageWidth,
                    imageHeight: avatarCropFrame.imageHeight,
                    viewportDiameter: diameter,
                    zoom: avatarCropFrame.zoom,
                    offsetX: base.width + value.translation.width,
                    offsetY: base.height + value.translation.height
                ).clamped()
                hasModifiedAvatarFraming = true
            }
            .onEnded { _ in
                gestureStartOffset = nil
                isActivelyDraggingCrop = false
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                isAdjustingAvatar = true
                isActivelyDraggingCrop = true
                let startZoom = gestureStartZoom ?? avatarCropFrame.zoom
                if gestureStartZoom == nil {
                    gestureStartZoom = startZoom
                }
                let anchor = CGPoint(
                    x: (value.startLocation.x - diameter / 2.0),
                    y: (value.startLocation.y - diameter / 2.0)
                )
                avatarCropFrame = avatarCropFrame
                    .resized(toDiameter: diameter)
                    .zooming(to: startZoom * value.magnification, anchorFromCenter: anchor)
                hasModifiedAvatarFraming = true
            }
            .onEnded { _ in
                gestureStartZoom = nil
                isActivelyDraggingCrop = false
            }

        return pan.simultaneously(with: magnify)
    }

    private var recentAvatarsShelf: some View {
        let recentURLs = Array(store.recentAvatarURLs.prefix(8))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                Spacer()
                Text("\(recentURLs.count)/8")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .monospacedDigit()
            }

            if recentURLs.isEmpty {
                Text("Up to 8 previous avatars appear here for instant one-tap switching.")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CuvenColors.cardSurface.opacity(0.60), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                    spacing: 12
                ) {
                    ForEach(Array(recentURLs.enumerated()), id: \.offset) { index, urlString in
                        let isSelected: Bool = {
                            switch avatarSource {
                            case .existingRemote(let cur, _): return cur == urlString
                            case .recentSelected(let cur, _): return cur == urlString
                            default: return false
                            }
                        }()

                        Button {
                            CuvenHaptics.selectionChanged()
                            selectRecentAvatar(urlString, index: index)
                        } label: {
                            ZStack {
                                CuvenAvatarView(
                                    name: "\(displayName) \(index + 1)",
                                    urlString: urlString,
                                    size: 64,
                                    isOnline: false
                                )
                                .clipShape(Circle())
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? activeAccentColor : CuvenColors.cardLine,
                                            lineWidth: isSelected ? 3.0 : 1.0
                                        )
                                }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recent avatar \(index + 1)")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .accessibilityIdentifier("avatarEditor.recent.\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("avatarEditor.recentShelf")
    }

    // MARK: - Cover Tab (Wide `2.6:1` Framing Stage + Overlapping Avatar + 8 Backdrop Presets)

    private var coverEditorPane: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .topTrailing) {
                coverLiveProfileStage
                    .accessibilityIdentifier("avatarEditor.coverStage")

                if coverSource != .none {
                    Button {
                        CuvenHaptics.softImpact()
                        withAnimation(reduceMotion ? nil : CuvenSprings.pressBounce) {
                            coverSource = .none
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(CuvenColors.cardLine, lineWidth: 1) }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .accessibilityLabel("Remove cover")
                    .accessibilityIdentifier("avatarEditor.removeCoverButton")
                }
            }

            if case .pickedCustom = coverSource {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 13))
                        .foregroundStyle(CuvenColors.inkSecondary)
                    Slider(
                        value: Binding(
                            get: { Double(coverCropFrame.zoom) },
                            set: { coverCropFrame = coverCropFrame.zooming(to: CGFloat($0)) }
                        ),
                        in: 1.0...Double(AvatarCoverCropEngine.maxZoom),
                        step: 0.02
                    )
                    .tint(activeAccentColor)
                    .accessibilityLabel("Cover zoom")
                    .accessibilityIdentifier("avatarEditor.coverZoomSlider")
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 13))
                        .foregroundStyle(CuvenColors.inkPrimary)
                }
                .frame(maxWidth: 280)
            }

            // Custom Cover Photo Picker
            VStack(alignment: .leading, spacing: 10) {
                Text("Banner Photo")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)

                PhotosPicker(
                    selection: $selectedCoverPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(CuvenColors.inkPrimary.opacity(0.11))
                                .frame(width: 60, height: 60)
                            Image(systemName: "panorama.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(activeAccentColor)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose cover photo")
                                .font(CuvenFonts.cappedBody(weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                            Text("Shown across the top of your profile card (1200×462).")
                                .font(CuvenFonts.cappedFootnote())
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkTertiary)
                    }
                    .padding(14)
                    .background(CuvenColors.cardSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("avatarEditor.chooseCoverButton")
            }

            // Built-in Cover Preset Grid (`None` + 8 `BackdropPreset` styles)
            VStack(alignment: .leading, spacing: 10) {
                Text("Style")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 94), spacing: 10)],
                    spacing: 10
                ) {
                    coverPresetTile(label: "None", preset: nil)
                    ForEach(BackdropPreset.allCases, id: \.self) { preset in
                        coverPresetTile(label: Self.backdropDisplayName(preset), preset: preset)
                    }
                }
                .accessibilityIdentifier("avatarEditor.coverPresetGrid")
            }
        }
    }

    private var coverLiveProfileStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let stageSize = CGSize(width: max(1, geo.size.width), height: max(1, geo.size.height))
                ZStack {
                    switch coverSource {
                    case .pickedCustom(let uiImage):
                        let frame = RectangularCropFrame(
                            imageWidth: CGFloat(uiImage.cgImage?.width ?? Int(uiImage.size.width)),
                            imageHeight: CGFloat(uiImage.cgImage?.height ?? Int(uiImage.size.height)),
                            viewportSize: stageSize,
                            zoom: coverCropFrame.zoom,
                            offsetX: coverCropFrame.offsetX,
                            offsetY: coverCropFrame.offsetY
                        ).clamped()
                        let box = frame.displayRect()
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            Image(uiImage: uiImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: box.width, height: box.height)
                                .offset(x: box.minX, y: box.minY)
                        }
                        .frame(width: stageSize.width, height: stageSize.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(coverPanAndZoomGesture(stageSize: stageSize))
                    case .preset(let preset):
                        CuvenBackdropView(preset: preset)
                    case .existingRemote(let url):
                        CuvenBackdropView(preset: .mist, customImageURL: url)
                    case .none:
                        LinearGradient(
                            colors: [activeAccentColor.opacity(0.28), CuvenColors.inkPrimary.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            }
            .aspectRatio(2.6, contentMode: .fit)

            // Overlapping `76pt` Avatar Face + Display Name (`avatar-editor.css:175-198`)
            HStack(alignment: .bottom, spacing: 12) {
                Group {
                    if let uiImage = activeAvatarUIImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(Circle())
                    } else if case .existingRemote(let url, _) = avatarSource {
                        CuvenAvatarView(name: displayName, urlString: url, size: 76)
                    } else {
                        CuvenAvatarView(name: displayName, urlString: nil, size: 76)
                    }
                }
                .overlay {
                    Circle().strokeBorder(sheetTintBackground, lineWidth: 3.5)
                }
                .offset(y: -32)
                .padding(.bottom, -32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(CuvenFonts.cappedHeadline(weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)
                    Text(usernameText)
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 4)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(CuvenColors.cardSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }

    private func coverPanAndZoomGesture(stageSize: CGSize) -> some Gesture {
        let pan = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let base = coverGestureStartOffset ?? CGSize(width: coverCropFrame.offsetX, height: coverCropFrame.offsetY)
                if coverGestureStartOffset == nil {
                    coverGestureStartOffset = base
                }
                coverCropFrame = RectangularCropFrame(
                    imageWidth: coverCropFrame.imageWidth,
                    imageHeight: coverCropFrame.imageHeight,
                    viewportSize: stageSize,
                    zoom: coverCropFrame.zoom,
                    offsetX: base.width + value.translation.width,
                    offsetY: base.height + value.translation.height
                ).clamped()
            }
            .onEnded { _ in
                coverGestureStartOffset = nil
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                let startZ = coverGestureStartZoom ?? coverCropFrame.zoom
                if coverGestureStartZoom == nil {
                    coverGestureStartZoom = startZ
                }
                coverCropFrame = RectangularCropFrame(
                    imageWidth: coverCropFrame.imageWidth,
                    imageHeight: coverCropFrame.imageHeight,
                    viewportSize: stageSize,
                    zoom: coverCropFrame.zoom,
                    offsetX: coverCropFrame.offsetX,
                    offsetY: coverCropFrame.offsetY
                ).zooming(to: startZ * value.magnification)
            }
            .onEnded { _ in
                coverGestureStartZoom = nil
            }

        return pan.simultaneously(with: magnify)
    }

    private func coverPresetTile(label: String, preset: BackdropPreset?) -> some View {
        let isSelected: Bool = {
            if let preset {
                return coverSource == .preset(preset)
            }
            return coverSource == .none
        }()

        return Button {
            CuvenHaptics.selectionChanged()
            withAnimation(reduceMotion ? nil : CuvenSprings.pressBounce) {
                if let preset {
                    coverSource = .preset(preset)
                } else {
                    coverSource = .none
                }
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let preset {
                    CuvenBackdropView(preset: preset)
                } else {
                    CuvenColors.fieldBackground
                }

                Text(label)
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
            .aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? CuvenColors.inkPrimary : CuvenColors.cardLine,
                        lineWidth: isSelected ? 2.5 : 1.0
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("Cover style \(label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Live Dominant Color Palette Card

    private var dominantTintPreviewCard: some View {
        let swatches: [(String, String)] = [
            ("Vibrant", extractedPalette.dominantTintHex),
            ("Average", extractedPalette.averageHex),
            ("Cuven Blue", "#1877F2"),
            ("Ink", "#18181B")
        ]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dominant Profile Tint", systemImage: "eyedropper.halffull")
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)

                Spacer()

                Text(selectedTintHex.uppercased())
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(activeAccentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(activeAccentColor.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 10) {
                ForEach(swatches, id: \.0) { label, hex in
                    let isChosen = selectedTintHex.caseInsensitiveCompare(hex) == .orderedSame
                    let swatchColor = DominantColorExtractor.color(fromHex: hex) ?? CuvenColors.sidebarBlue
                    Button {
                        CuvenHaptics.selectionChanged()
                        selectedTintHex = hex
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(swatchColor)
                                .frame(width: 16, height: 16)
                            Text(label)
                                .font(CuvenFonts.cappedCaption(weight: .medium))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(
                            isChosen ? swatchColor.opacity(0.16) : CuvenColors.fieldBackground.opacity(0.75),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    isChosen ? swatchColor : CuvenColors.cardLine,
                                    lineWidth: isChosen ? 2.0 : 1.0
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label) accent \(hex)")
                }
            }
        }
        .padding(16)
        .background(CuvenColors.cardSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
        }
        .accessibilityIdentifier("avatarEditor.dominantTintCard")
    }

    // MARK: - Loading Photos, Extracting Tint & Exporting `512×512` / `1200×462` Crops

    private func loadPickedAvatar(from item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: rawData),
                  let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: uiImage) else {
                errorMessage = "This image couldn't be opened."
                return
            }
            let normalizedUI = UIImage(cgImage: cgImage)
            let palette = DominantColorExtractor.extract(from: cgImage)
            avatarSource = .pickedCustom(normalizedUI)
            avatarCropFrame = CircularCropFrame(
                imageWidth: CGFloat(cgImage.width),
                imageHeight: CGFloat(cgImage.height),
                viewportDiameter: 232,
                zoom: 1.0,
                offsetX: 0,
                offsetY: 0
            )
            extractedPalette = palette
            selectedTintHex = palette.dominantTintHex
            isAdjustingAvatar = true
            hasModifiedAvatarFraming = false
            CuvenHaptics.softImpact()
        } catch {
            errorMessage = "Couldn't read selected photo."
        }
    }

    private func loadPickedCover(from item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: rawData),
                  let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: uiImage) else {
                errorMessage = "This cover image couldn't be opened."
                return
            }
            let normalizedUI = UIImage(cgImage: cgImage)
            let palette = DominantColorExtractor.extract(from: cgImage)
            coverSource = .pickedCustom(normalizedUI)
            coverCropFrame = RectangularCropFrame(
                imageWidth: CGFloat(cgImage.width),
                imageHeight: CGFloat(cgImage.height),
                viewportSize: CGSize(width: 340, height: 131),
                zoom: 1.0,
                offsetX: 0,
                offsetY: 0
            )
            extractedPalette = palette
            selectedTintHex = palette.dominantTintHex
            CuvenHaptics.softImpact()
        } catch {
            errorMessage = "Couldn't read selected cover photo."
        }
    }

    private func selectStudioPreset(_ preset: StudioAvatarPreset) {
        errorMessage = nil
        guard let cgImage = AvatarCoverCropEngine.renderStudioAvatarCGImage(preset: preset) else {
            return
        }
        let uiImage = UIImage(cgImage: cgImage)
        let palette = DominantColorExtractor.extract(from: cgImage)
        avatarSource = .studioPreset(preset, uiImage)
        avatarCropFrame = CircularCropFrame(
            imageWidth: CGFloat(cgImage.width),
            imageHeight: CGFloat(cgImage.height),
            viewportDiameter: 232,
            zoom: 1.0,
            offsetX: 0,
            offsetY: 0
        )
        extractedPalette = palette
        selectedTintHex = palette.dominantTintHex
        isAdjustingAvatar = true
        hasModifiedAvatarFraming = false
    }

    private func selectRecentAvatar(_ urlString: String, index: Int) {
        hasModifiedAvatarFraming = false
        isAdjustingAvatar = false

        // Immediate pixel extraction when selecting a `cuven-demo://avatar/...` studio entry
        if let demoCG = AvatarCoverCropEngine.renderDemoAvatarCGImage(forURLString: urlString) {
            let uiImage = UIImage(cgImage: demoCG)
            let realPalette = DominantColorExtractor.extract(from: demoCG)
            avatarSource = .recentSelected(urlString, uiImage)
            avatarCropFrame = CircularCropFrame(
                imageWidth: CGFloat(demoCG.width),
                imageHeight: CGFloat(demoCG.height),
                viewportDiameter: 232
            )
            extractedPalette = realPalette
            selectedTintHex = realPalette.dominantTintHex
            return
        }

        avatarSource = .recentSelected(urlString, nil)

        // Derive a deterministic harmonious palette from the recent slot immediately,
        // and upgrade with real pixel extraction if the URL resolves to image bytes.
        let goldenHue = Double((index * 47 + 205) % 360)
        let (r, g, b) = DominantColorExtractor.hslToRGB(h: goldenHue, s: 0.68, l: 0.50)
        let hex = DominantColorExtractor.hexString(r: r, g: g, b: b)
        extractedPalette = ExtractedColorPalette(
            dominantTintHex: hex,
            averageHex: hex,
            sheetLightHex: DominantColorExtractor.sheetTintHex(r: r, g: g, b: b, isDark: false),
            sheetDarkHex: DominantColorExtractor.sheetTintHex(r: r, g: g, b: b, isDark: true),
            hueDegrees: goldenHue,
            saturation: 0.68,
            brightness: 0.72
        )
        selectedTintHex = hex

        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let uiImage = UIImage(data: data),
                      let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: uiImage) else {
                    return
                }
                if case .recentSelected(let currentURL, _) = avatarSource, currentURL == urlString {
                    let normalized = UIImage(cgImage: cgImage)
                    avatarSource = .recentSelected(urlString, normalized)
                    avatarCropFrame = CircularCropFrame(
                        imageWidth: CGFloat(cgImage.width),
                        imageHeight: CGFloat(cgImage.height),
                        viewportDiameter: 232
                    )
                    let realPalette = DominantColorExtractor.extract(from: cgImage)
                    extractedPalette = realPalette
                    selectedTintHex = realPalette.dominantTintHex
                }
            }
        }
    }

    private func commitSave() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        // Export 512x512 JPEG when a new/studio/reframed avatar image was chosen;
        // if an offline existing remote avatar was untouched (`spec_miner_survey_2` Edge Case #30), pass `nil` so it is preserved!
        var exportedAvatarData: Data?
        switch avatarSource {
        case .pickedCustom(let uiImage), .studioPreset(_, let uiImage):
            if let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: uiImage) {
                exportedAvatarData = AvatarCoverCropEngine.renderAvatar512JPEG(
                    from: cgImage,
                    frame: avatarCropFrame
                )
            }
        case .recentSelected(_, let loadedImage):
            if let loadedImage,
               let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: loadedImage) {
                exportedAvatarData = AvatarCoverCropEngine.renderAvatar512JPEG(
                    from: cgImage,
                    frame: avatarCropFrame
                )
            }
        case .existingRemote(_, let demoLoaded):
            if hasModifiedAvatarFraming,
               let demoLoaded,
               let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: demoLoaded) {
                exportedAvatarData = AvatarCoverCropEngine.renderAvatar512JPEG(
                    from: cgImage,
                    frame: avatarCropFrame
                )
            } else {
                exportedAvatarData = nil
            }
        case .removedToInitials:
            if store.currentUser?.avatarURL != nil {
                exportedAvatarData = Data()
            }
        }

        var exportedCoverData: Data?
        switch coverSource {
        case .pickedCustom(let uiImage):
            if let cgImage = AvatarCoverCropEngine.normalizedCGImage(from: uiImage) {
                exportedCoverData = AvatarCoverCropEngine.renderCoverBannerJPEG(
                    from: cgImage,
                    frame: coverCropFrame
                )
            }
        case .preset(let preset):
            let renderer = ImageRenderer(
                content: CuvenBackdropView(preset: preset)
                    .frame(width: 600, height: 231)
            )
            renderer.scale = 2.0
            exportedCoverData = renderer.uiImage?.jpegData(compressionQuality: 0.88)
        case .existingRemote:
            exportedCoverData = nil
        case .none:
            if store.currentUser?.coverURL != nil {
                exportedCoverData = Data()
            }
        }

        let currentDisplay = store.currentUser?.display ?? displayName
        let currentBio = store.currentUser?.bio ?? ""

        await store.updateProfile(
            display: currentDisplay,
            bio: currentBio,
            avatarData: exportedAvatarData,
            coverData: exportedCoverData,
            dominantTintHex: selectedTintHex
        )

        CuvenHaptics.success()
        isSaving = false
        dismiss()
    }

    public static func backdropDisplayName(_ preset: BackdropPreset) -> String {
        switch preset {
        case .mist: return "Mist"
        case .dawn: return "Dawn"
        case .mint: return "Mint"
        case .sand: return "Dune"
        case .ocean: return "Ocean"
        case .dusk: return "Dusk"
        case .dots: return "Dots"
        case .night: return "Night"
        }
    }
}
