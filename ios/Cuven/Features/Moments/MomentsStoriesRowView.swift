// MomentsStoriesRowView.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Horizontal active-friends Stories / Recent Moments ring shelf (`public/js/views/moments.js:134-148`,
// `public/css/moments.css:66-115`):
// - Slot 0: "Your moment" with `64pt` avatar inside a `74pt` ring + blue `+` badge -> opens Composer.
// - Subsequent slots: Unique Moment authors & active friends sorted by unseen freshness first, then
//   latest post timestamp; conic rainbow ring on unseen moments; `person.badge.plus` badge on strangers.

import SwiftUI
import CuvenCore

struct MomentsStoryPersonEntry: Identifiable, Equatable {
    let user: CuvenUser
    let latestTimestamp: Int64
    let isFresh: Bool
    let isFriend: Bool
    var id: String { user.id }
}

struct MomentsStoriesRowView: View {
    let currentUser: CuvenUser?
    let entries: [MomentsStoryPersonEntry]
    let trailingInset: CGFloat
    let onComposeTap: () -> Void
    let onPersonTap: (CuvenUser) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                // Slot 0: "Your moment" (`moments.js:135-138`)
                MomentsStoryRingButton(
                    name: currentUser?.display ?? "You",
                    avatarURL: currentUser?.avatarURL,
                    caption: "Your moment",
                    hasFreshRing: false,
                    badgeKind: .composePlus,
                    accessibilityText: "Share a moment",
                    action: {
                        CuvenHaptics.lightTap()
                        onComposeTap()
                    }
                )
                .accessibilityIdentifier("moments.stories.compose")

                // Active friends & public Moment authors (`moments.js:140-147`)
                ForEach(entries) { entry in
                    MomentsStoryRingButton(
                        name: entry.user.display.isEmpty ? entry.user.username : entry.user.display,
                        avatarURL: entry.user.avatarURL,
                        caption: entry.user.display.isEmpty ? entry.user.username : entry.user.display,
                        hasFreshRing: entry.isFresh,
                        badgeKind: entry.isFriend ? .none : .strangerAdd,
                        accessibilityText: accessibilityDescription(for: entry),
                        action: {
                            CuvenHaptics.selectionChanged()
                            onPersonTap(entry.user)
                        }
                    )
                    .accessibilityIdentifier("moments.stories.person.\(entry.user.id)")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, max(14, trailingInset))
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CuvenColors.hairlineSeparator)
                .frame(height: 0.5)
        }
        .accessibilityIdentifier("moments.storiesRow")
    }

    private func accessibilityDescription(for entry: MomentsStoryPersonEntry) -> String {
        let display = entry.user.display.isEmpty ? entry.user.username : entry.user.display
        var parts = [display]
        if entry.isFresh {
            parts.append("new moments")
        }
        if !entry.isFriend {
            parts.append("you've not talked yet")
        }
        return parts.joined(separator: ", ")
    }
}

private enum StoryBadgeKind: Equatable {
    case none
    case composePlus
    case strangerAdd
}

private struct MomentsStoryRingButton: View {
    let name: String
    let avatarURL: String?
    let caption: String
    let hasFreshRing: Bool
    let badgeKind: StoryBadgeKind
    let accessibilityText: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if hasFreshRing {
                            Circle()
                                .strokeBorder(MomentsPalette.freshStoryRingGradient, lineWidth: 2.6)
                                .frame(width: 74, height: 74)
                        } else {
                            Circle()
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1.0)
                                .frame(width: 74, height: 74)
                        }

                        CuvenAvatarView(
                            name: name,
                            urlString: avatarURL,
                            size: 64,
                            isOnline: false
                        )
                    }
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                    .animation(reduceMotion ? nil : CuvenSprings.pressBounce, value: isPressed)

                    if badgeKind != .none {
                        badgeOverlay
                            .offset(x: -1, y: -1)
                    }
                }
                .frame(width: 74, height: 74)

                Text(caption)
                    .font(CuvenFonts.cappedCaption(weight: .regular))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(1)
                    .frame(width: 82)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(StoryPressFeedbackStyle(isPressed: $isPressed))
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var badgeOverlay: some View {
        switch badgeKind {
        case .none:
            EmptyView()
        case .composePlus:
            Circle()
                .fill(CuvenColors.systemBlue)
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle()
                        .strokeBorder(CuvenColors.paperBackground, lineWidth: 2.5)
                }
        case .strangerAdd:
            Circle()
                .fill(CuvenColors.ctaInk)
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CuvenColors.onCtaInk)
                }
                .overlay {
                    Circle()
                        .strokeBorder(CuvenColors.paperBackground, lineWidth: 2.5)
                }
        }
    }
}

private struct StoryPressFeedbackStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}
