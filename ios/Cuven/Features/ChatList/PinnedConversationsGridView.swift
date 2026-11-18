import SwiftUI
import CuvenCore

// MARK: - Pinned Conversations Grid (`chatlist.pinnedGrid`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Designing for iPhone Duo (adaptive column count that
//   divides cleanly without clipping inside narrow 342pt split columns or Duo Closed outer screen)
// - Apple Human Interface Guidelines: Gestures & Context Menus (spring jiggle unpin mode +
//   blurred live room preview context menu)
// - Cuven Web Reference: `public/js/views/chatList.js:365-387, 471-489`, `public/css/list.css:86-98`

public struct PinnedConversationsGridView: View {
    private let store: AppStore
    private let rooms: [Room]
    private let metrics: DuoLayoutMetrics
    private let onDeleteRoom: (Room) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isJiggling = false
    @State private var jigglePhase = false

    public init(
        store: AppStore,
        rooms: [Room],
        metrics: DuoLayoutMetrics,
        onDeleteRoom: @escaping (Room) -> Void
    ) {
        self.store = store
        self.rooms = rooms
        self.metrics = metrics
        self.onDeleteRoom = onDeleteRoom
    }

    private var availableWidth: CGFloat {
        ChatListSpatialMetrics.effectiveColumnWidth(for: metrics)
    }

    /// Uses 3 columns on compact `< 360pt` columns (`DISPATCH.md` item 1) and 4 columns on wider
    /// viewports (`Spec Miner 2 § 4.3` `54pt` squircle grid) so tiles never crowd or clip.
    private var columnCount: Int {
        availableWidth < 360 ? 3 : 4
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }

    private var horizontalInset: CGFloat {
        metrics.visibleColumnCount == 2 ? 14 : 16
    }

    private var trailingSafePadding: CGFloat {
        ChatListSpatialMetrics.trailingSystemColumnInset(for: metrics)
    }

    public var body: some View {
        if !rooms.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Eyebrow label + Edit/Done jiggle unpin toggle (`list.css:88-89`)
                HStack(spacing: 5) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                    Text("PINNED")
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.semibold)
                        .tracking(0.6)
                        .foregroundStyle(CuvenColors.inkSecondary)

                    Spacer()

                    if isJiggling {
                        Button {
                            CuvenHaptics.lightTap()
                            exitJiggleMode()
                        } label: {
                            Text("Done")
                                .font(CuvenFonts.cappedCaption())
                                .fontWeight(.semibold)
                                .foregroundStyle(ChatListPalette.accessibleBlueText)
                                .padding(.horizontal, 10)
                                .frame(minWidth: 44, minHeight: 32)
                                .background(Capsule().fill(ChatListPalette.subtleChipFill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chatlist.pinnedGrid.doneButton")
                    }
                }
                .padding(.leading, horizontalInset + 4 + metrics.safeAreaLeft)
                .padding(.trailing, horizontalInset + 4 + trailingSafePadding)

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(Array(rooms.prefix(12).enumerated()), id: \.element.id) { index, room in
                        PinnedConversationTile(
                            store: store,
                            room: room,
                            avatarSize: metrics.visibleColumnCount == 2 ? 48 : 54,
                            isSelected: metrics.visibleColumnCount == 2 && store.selectedRoomID == room.id,
                            isOnline: isPeerOnline(for: room),
                            isJiggling: isJiggling,
                            jiggleAngle: jiggleAngle(for: index),
                            onTap: {
                                if isJiggling {
                                    CuvenHaptics.rigidImpact()
                                    withAnimation(CuvenSprings.pressBounce) {
                                        store.toggleRoomPin(room.id)
                                    }
                                    if rooms.count <= 1 {
                                        exitJiggleMode()
                                    }
                                } else {
                                    CuvenHaptics.selectionChanged()
                                    store.selectRoom(room.id)
                                }
                            },
                            onUnpin: {
                                CuvenHaptics.rigidImpact()
                                withAnimation(CuvenSprings.pressBounce) {
                                    store.toggleRoomPin(room.id)
                                }
                                if rooms.count <= 1 {
                                    exitJiggleMode()
                                }
                            },
                            onEnterJiggle: {
                                enterJiggleMode()
                            },
                            onDelete: {
                                onDeleteRoom(room)
                            }
                        )
                        .accessibilityIdentifier("chatlist.pinned.\(room.id)")
                    }
                }
                .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                .padding(.trailing, horizontalInset + trailingSafePadding)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(CuvenColors.hairlineSeparator)
                    .frame(height: 0.6)
                    .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                    .padding(.trailing, horizontalInset + trailingSafePadding)
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .accessibilityIdentifier("chatlist.pinnedGrid")
            .onChange(of: rooms.isEmpty) { _, empty in
                if empty {
                    exitJiggleMode()
                }
            }
        }
    }

    private func isPeerOnline(for room: Room) -> Bool {
        guard room.kind == .dm, let peerID = room.peerUserID else { return false }
        return store.contacts.first(where: { $0.user.id == peerID })?.user.isOnline ?? false
    }

    private func jiggleAngle(for index: Int) -> Double {
        guard isJiggling, !reduceMotion else { return 0 }
        let direction: Double = index.isMultiple(of: 2) ? 1.0 : -1.0
        return (jigglePhase ? 2.2 : -2.2) * direction
    }

    private func enterJiggleMode() {
        CuvenHaptics.softImpact()
        isJiggling = true
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
            jigglePhase = true
        }
    }

    private func exitJiggleMode() {
        withAnimation(CuvenSprings.pressBounce) {
            isJiggling = false
            jigglePhase = false
        }
    }
}

// MARK: - Pinned Squircle Tile (`list.css:91-98`)

private struct PinnedConversationTile: View {
    let store: AppStore
    let room: Room
    let avatarSize: CGFloat
    let isSelected: Bool
    let isOnline: Bool
    let isJiggling: Bool
    let jiggleAngle: Double
    let onTap: () -> Void
    let onUnpin: () -> Void
    let onEnterJiggle: () -> Void
    let onDelete: () -> Void

    private var effectiveUnreadCount: Int {
        max(room.unreadCount, room.isMarkedUnread ? 1 : 0)
    }

    private var squircleRadius: CGFloat {
        round(avatarSize * 0.32)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Squircle avatar with selected ring (`list.css:93, 97`)
                CuvenAvatarView(
                    name: room.title,
                    urlString: room.avatarURL,
                    size: avatarSize,
                    isOnline: isOnline
                )
                .clipShape(RoundedRectangle(cornerRadius: squircleRadius, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: squircleRadius + 3, style: .continuous)
                            .strokeBorder(ChatListPalette.messagesTitleBlue, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .rotationEffect(.degrees(jiggleAngle))

                // Unread count badge (`list.css:96`)
                if effectiveUnreadCount > 0 && !isJiggling {
                    Text(effectiveUnreadCount > 99 ? "99+" : "\(effectiveUnreadCount)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(room.isMuted ? CuvenColors.inkSecondary : ChatListPalette.unreadBadgeForeground)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(
                            Capsule()
                                .fill(room.isMuted ? ChatListPalette.subtleChipFill : ChatListPalette.unreadBadgeBackground)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(CuvenColors.paperBackground, lineWidth: 2.5)
                        )
                        .offset(x: 6, y: -4)
                }

                // Spring Unpin `-` badge in Jiggle Mode
                if isJiggling {
                    Button(action: onUnpin) {
                        ZStack {
                            Circle()
                                .fill(CuvenColors.elevatedSurface)
                                .frame(width: 22, height: 22)
                                .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(CuvenColors.dangerRed)
                        }
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -avatarSize + 14, y: -8)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Unpin \(room.title)")
                }
            }

            // Room title (`list.css:94-95`)
            HStack(spacing: 3) {
                if let typing = store.typingPreviewByRoom[room.id], !typing.isEmpty {
                    Text("typing…")
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.medium)
                        .foregroundStyle(ChatListPalette.accessibleBlueText)
                        .lineLimit(1)
                } else {
                    Text(room.title)
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(effectiveUnreadCount > 0 ? .semibold : .regular)
                        .foregroundStyle(effectiveUnreadCount > 0 ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 74)
        .contentShape(RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous))
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                CuvenHaptics.lightTap()
                store.toggleRoomUnread(room.id)
            } label: {
                Label(
                    effectiveUnreadCount > 0 ? "Mark as Read" : "Mark as Unread",
                    systemImage: effectiveUnreadCount > 0 ? "checkmark.message" : "envelope.badge"
                )
            }

            Button {
                CuvenHaptics.rigidImpact()
                withAnimation(CuvenSprings.pressBounce) {
                    store.toggleRoomPin(room.id)
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }

            Button {
                onEnterJiggle()
            } label: {
                Label("Rearrange / Unpin Pins", systemImage: "square.grid.2x2")
            }

            Button {
                CuvenHaptics.lightTap()
                store.toggleRoomMute(room.id)
            } label: {
                Label(
                    room.isMuted ? "Unmute" : "Mute",
                    systemImage: room.isMuted ? "bell" : "bell.slash"
                )
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Delete Conversation", systemImage: "trash")
            }
        } preview: {
            RoomContextPreviewCard(store: store, room: room)
        }
    }
}
