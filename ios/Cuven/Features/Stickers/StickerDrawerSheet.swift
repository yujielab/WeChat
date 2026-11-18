import SwiftUI
import CuvenCore

// MARK: - Canonical Telegram Sticker Drawer & Pack Catalog Sheet (M10 — `PROJECT.md § 5.4`)
//
// Exact Public Contract:
// `public struct StickerDrawerSheet: View {`
// `    public init(store: AppStore, onSelectSticker: @escaping (StickerItem) -> Void)`
// `}`
//
// Grounded in `public/js/views/stickers.js:224-341` & `src/stickers.js:35-50`:
// - Installed pack tab bar (`role="tablist"`) + `+` Pack Catalog tab (`Add sticker pack`).
// - Borderless 4/5-column sticker grid rendering static WebP (`ImageIO`), animated Lottie JSON
//   (`LottieCanvasEvaluator` at 60–120Hz), and muted looping video (`AVQueuePlayer` + `AVPlayerLooper`),
//   respecting `accessibilityReduceMotion` and the `120ms` anti-flash hold (`AnimatedStickerRenderer`).
// - Full 14-pack Cuven Telegram Catalog (`HandDrawnEmoji`, `GameEmoji`, `ParisOlympicEmoji`,
//   `UtyaDuck`, `HotCherry`, `AnimatedEmojies`, `LadyCat`, `MottyEmojiAnim`, `SiameseCatLive`,
//   `LINE_Mochi_Mochi_Peach_Cat`, `CAT_CAT_CAT111`, `Pusheen_3`, `utya_vk`, `AngryDuck`) with
//   live `Add` / `Remove` persistence via `store.toggleStickerPackInstalled(packName:)`.

public struct StickerDrawerSheet: View {
    private let store: AppStore
    private let onSelectSticker: (StickerItem) -> Void
    private let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var packTabNamespace

    @State private var selectedPackName: String?
    @State private var isShowingCatalog: Bool = false
    @State private var searchFilter: String = ""
    @State private var togglingPackNames: Set<String> = []

    /// Canonical `PROJECT.md § 5.4` initializer.
    public init(
        store: AppStore,
        onSelectSticker: @escaping (StickerItem) -> Void
    ) {
        self.store = store
        self.onSelectSticker = onSelectSticker
        self.onClose = nil
    }

    /// Extended initializer supporting custom modal hosts (e.g., `.cuvenAdaptiveModal`).
    public init(
        store: AppStore,
        onSelectSticker: @escaping (StickerItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.onSelectSticker = onSelectSticker
        self.onClose = onClose
    }

    private func closeDrawer() {
        if let onClose {
            onClose()
        }
        dismiss()
    }

    // MARK: - Resolved Catalog & Installed Shelf

    private var allCatalogPacks: [StickerPack] {
        CuvenStickerCatalogRegistry.mergedCatalogPacks(
            storePacks: store.stickerPacks,
            serverBaseURL: store.serverBaseURL
        )
    }

    private var installedPacks: [StickerPack] {
        CuvenStickerCatalogRegistry.installedPacks(
            from: allCatalogPacks,
            installedNames: store.installedStickerPackNames
        )
    }

    private var activePack: StickerPack? {
        guard !installedPacks.isEmpty else { return nil }
        if let name = selectedPackName,
           let matched = installedPacks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return matched
        }
        return installedPacks.first
    }

    private var filteredStickersInActivePack: [StickerItem] {
        guard let pack = activePack else { return [] }
        let trimmed = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return pack.stickers }
        return pack.stickers.filter { item in
            item.emoji.lowercased().contains(trimmed)
                || item.id.lowercased().contains(trimmed)
                || pack.title.lowercased().contains(trimmed)
        }
    }

    private var filteredCatalogPacks: [StickerPack] {
        let trimmed = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allCatalogPacks }
        return allCatalogPacks.filter { pack in
            pack.title.lowercased().contains(trimmed)
                || pack.name.lowercased().contains(trimmed)
                || pack.stickers.contains(where: { $0.emoji.contains(trimmed) })
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            sheetHeaderBar
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            packTabStrip
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()
                .overlay(CuvenColors.hairlineSeparator)

            if isShowingCatalog || installedPacks.isEmpty {
                packCatalogListView
            } else {
                activePackStickerGridView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CuvenColors.cardSurface.ignoresSafeArea())
        .onAppear {
            if selectedPackName == nil {
                selectedPackName = installedPacks.first?.name
            }
            if installedPacks.isEmpty {
                isShowingCatalog = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sticker.drawer")
    }

    // MARK: - 1. Header Bar (`Stickers` + Filter Pill + `Close`)

    private var sheetHeaderBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isShowingCatalog ? "Sticker Packs" : "Stickers")
                        .font(CuvenFonts.cappedTitle(weight: .bold))
                        .foregroundStyle(CuvenColors.inkPrimary)

                    if isShowingCatalog {
                        Text("\(allCatalogPacks.count) curated Telegram packs")
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                    } else if let pack = activePack {
                        HStack(spacing: 6) {
                            Text(pack.title)
                                .font(CuvenFonts.cappedCaption(weight: .semibold))
                                .foregroundStyle(CuvenColors.inkSecondary)
                            formatBadge(for: pack.format)
                        }
                    }
                }

                Spacer()

                Button {
                    CuvenHaptics.lightTap()
                    closeDrawer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .frame(width: 44, height: 44)
                        .background(CuvenColors.fieldBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("sticker.close")
            }

            // Lightweight emoji / pack search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CuvenColors.inkTertiary)

                TextField(
                    isShowingCatalog ? "Filter sticker packs…" : "Search by emoji or pack…",
                    text: $searchFilter
                )
                .font(CuvenFonts.cappedSubheadline())
                .foregroundStyle(CuvenColors.inkPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("sticker.searchField")

                if !searchFilter.isEmpty {
                    Button {
                        searchFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(CuvenColors.inkTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear sticker filter")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - 2. Pack Tabs + `+` Add Catalog Button (`stickers.js:242-255`)

    private var packTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(installedPacks) { pack in
                    let isSelected = !isShowingCatalog
                        && (activePack?.name.caseInsensitiveCompare(pack.name) == .orderedSame)

                    Button {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            isShowingCatalog = false
                            selectedPackName = pack.name
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let firstEmoji = pack.stickers.first?.emoji, !firstEmoji.isEmpty {
                                Text(firstEmoji)
                                    .font(.system(size: 15))
                            }
                            Text(pack.title)
                                .font(CuvenFonts.cappedSubheadline(weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                        }
                        .padding(.horizontal, 13)
                        .frame(minHeight: 40)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(CuvenColors.ctaInk)
                                    .matchedGeometryEffect(id: "stickerPackActivePill", in: packTabNamespace)
                            } else {
                                Capsule(style: .continuous)
                                    .fill(CuvenColors.fieldBackground)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel(pack.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("sticker.tab.\(pack.name)")
                }

                // Trailing `+` Pack Store / Catalog button (`stickers.js:252`)
                Button {
                    CuvenHaptics.selectionChanged()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                        isShowingCatalog.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text("Packs")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                    }
                    .foregroundStyle(isShowingCatalog ? CuvenColors.onCtaInk : CuvenColors.sidebarBlue)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 40)
                    .background {
                        if isShowingCatalog {
                            Capsule(style: .continuous)
                                .fill(CuvenColors.ctaInk)
                                .matchedGeometryEffect(id: "stickerPackActivePill", in: packTabNamespace)
                        } else {
                            Capsule(style: .continuous)
                                .fill(CuvenColors.sidebarBlue.opacity(0.12))
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("Add sticker pack")
                .accessibilityAddTraits(isShowingCatalog ? .isSelected : [])
                .accessibilityIdentifier("sticker.catalogTab")
            }
            .padding(.horizontal, 4)
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - 3. Borderless Sticker Grid (`stickers.js:257-271`)

    private var activePackStickerGridView: some View {
        let columns = [GridItem(.adaptive(minimum: 76, maximum: 100), spacing: 10)]

        return ScrollView(.vertical, showsIndicators: false) {
            if filteredStickersInActivePack.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 32))
                        .foregroundStyle(CuvenColors.inkTertiary)
                    Text("No matching stickers")
                        .font(CuvenFonts.cappedHeadline())
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text("Try another emoji or browse the + Packs catalog.")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredStickersInActivePack) { item in
                        Button {
                            CuvenHaptics.lightTap()
                            onSelectSticker(item)
                            closeDrawer()
                        } label: {
                            AnimatedStickerRenderer(
                                sticker: item,
                                size: 72,
                                serverBaseURL: store.serverBaseURL
                            )
                            .frame(maxWidth: .infinity, minHeight: 78)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(StickerCellBounceButtonStyle(reduceMotion: reduceMotion))
                        .accessibilityLabel("Send sticker \(item.emoji)")
                        .accessibilityIdentifier("sticker.item.\(item.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - 4. `+` 14-Pack Curated Catalog List (`stickers.js:274-329`)

    private var packCatalogListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(filteredCatalogPacks) { pack in
                    let isInstalled = CuvenStickerCatalogRegistry.isPackInstalled(
                        pack.name,
                        in: store.installedStickerPackNames
                    )
                    let isBusy = togglingPackNames.contains(pack.name)

                    HStack(spacing: 14) {
                        if let cover = pack.stickers.first {
                            AnimatedStickerRenderer(
                                sticker: cover,
                                size: 52,
                                serverBaseURL: store.serverBaseURL
                            )
                            .frame(width: 56, height: 56)
                            .background(
                                CuvenColors.fieldBackground,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(pack.title)
                                    .font(CuvenFonts.cappedBody(weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkPrimary)
                                    .lineLimit(1)
                                formatBadge(for: pack.format)
                            }

                            Text("\(pack.stickers.count) stickers · \(pack.stickers.prefix(5).map(\.emoji).joined(separator: " "))")
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button {
                            Task {
                                await toggleCatalogPack(pack, currentlyInstalled: isInstalled)
                            }
                        } label: {
                            Text(isInstalled ? "Remove" : "Add")
                                .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                                .foregroundStyle(isInstalled ? CuvenColors.inkPrimary : CuvenColors.onCtaInk)
                                .padding(.horizontal, 16)
                                .frame(minWidth: 82, minHeight: 40)
                                .background(
                                    isInstalled ? CuvenColors.fieldBackground : CuvenColors.ctaInk,
                                    in: Capsule(style: .continuous)
                                )
                                .overlay {
                                    if isInstalled {
                                        Capsule(style: .continuous)
                                            .strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .disabled(isBusy)
                        .accessibilityLabel("\(isInstalled ? "Remove" : "Add") \(pack.title)")
                        .accessibilityIdentifier("sticker.packToggle.\(pack.name)")
                    }
                    .padding(12)
                    .background(
                        CuvenColors.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CuvenColors.cardLine, lineWidth: 0.8)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Helpers

    private func formatBadge(for format: StickerFormat) -> some View {
        let label: String
        let color: Color
        switch format {
        case .animatedLottie:
            label = "Animated"
            color = CuvenColors.sidebarBlue
        case .videoWebM:
            label = "Video"
            color = CuvenColors.momentsSkyBlue
        case .staticWebP:
            label = "WebP"
            color = CuvenColors.inkSecondary
        }

        return Text(label)
            .font(CuvenFonts.cappedCaption2(weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    @MainActor
    private func toggleCatalogPack(_ pack: StickerPack, currentlyInstalled: Bool) async {
        guard !togglingPackNames.contains(pack.name) else { return }
        togglingPackNames.insert(pack.name)
        defer { togglingPackNames.remove(pack.name) }

        await store.toggleStickerPackInstalled(packName: pack.name)
        if !currentlyInstalled {
            CuvenHaptics.success()
            selectedPackName = pack.name
        } else {
            CuvenHaptics.lightTap()
            if selectedPackName?.caseInsensitiveCompare(pack.name) == .orderedSame {
                selectedPackName = installedPacks.first?.name
            }
        }
    }
}

// MARK: - Subtle Spring Bounce for Borderless Sticker Tap

private struct StickerCellBounceButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .animation(
                reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.pressBounce,
                value: configuration.isPressed
            )
    }
}

// MARK: - Companion Public Entry Points (`DISPATCH.md` Compatibility)

/// Companion entry point forwarding `onSelect` directly to `StickerDrawerSheet`.
public struct StickerPickerDrawerView: View {
    private let store: AppStore
    private let onSelect: (StickerItem) -> Void

    public init(
        store: AppStore,
        onSelect: @escaping (StickerItem) -> Void
    ) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        StickerDrawerSheet(store: store, onSelectSticker: onSelect)
    }
}

/// Standalone 14-Pack Telegram Sticker Catalog Management Sheet.
public struct StickerCatalogSheet: View {
    private let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var togglingPacks: Set<String> = []

    public init(store: AppStore) {
        self.store = store
    }

    private var catalogPacks: [StickerPack] {
        CuvenStickerCatalogRegistry.mergedCatalogPacks(
            storePacks: store.stickerPacks,
            serverBaseURL: store.serverBaseURL
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(catalogPacks) { pack in
                        let installed = CuvenStickerCatalogRegistry.isPackInstalled(
                            pack.name,
                            in: store.installedStickerPackNames
                        )
                        HStack(spacing: 14) {
                            if let cover = pack.stickers.first {
                                AnimatedStickerRenderer(
                                    sticker: cover,
                                    size: 52,
                                    serverBaseURL: store.serverBaseURL
                                )
                                .frame(width: 56, height: 56)
                                .background(
                                    CuvenColors.fieldBackground,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(pack.title)
                                    .font(CuvenFonts.cappedBody(weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkPrimary)
                                Text("\(pack.stickers.count) stickers")
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                            }

                            Spacer()

                            Button {
                                guard !togglingPacks.contains(pack.name) else { return }
                                togglingPacks.insert(pack.name)
                                Task {
                                    await store.toggleStickerPackInstalled(packName: pack.name)
                                    CuvenHaptics.selectionChanged()
                                    togglingPacks.remove(pack.name)
                                }
                            } label: {
                                Text(installed ? "Remove" : "Add")
                                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                                    .foregroundStyle(installed ? CuvenColors.inkPrimary : CuvenColors.onCtaInk)
                                    .padding(.horizontal, 16)
                                    .frame(minWidth: 82, minHeight: 40)
                                    .background(
                                        installed ? CuvenColors.fieldBackground : CuvenColors.ctaInk,
                                        in: Capsule(style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                        .padding(12)
                        .background(
                            CuvenColors.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                }
                .padding(16)
            }
            .background(CuvenColors.paperBackground.ignoresSafeArea())
            .navigationTitle("Sticker Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
