//
//  DuoRailView.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Vertical controls & Toolbars
//  - Human Interface Guidelines › Toolbars › Overflow Menus (bottom-up priority collapse into single ellipsis menu;
//    primary Back/Close never overflows; badged items receive priority boost)
//  - Cuven Web Parity: `public/js/ui/bars.js:27-175`, `public/css/rail.css:17-82`, `design-qa.md:70-73, 137-156`
//    (`52pt` width, centered `49pt` from right physical edge, `170pt` outer portrait / `118pt` inner top reserve,
//    `44×44pt` circular hit targets inside `4pt` Liquid Glass capsules)
//

import CuvenCore
import SwiftUI

// MARK: - Rail Action Item & Group Models (`bars.js:42-45`)

/// Declarative action descriptor for `DuoRailView` and `AdaptiveActionBars`, supporting priority-ordered
/// bottom-up overflow into a single `More` (`ellipsis`) menu.
public struct DuoActionBarItem: Identifiable {
    public let id: String
    public let systemImage: String
    public let title: String
    public let priority: Int
    public let isPrimaryNavigation: Bool
    public let isActive: Bool
    public let isDisabled: Bool
    public let badgeText: String?
    public let accessibilityID: String?
    public let action: @MainActor () -> Void

    public init(
        id: String,
        systemImage: String,
        title: String,
        priority: Int = 0,
        isPrimaryNavigation: Bool = false,
        isActive: Bool = false,
        isDisabled: Bool = false,
        badgeText: String? = nil,
        accessibilityID: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.systemImage = systemImage
        self.title = title
        self.priority = priority
        self.isPrimaryNavigation = isPrimaryNavigation
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.badgeText = badgeText
        self.accessibilityID = accessibilityID
        self.action = action
    }

    /// Priority weight matching `bars.js:40, 87` (`BADGE_BOOST = 10`; primary navigation never overflows).
    var effectiveWeight: Int {
        if isPrimaryNavigation { return Int.max }
        let boost = (badgeText?.isEmpty == false) ? 10 : 0
        return priority + boost
    }
}

/// Logical grouping of 1 or more items rendered either as a standalone `44pt` circle (1 item)
/// or a `52pt`-wide (`4pt` inset + `44pt` buttons, `2pt` internal spacing) Liquid Glass capsule (`>1` items).
public struct DuoActionBarGroup: Identifiable {
    public let id: String
    public let items: [DuoActionBarItem]

    public init(id: String, items: [DuoActionBarItem]) {
        self.id = id
        self.items = items
    }
}

// MARK: - DuoRailView (`shell.duoRail`)

/// Vertical `52pt`-wide Liquid Glass control rail standing inside iPhone Duo's asymmetric right-edge
/// status/camera column (`centerX = viewportWidth - 49pt`, below clock & Silent bell at `170pt` outer / `118pt` inner).
public struct DuoRailView: View {
    public let topGroups: [DuoActionBarGroup]
    public let bottomGroups: [DuoActionBarGroup]
    public let glassMode: GlassAppearanceMode
    public let panLeadBackOffset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Exact geometry constants from `public/js/ui/bars.js:32-39` & `public/css/rail.css:18`.
    public static let railWidth: CGFloat = 52
    public static let buttonSize: CGFloat = 44
    public static let capsulePadding: CGFloat = 4
    public static let intraCapsuleGap: CGFloat = 2
    public static let interGroupGap: CGFloat = 10
    public static let sectionSeparationMin: CGFloat = 20

    public init(
        topGroups: [DuoActionBarGroup],
        bottomGroups: [DuoActionBarGroup] = [],
        glassMode: GlassAppearanceMode = .clear,
        panLeadBackOffset: CGFloat = 0
    ) {
        self.topGroups = topGroups
        self.bottomGroups = bottomGroups
        self.glassMode = glassMode
        self.panLeadBackOffset = panLeadBackOffset
    }

    public var body: some View {
        GeometryReader { proxy in
            let plan = Self.computeOverflowPlan(
                topGroups: topGroups,
                bottomGroups: bottomGroups,
                availableHeight: proxy.size.height
            )

            VStack(spacing: 0) {
                if !plan.visibleTop.isEmpty {
                    VStack(spacing: Self.interGroupGap) {
                        ForEach(plan.visibleTop) { entry in
                            renderGroupEntry(entry, overflowItems: plan.overflowItems)
                        }
                    }
                }

                Spacer(minLength: (!plan.visibleTop.isEmpty && !plan.visibleBottom.isEmpty) ? Self.sectionSeparationMin : 0)

                if !plan.visibleBottom.isEmpty {
                    VStack(spacing: Self.interGroupGap) {
                        ForEach(plan.visibleBottom) { entry in
                            renderGroupEntry(entry, overflowItems: plan.overflowItems)
                        }
                    }
                }
            }
            .frame(width: Self.railWidth, height: proxy.size.height, alignment: .top)
        }
        .frame(width: Self.railWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.duoRail")
        .accessibilityLabel("Column actions")
    }

    // MARK: - Group & Button Rendering

    @ViewBuilder
    private func renderGroupEntry(
        _ entry: ResolvedRailGroup,
        overflowItems: [DuoActionBarItem]
    ) -> some View {
        switch entry.kind {
        case .overflowMenu:
            overflowEllipsisMenu(items: overflowItems)

        case .items(let items):
            if items.count == 1, let single = items.first {
                railButton(for: single, insideMultiCapsule: false)
                    .offset(x: single.isPrimaryNavigation && single.id == "back" ? panLeadBackOffset : 0)
            } else {
                VStack(spacing: Self.intraCapsuleGap) {
                    ForEach(items) { item in
                        railButton(for: item, insideMultiCapsule: true)
                    }
                }
                .padding(Self.capsulePadding)
                .cuvenLiquidGlass(
                    mode: glassMode,
                    cornerRadius: Self.railWidth / 2,
                    interactiveBounce: false
                )
            }
        }
    }

    @ViewBuilder
    private func railButton(for item: DuoActionBarItem, insideMultiCapsule: Bool) -> some View {
        Button {
            guard !item.isDisabled else { return }
            CuvenHaptics.lightTap()
            item.action()
        } label: {
            ZStack {
                if item.isActive {
                    Circle()
                        .fill(CuvenColors.ctaInk)
                }

                Image(systemName: item.systemImage)
                    .font(.system(size: 18.5, weight: item.isPrimaryNavigation ? .semibold : .medium))
                    .foregroundStyle(item.isActive ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                    .symbolRenderingMode(.hierarchical)

                if let badge = item.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .padding(.horizontal, 4.5)
                        .frame(minWidth: 17, minHeight: 16)
                        .background(CuvenColors.ctaInk, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(CuvenColors.paperBackground, lineWidth: 1.75)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 3, y: -3)
                }
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .contentShape(Circle())
            .modifier(
                StandaloneRailCircleGlassModifier(
                    isEnabled: !insideMultiCapsule && !item.isActive,
                    glassMode: glassMode
                )
            )
        }
        .buttonStyle(DuoRailItemPressStyle())
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.40 : 1.0)
        .accessibilityIdentifier(item.accessibilityID ?? "shell.duoRail.\(item.id)")
        .accessibilityLabel(
            (item.badgeText?.isEmpty == false)
                ? "\(item.title), \(item.badgeText ?? "")"
                : item.title
        )
        .accessibilityAddTraits(item.isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private func overflowEllipsisMenu(items: [DuoActionBarItem]) -> some View {
        Menu {
            ForEach(items) { item in
                Button {
                    CuvenHaptics.lightTap()
                    item.action()
                } label: {
                    let labelText = (item.badgeText?.isEmpty == false)
                        ? "\(item.title) (\(item.badgeText ?? ""))"
                        : item.title
                    Label(labelText, systemImage: item.systemImage)
                }
                .disabled(item.isDisabled)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Circle())
                .cuvenLiquidGlass(
                    mode: glassMode,
                    cornerRadius: Self.buttonSize / 2,
                    interactiveBounce: true
                )
        }
        .accessibilityIdentifier("shell.duoRail.more")
        .accessibilityLabel("More actions")
    }

    // MARK: - Genuine Priority-Based Bottom-Up Overflow Solver (`bars.js:88-146`)

    struct ResolvedRailGroup: Identifiable {
        enum Kind {
            case items([DuoActionBarItem])
            case overflowMenu
        }
        let id: String
        let kind: Kind

        var itemCount: Int {
            switch kind {
            case .items(let list): return list.count
            case .overflowMenu: return 1
            }
        }
    }

    struct OverflowLayoutPlan {
        let visibleTop: [ResolvedRailGroup]
        let visibleBottom: [ResolvedRailGroup]
        let overflowItems: [DuoActionBarItem]
    }

    static func computeOverflowPlan(
        topGroups: [DuoActionBarGroup],
        bottomGroups: [DuoActionBarGroup],
        availableHeight: CGFloat
    ) -> OverflowLayoutPlan {
        let allOrderedItems = (topGroups + bottomGroups).flatMap(\.items)
        guard !allOrderedItems.isEmpty else {
            return OverflowLayoutPlan(visibleTop: [], visibleBottom: [], overflowItems: [])
        }

        let effectiveBudget = availableHeight > 0 ? availableHeight : 10_000
        let moreGoesInTop = !topGroups.flatMap(\.items).isEmpty
        var hiddenIDs = Set<String>()

        func buildGroups(from source: [DuoActionBarGroup], includeMore: Bool) -> [ResolvedRailGroup] {
            var resolved: [ResolvedRailGroup] = source.compactMap { group in
                let remaining = group.items.filter { !hiddenIDs.contains($0.id) }
                guard !remaining.isEmpty else { return nil }
                return ResolvedRailGroup(id: group.id, kind: .items(remaining))
            }
            if includeMore {
                // Per `bars.js:98-100`: in vertical rail, `More` stands right after primary `Back`/`Close`.
                let insertIndex: Int
                if let first = resolved.first,
                   case .items(let leadItems) = first.kind,
                   leadItems.allSatisfy(\.isPrimaryNavigation) {
                    insertIndex = 1
                } else {
                    insertIndex = 0
                }
                resolved.insert(
                    ResolvedRailGroup(id: "__overflow_more__", kind: .overflowMenu),
                    at: min(insertIndex, resolved.count)
                )
            }
            return resolved
        }

        func sectionHeight(_ groups: [ResolvedRailGroup]) -> CGFloat {
            guard !groups.isEmpty else { return 0 }
            let blocks = groups.reduce(CGFloat(0)) { partial, group in
                let n = group.itemCount
                let blockH: CGFloat = (n > 1)
                    ? (capsulePadding * 2 + CGFloat(n) * buttonSize + CGFloat(n - 1) * intraCapsuleGap)
                    : buttonSize
                return partial + blockH
            }
            let gaps = CGFloat(max(0, groups.count - 1)) * interGroupGap
            return blocks + gaps
        }

        func fitsCurrentSelection() -> Bool {
            let hasHidden = !hiddenIDs.isEmpty
            let top = buildGroups(from: topGroups, includeMore: hasHidden && moreGoesInTop)
            let bottom = buildGroups(from: bottomGroups, includeMore: hasHidden && !moreGoesInTop)
            let topH = sectionHeight(top)
            let bottomH = sectionHeight(bottom)
            let sep = (topH > 0 && bottomH > 0) ? sectionSeparationMin : 0
            return (topH + bottomH + sep) <= effectiveBudget
        }

        // Lowest priority overflows first; ties broken from bottom-up (`b.index - a.index` in `bars.js:140`).
        let candidates = allOrderedItems.enumerated()
            .filter { !$0.element.isPrimaryNavigation }
            .sorted { lhs, rhs in
                if lhs.element.effectiveWeight != rhs.element.effectiveWeight {
                    return lhs.element.effectiveWeight < rhs.element.effectiveWeight
                }
                return lhs.offset > rhs.offset
            }

        for candidate in candidates {
            if fitsCurrentSelection() { break }
            hiddenIDs.insert(candidate.element.id)
        }

        let hasOverflow = !hiddenIDs.isEmpty
        let finalTop = buildGroups(from: topGroups, includeMore: hasOverflow && moreGoesInTop)
        let finalBottom = buildGroups(from: bottomGroups, includeMore: hasOverflow && !moreGoesInTop)
        let overflowList = allOrderedItems.filter { hiddenIDs.contains($0.id) }

        return OverflowLayoutPlan(
            visibleTop: finalTop,
            visibleBottom: finalBottom,
            overflowItems: overflowList
        )
    }
}

private struct StandaloneRailCircleGlassModifier: ViewModifier {
    let isEnabled: Bool
    let glassMode: GlassAppearanceMode

    func body(content: Content) -> some View {
        if isEnabled {
            content.cuvenLiquidGlass(
                mode: glassMode,
                cornerRadius: DuoRailView.buttonSize / 2,
                interactiveBounce: true
            )
        } else {
            content
        }
    }
}

private struct DuoRailItemPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1.0)
            .animation(
                CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}
