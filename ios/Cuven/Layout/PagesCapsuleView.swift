//
//  PagesCapsuleView.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Vertical controls & Tab bars
//  - Human Interface Guidelines › Materials › Liquid Glass & Accessibility (44×44pt hit targets)
//  - Cuven Web Parity: `public/js/ui/pages.js:1-166`, `public/css/pages.css:1-97`
//    (`52×282pt` capsule, 6 × `44pt` circular slots: `Chats`, `Moments`, `Memories`, `Friends`, `You`, `Menu`,
//    gliding `.page-thumb` circle, red numeric pending-requests badge on `Friends`, unread dot on `Moments`)
//

import CuvenCore
import SwiftUI

/// Floating vertical `52×282pt` Liquid Glass page-switcher capsule anchored at the foot of iPhone Duo's
/// right-edge status column (`centerX = width - 49pt`, aligned directly under the Duo clock).
public struct PagesCapsuleView: View {
    private let store: AppStore
    public let metrics: DuoLayoutMetrics
    public let onSelectPage: (NavigationPage) -> Void

    @Namespace private var thumbNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Exact dimensions from `public/css/pages.css:7, 15-21, 38-40`:
    /// `4pt` top padding + `6 × 44pt` items + `5 × 2pt` gaps + `4pt` bottom padding = `282pt` height, `52pt` width.
    public static let capsuleWidth: CGFloat = 52
    public static let capsuleHeight: CGFloat = 282
    public static let itemDiameter: CGFloat = 44
    public static let itemSpacing: CGFloat = 2
    public static let outerPadding: CGFloat = 4

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        onSelectPage: @escaping (NavigationPage) -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onSelectPage = onSelectPage
    }

    /// Pending incoming friend requests count for the red badge on `Friends` (`pages.js:126-127`).
    private var pendingFriendRequestCount: Int {
        store.contacts.reduce(into: 0) { count, item in
            if item.status == .pendingIn {
                count += 1
            }
        }
    }

    /// Total unread messages across non-hidden rooms for `Chats` awareness.
    private var unreadRoomsCount: Int {
        store.rooms.reduce(into: 0) { count, room in
            if !room.isHidden && (room.unreadCount > 0 || room.isMarkedUnread) {
                count += 1
            }
        }
    }

    /// Indicates whether friends have shared recent Moments while not currently viewing `.moments`.
    private var hasFreshMomentsDot: Bool {
        store.activePage != .moments && !store.moments.isEmpty
    }

    /// Resolves the visually highlighted slot (`pages.js:50` `current = () => page?.id || column`).
    private var highlightedPage: NavigationPage {
        switch store.activePage {
        case .moments, .memories, .friends, .you:
            return store.activePage
        case .chats, .menu:
            if store.activeColumnIndex == 0 && store.activePage == .menu {
                return .menu
            }
            if store.activeColumnIndex == 0 && metrics.visibleColumnCount == 1 {
                return .menu
            }
            return .chats
        }
    }

    public var body: some View {
        VStack(spacing: Self.itemSpacing) {
            ForEach(NavigationPage.allCases) { page in
                pageSlotButton(for: page)
            }
        }
        .padding(Self.outerPadding)
        .frame(width: Self.capsuleWidth, height: Self.capsuleHeight)
        .cuvenLiquidGlass(
            mode: store.prefs.glassMode,
            cornerRadius: Self.capsuleWidth / 2,
            interactiveBounce: false
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.pagesCapsule")
        .accessibilityLabel("Pages")
    }

    // MARK: - Individual 44×44pt Slot

    @ViewBuilder
    private func pageSlotButton(for page: NavigationPage) -> some View {
        let isSelected = (highlightedPage == page)
        let meta = metadata(for: page)
        let badge = badgeState(for: page)

        Button {
            CuvenHaptics.selectionChanged()
            withAnimation(CuvenSprings.adaptive(.spring(response: 0.30, dampingFraction: 0.84), reduceMotion: reduceMotion)) {
                onSelectPage(page)
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.16)
                                : Color.black.opacity(0.08)
                        )
                        .matchedGeometryEffect(id: "pages.activeThumb", in: thumbNamespace)
                }

                Image(systemName: isSelected ? meta.filledSymbol : meta.symbol)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkPrimary.opacity(0.82))
                    .symbolRenderingMode(.hierarchical)
                    .scaleEffect(isSelected ? 1.03 : 1.0)

                if let badge {
                    badgeOverlay(badge)
                }
            }
            .frame(width: Self.itemDiameter, height: Self.itemDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(PagesCapsuleSlotPressStyle())
        .accessibilityIdentifier("shell.pagesCapsule.\(page.rawValue)")
        .accessibilityLabel(accessibilityDescription(label: meta.label, badge: badge))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Metadata & Badges

    private struct PageMetadata {
        let label: String
        let symbol: String
        let filledSymbol: String
    }

    private func metadata(for page: NavigationPage) -> PageMetadata {
        switch page {
        case .chats:
            return PageMetadata(
                label: "Chats",
                symbol: "bubble.left.and.bubble.right",
                filledSymbol: "bubble.left.and.bubble.right.fill"
            )
        case .moments:
            return PageMetadata(
                label: "Moments",
                symbol: "photo.on.rectangle.angled",
                filledSymbol: "photo.fill.on.rectangle.fill"
            )
        case .memories:
            return PageMetadata(
                label: "Memories",
                symbol: "sparkles.rectangle.stack",
                filledSymbol: "sparkles.rectangle.stack.fill"
            )
        case .friends:
            return PageMetadata(
                label: "Friends",
                symbol: "bell",
                filledSymbol: "bell.fill"
            )
        case .you:
            return PageMetadata(
                label: "You",
                symbol: "person.crop.circle",
                filledSymbol: "person.crop.circle.fill"
            )
        case .menu:
            return PageMetadata(
                label: "Menu",
                symbol: "line.3.horizontal",
                filledSymbol: "line.3.horizontal"
            )
        }
    }

    private enum SlotBadge: Equatable {
        case count(String)
        case dot
    }

    private func badgeState(for page: NavigationPage) -> SlotBadge? {
        switch page {
        case .friends:
            let count = pendingFriendRequestCount
            guard count > 0 else { return nil }
            return .count(count > 9 ? "9+" : "\(count)")
        case .moments:
            return hasFreshMomentsDot ? .dot : nil
        case .chats:
            let count = unreadRoomsCount
            guard count > 0, highlightedPage != .chats else { return nil }
            return .count(count > 99 ? "99+" : "\(count)")
        case .memories, .you, .menu:
            return nil
        }
    }

    @ViewBuilder
    private func badgeOverlay(_ badge: SlotBadge) -> some View {
        switch badge {
        case .dot:
            Circle()
                .fill(CuvenColors.dangerRed)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle()
                        .strokeBorder(CuvenColors.paperBackground, lineWidth: 1.75)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 7)
                .padding(.trailing, 7)

        case .count(let text):
            Text(text)
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 17, minHeight: 17)
                .background(CuvenColors.dangerRed, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(CuvenColors.paperBackground, lineWidth: 1.75)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 1, y: 2)
        }
    }

    private func accessibilityDescription(label: String, badge: SlotBadge?) -> String {
        guard let badge else { return label }
        switch badge {
        case .dot:
            return "\(label), new"
        case .count(let countText):
            return "\(label), \(countText) waiting"
        }
    }
}

/// Tactile `0.90` scale press feedback matching `pages.css:49` (`.page-item:active .icon { transform: scale(.88) }`).
private struct PagesCapsuleSlotPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.90 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78),
                value: configuration.isPressed
            )
    }
}
