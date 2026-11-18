import SwiftUI
import CuvenCore

// MARK: - 24h Friends Notes Shelf (`chatlist.notesStrip`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Designing for iPhone Duo (safe-area-aware horizontal
//   scroll margins clear of the 84–91pt right system column)
// - Apple Human Interface Guidelines: Sheets & Modality (adaptive modal note composer & quick-reply)
// - Apple Human Interface Guidelines: Accessibility (>= 44x44pt hit targets, descriptive labels)
// - Cuven Web Reference: `public/js/views/people.js:48-172`, `public/css/people.css:8-105`

public struct NotesStripView: View {
    public static let maxNoteCharacters: Int = 60

    private let store: AppStore
    private let metrics: DuoLayoutMetrics

    @State private var isShowingMyNoteComposer = false
    @State private var selectedFriendNote: UserNote?
    @State private var nowTick = Date()

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    private var activeMyNote: UserNote? {
        guard let mine = store.myNote,
              !mine.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ChatListTimeFormatter.isNoteActive(mine, now: nowTick) else {
            return nil
        }
        return mine
    }

    private var activeFriendNotes: [UserNote] {
        let myID = store.currentUser?.id
        return store.notes
            .filter { note in
                note.userID != myID
                    && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ChatListTimeFormatter.isNoteActive(note, now: nowTick)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var horizontalInset: CGFloat {
        metrics.visibleColumnCount == 2 ? 14 : 16
    }

    private var trailingSafePadding: CGFloat {
        ChatListSpatialMetrics.trailingSystemColumnInset(for: metrics)
    }

    private var featuredMyNoteWidth: CGFloat {
        metrics.visibleColumnCount == 2 ? 186 : 212
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                // 1. Current user's prominent "Your note" composer slot (`people.js:62-64`)
                MyNoteFeaturedCell(
                    avatarName: store.currentUser?.display ?? "You",
                    avatarURL: store.currentUser?.avatarURL,
                    bubbleText: activeMyNote?.text ?? "Share a thought…",
                    isPlaceholder: activeMyNote == nil,
                    ageLabel: activeMyNote.map { ChatListTimeFormatter.noteAgeString(from: $0.createdAt, now: nowTick) },
                    cardWidth: featuredMyNoteWidth
                ) {
                    CuvenHaptics.lightTap()
                    isShowingMyNoteComposer = true
                }
                .accessibilityIdentifier("chatlist.notesStrip.myNote")

                // 2. Friends' active <24h notes, newest first (`people.js:65-70`)
                ForEach(activeFriendNotes) { note in
                    NoteAvatarCell(
                        displayName: note.userDisplay,
                        avatarName: note.userDisplay,
                        avatarURL: note.avatarURL,
                        bubbleText: note.text,
                        isPlaceholder: false,
                        isMine: false,
                        ageLabel: ChatListTimeFormatter.noteAgeString(from: note.createdAt, now: nowTick),
                        isOnline: isUserOnline(userID: note.userID)
                    ) {
                        CuvenHaptics.lightTap()
                        selectedFriendNote = note
                    }
                    .accessibilityIdentifier("chatlist.notesStrip.\(note.userID)")
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, horizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, horizontalInset + trailingSafePadding)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                CuvenHaptics.lightTap()
                isShowingMyNoteComposer = true
            }
        }
        .accessibilityIdentifier("chatlist.notesStrip")
        .accessibilityElement(children: .contain)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { tick in
            nowTick = tick
        }
        .sheet(isPresented: $isShowingMyNoteComposer) {
            MyNoteComposerSheetView(
                store: store,
                existingNote: activeMyNote,
                onDismiss: { isShowingMyNoteComposer = false }
            )
            .presentationDetents([.height(420), .medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .presentationBackground(CuvenColors.cardSurface)
        }
        .sheet(item: $selectedFriendNote) { friendNote in
            FriendNoteReplySheetView(
                store: store,
                note: friendNote,
                onDismiss: { selectedFriendNote = nil }
            )
            .presentationDetents([.height(410), .medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .presentationBackground(CuvenColors.cardSurface)
        }
    }

    private func isUserOnline(userID: String) -> Bool {
        store.contacts.first(where: { $0.user.id == userID })?.user.isOnline ?? false
    }
}

// MARK: - Featured Current-User Note Composer Card

private struct MyNoteFeaturedCell: View {
    let avatarName: String
    let avatarURL: String?
    let bubbleText: String
    let isPlaceholder: Bool
    let ageLabel: String?
    let cardWidth: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    CuvenAvatarView(
                        name: avatarName,
                        urlString: avatarURL,
                        size: 58,
                        isOnline: true
                    )

                    ZStack {
                        Circle()
                            .fill(CuvenColors.ctaInk)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(CuvenColors.paperBackground, lineWidth: 2.2)
                            )
                        Image(systemName: isPlaceholder ? "plus" : "pencil")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(CuvenColors.onCtaInk)
                    }
                    .offset(x: 2, y: 2)
                    .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(bubbleText)
                        .font(CuvenFonts.cappedCaption(weight: isPlaceholder ? .regular : .semibold))
                        .foregroundStyle(isPlaceholder ? ChatListPalette.tertiaryInk : CuvenColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 4) {
                        Text("Your note")
                            .font(CuvenFonts.cappedCaption2(weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)
                        if let ageLabel {
                            Text("· \(ageLabel)")
                                .font(CuvenFonts.cappedCaption2())
                                .foregroundStyle(ChatListPalette.tertiaryInk)
                        } else {
                            Text("· 24h")
                                .font(CuvenFonts.cappedCaption2())
                                .foregroundStyle(ChatListPalette.tertiaryInk)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: cardWidth)
            .frame(minHeight: 86)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(CuvenColors.elevatedSurface)
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(CuvenSprings.pressBounce, value: isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(NoteCellPressStyle(isPressed: $isPressed))
        .accessibilityLabel(isPlaceholder ? "Share a note" : "Your note: \(bubbleText)")
    }
}

// MARK: - Individual Note Cell (`people.css:22-75`)

private struct NoteAvatarCell: View {
    let displayName: String
    let avatarName: String
    let avatarURL: String?
    let bubbleText: String
    let isPlaceholder: Bool
    let isMine: Bool
    let ageLabel: String?
    var isOnline: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    // Avatar positioned below the floating thought bubble
                    ZStack(alignment: .bottomTrailing) {
                        CuvenAvatarView(
                            name: avatarName,
                            urlString: avatarURL,
                            size: 60,
                            isOnline: isOnline
                        )

                        if isMine && isPlaceholder {
                            ZStack {
                                Circle()
                                    .fill(CuvenColors.inkPrimary)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(CuvenColors.paperBackground, lineWidth: 2.5)
                                    )
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(CuvenColors.paperBackground)
                            }
                            .offset(x: 3, y: 3)
                            .accessibilityHidden(true)
                        }
                    }
                    .padding(.top, 36)
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                    .animation(CuvenSprings.pressBounce, value: isPressed)

                    // Floating speech thought-bubble (`people.css:55-74`)
                    VStack(spacing: 1.5) {
                        Text(bubbleText)
                            .font(CuvenFonts.cappedCaption())
                            .fontWeight(isPlaceholder ? .regular : .medium)
                            .foregroundStyle(isPlaceholder ? ChatListPalette.tertiaryInk : CuvenColors.inkPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6.5)
                            .frame(minWidth: 50, maxWidth: 96)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(CuvenColors.elevatedSurface)
                                    .shadow(color: Color.black.opacity(0.12), radius: 7, x: 0, y: 3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
                            )

                        // Authentic thought-bubble trailing droplets
                        HStack(spacing: 2) {
                            Circle()
                                .fill(CuvenColors.elevatedSurface)
                                .frame(width: 6.5, height: 6.5)
                                .overlay(Circle().strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.6))
                            Circle()
                                .fill(CuvenColors.elevatedSurface)
                                .frame(width: 3.8, height: 3.8)
                                .offset(y: 2.5)
                        }
                        .offset(x: -8, y: -1)
                    }
                }

                Text(displayName)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(isMine ? ChatListPalette.tertiaryInk : CuvenColors.inkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 92)
            }
            .frame(width: 98)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoteCellPressStyle(isPressed: $isPressed))
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        if isMine {
            return isPlaceholder ? "Share a note" : "Your note: \(bubbleText)"
        }
        if let ageLabel {
            return "\(displayName)'s note: \(bubbleText), \(ageLabel) ago"
        }
        return "\(displayName)'s note: \(bubbleText)"
    }
}

private struct NoteCellPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

// MARK: - Current User Note Composer Modal (`people.js:105-142`)

private struct MyNoteComposerSheetView: View {
    let store: AppStore
    let existingNote: UserNote?
    let onDismiss: () -> Void

    @State private var draftText: String
    @State private var isSubmitting = false
    @FocusState private var isInputFocused: Bool

    init(store: AppStore, existingNote: UserNote?, onDismiss: @escaping () -> Void) {
        self.store = store
        self.existingNote = existingNote
        self.onDismiss = onDismiss
        _draftText = State(initialValue: existingNote?.text ?? "")
    }

    private var sanitizedDraft: String {
        draftText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private var trimmedDraft: String {
        sanitizedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var characterCount: Int {
        sanitizedDraft.count
    }

    private var canShare: Bool {
        !isSubmitting
            && !trimmedDraft.isEmpty
            && trimmedDraft.count <= NotesStripView.maxNoteCharacters
    }

    var body: some View {
        VStack(spacing: 18) {
            // Sheet Top Bar: Cancel | Note | Share (`people.css:223-226`)
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22, interactiveBounce: true)
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("chatlist.noteComposer.cancel")

                Spacer()

                Text("Note")
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkPrimary)

                Spacer()

                Button {
                    Task { await submitNote() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CuvenColors.paperBackground)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(CuvenColors.inkPrimary))
                        .opacity(canShare ? 1.0 : 0.32)
                }
                .disabled(!canShare)
                .accessibilityLabel("Share note")
                .accessibilityIdentifier("chatlist.noteComposer.share")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            // Preview stage: Large thought bubble resting over 96pt avatar (`people.css:78-90`)
            VStack(spacing: 4) {
                VStack(spacing: 3) {
                    TextField("Share a thought…", text: $draftText)
                        .focused($isInputFocused)
                        .font(CuvenFonts.cappedBody())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .submitLabel(.done)
                        .onSubmit {
                            if canShare {
                                Task { await submitNote() }
                            }
                        }
                        .onChange(of: draftText) { _, newValue in
                            let cleaned = newValue
                                .replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ")
                            if cleaned.count > NotesStripView.maxNoteCharacters {
                                draftText = String(cleaned.prefix(NotesStripView.maxNoteCharacters))
                            } else if cleaned != newValue {
                                draftText = cleaned
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(minWidth: 180, maxWidth: 300)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(CuvenColors.elevatedSurface)
                                .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1)
                        )
                        .accessibilityIdentifier("chatlist.noteComposer.input")

                    HStack(spacing: 3) {
                        Circle()
                            .fill(CuvenColors.elevatedSurface)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8))
                        Circle()
                            .fill(CuvenColors.elevatedSurface)
                            .frame(width: 5, height: 5)
                            .offset(y: 4)
                    }
                    .offset(x: -12)
                }

                CuvenAvatarView(
                    name: store.currentUser?.display ?? "You",
                    urlString: store.currentUser?.avatarURL,
                    size: 96,
                    isOnline: true
                )
            }
            .padding(.top, 6)

            // Tabular character counter (`N/60`) & 24h hint
            VStack(spacing: 6) {
                Text("\(characterCount)/\(NotesStripView.maxNoteCharacters)")
                    .font(CuvenFonts.cappedCaption().monospacedDigit())
                    .foregroundStyle(ChatListPalette.tertiaryInk)
                    .accessibilityIdentifier("chatlist.noteComposer.counter")

                Text(hintDescription)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            if existingNote != nil {
                Button(role: .destructive) {
                    Task { await removeNote() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Delete note")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(CuvenColors.dangerRed)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(ChatListPalette.subtleChipFill))
                }
                .disabled(isSubmitting)
                .accessibilityIdentifier("chatlist.noteComposer.delete")
            }
        }
        .padding(.bottom, 24)
        .onAppear {
            isInputFocused = true
        }
    }

    private var hintDescription: String {
        if let existingNote {
            let age = ChatListTimeFormatter.noteAgeString(from: existingNote.createdAt)
            let prefix = age == "now" ? "Shared just now. " : "Shared \(age) ago. "
            return "\(prefix)Friends see it on your photo for 24 hours."
        }
        return "Friends see it on your photo for 24 hours."
    }

    private func submitNote() async {
        guard canShare else { return }
        isSubmitting = true
        await store.publishNote(text: trimmedDraft)
        CuvenHaptics.success()
        isSubmitting = false
        onDismiss()
    }

    private func removeNote() async {
        isSubmitting = true
        await store.deleteMyNote()
        CuvenHaptics.rigidImpact()
        isSubmitting = false
        onDismiss()
    }
}

// MARK: - Friend Note Reader & Quick Reply Modal (`people.js:145-172`)

private struct FriendNoteReplySheetView: View {
    let store: AppStore
    let note: UserNote
    let onDismiss: () -> Void

    @State private var replyText = ""
    @State private var isSending = false
    @FocusState private var isReplyFocused: Bool

    private var trimmedReply: String {
        replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(ChatListPalette.subtleChipFill))
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(spacing: 4) {
                Text(note.text)
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.medium)
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .frame(minWidth: 160, maxWidth: 300)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(CuvenColors.elevatedSurface)
                            .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1)
                    )

                CuvenAvatarView(
                    name: note.userDisplay,
                    urlString: note.avatarURL,
                    size: 96,
                    isOnline: store.contacts.first(where: { $0.user.id == note.userID })?.user.isOnline ?? false
                )
                .padding(.top, 6)
            }

            HStack(spacing: 4) {
                Text(note.userDisplay)
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("· \(ChatListTimeFormatter.noteAgeString(from: note.createdAt))")
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(CuvenColors.inkSecondary)
            }

            // Quick-reply DM composer (`people.js:146-169`)
            HStack(spacing: 8) {
                TextField("Reply to \(note.userDisplay)…", text: $replyText)
                    .focused($isReplyFocused)
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .submitLabel(.send)
                    .onSubmit {
                        if !trimmedReply.isEmpty {
                            Task { await sendNoteReply() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(
                        Capsule()
                            .fill(ChatListPalette.subtleChipFill)
                    )
                    .accessibilityIdentifier("chatlist.noteReply.input")

                Button {
                    Task { await sendNoteReply() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CuvenColors.paperBackground)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(CuvenColors.inkPrimary))
                        .opacity(trimmedReply.isEmpty || isSending ? 0.35 : 1.0)
                }
                .disabled(trimmedReply.isEmpty || isSending)
                .accessibilityLabel("Send reply")
                .accessibilityIdentifier("chatlist.noteReply.send")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onAppear {
            isReplyFocused = true
        }
    }

    private func sendNoteReply() async {
        guard !trimmedReply.isEmpty, !isSending else { return }
        isSending = true
        let roomID = await store.createDirectChat(with: note.userID)
        let formattedReply = "Replied to your note “\(note.text)”\n\(trimmedReply)"
        await store.sendText(formattedReply, in: roomID)
        CuvenHaptics.success()
        isSending = false
        onDismiss()
        store.selectRoom(roomID)
    }
}
