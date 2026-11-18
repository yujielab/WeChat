import SwiftUI
import PhotosUI
import UIKit
import CuvenCore

// MARK: - Conversation Composer Bar (`composer.js`, `predict.js`, `chat.css:128-143`, `PROJECT.md § 5.4-5.5`)
//
// Features:
// - `ComposerGlowView` (`ocean` / `dawn` / `aurora` / `off`) + RMS-reactive `VoiceBeamView` along field bottom edge
// - Stationary counter-translated `thread.backButton` (`offset(x: panLeadOffset)`) in 1-column non-railed postures
// - `thread.plusButton` (multi-photo `PhotosPicker`, Drawing Board, Voice Message clip)
// - `thread.stickerButton` toggling inline `StickerDrawerSheet`
// - Growing multi-line `thread.composerField` (`1...5` lines) with Honk live typing (`store.sendTypingPreview`)
// - Inline gray AI Ghost Completion (`store.ghostSuggestionByRoom[roomID]`, `Tab` / `→` / tap to accept)
// - Reply quote banner, Edit message banner (`15m` / `5-edit` `EditPolicyValidator`), and `@mention` member bar
// - `thread.micButton` (`WhisperDictationRecorder` 16kHz mono PCM16 WAV -> `store.transcribeWAV` + direct Voice Note send)
// - `thread.sendButton` (solid `CuvenColors.ctaInk` circle with `CuvenColors.onCtaInk` `arrow.up` / `checkmark`, rejecting empty/whitespace drafts)

struct ThreadComposerBar: View {
    @Bindable var store: AppStore
    let roomID: String
    let room: Room?
    let showsLeadingBackButton: Bool
    let otherUnreadCount: Int
    let panLeadOffset: CGFloat
    let onBack: () -> Void
    let onSubmittedMessage: () -> Void
    let onJumpToMessage: (String) -> Void

    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var textDraft: String = ""
    @State private var lastBaseForGhost: String = ""
    @State private var savedDraftBeforeEdit: String? = nil

    @State private var isAttachmentTrayOpen: Bool = false
    @State private var isStickerDrawerOpen: Bool = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isUploadingPhotos: Bool = false

    @State private var recorder = WhisperDictationRecorder()
    @State private var localValidationError: String? = nil
    @State private var ghostDebounceTask: Task<Void, Never>? = nil

    // MARK: - Derived State

    private var activeReplyMessage: Message? {
        store.replyingToMessageByRoom[roomID]
    }

    private var activeEditMessage: Message? {
        store.editingMessageByRoom[roomID]
    }

    private var activeGhostSuffix: String? {
        guard store.prefs.smartAssistEnabled,
              activeEditMessage == nil,
              !recorder.isRecording,
              !recorder.isTranscribing,
              let raw = store.ghostSuggestionByRoom[roomID],
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private var trimmedDraft: String {
        textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rejects empty or whitespace-only drafts; when editing, also requires valid `EditPolicyValidator` state.
    private var canSubmitDraft: Bool {
        guard !trimmedDraft.isEmpty else { return false }
        if let editing = activeEditMessage {
            let uid = store.currentUser?.id ?? "u_me"
            let err = EditPolicyValidator.validateEdit(
                message: editing,
                editorUserID: uid,
                newText: trimmedDraft
            )
            return err == nil && trimmedDraft != editing.text
        }
        return true
    }

    /// Active `@query` token at the end of `textDraft` for group `@mention` autocomplete.
    private var activeMentionQuery: String? {
        guard room?.kind == .group, activeEditMessage == nil else { return nil }
        guard let atIdx = textDraft.lastIndex(of: "@") else { return nil }
        if atIdx > textDraft.startIndex {
            let prev = textDraft[textDraft.index(before: atIdx)]
            if !prev.isWhitespace { return nil }
        }
        let tail = String(textDraft[textDraft.index(after: atIdx)...])
        guard !tail.contains(where: \.isWhitespace), tail.count <= 24 else { return nil }
        return tail
    }

    private var mentionCandidates: [CuvenUser] {
        guard let query = activeMentionQuery, let room else { return [] }
        let myID = store.currentUser?.id
        let roomMembers: [CuvenUser] = store.contacts
            .map(\.user)
            .filter { user in
                user.id != myID && (room.memberIDs.isEmpty || room.memberIDs.contains(user.id))
            }
        if query.isEmpty {
            return Array(roomMembers.prefix(8))
        }
        let lowered = query.lowercased()
        return roomMembers.filter { user in
            user.display.lowercased().contains(lowered) || user.username.lowercased().contains(lowered)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            // 1. Validation / Recorder Error Toast Pill
            if let errorBanner = localValidationError ?? recorder.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CuvenColors.dangerRedText)
                    Text(errorBanner)
                        .font(CuvenFonts.cappedFootnote(weight: .medium))
                        .foregroundStyle(CuvenColors.dangerRedText)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        localValidationError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CuvenColors.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CuvenColors.dangerRed.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 2. Group `@mention` Autocomplete Strip (`composer.js` mentionable)
            if !mentionCandidates.isEmpty {
                mentionAutocompleteStrip
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 3. Expandable `+` Attachment Tray (`PhotosPicker`, `Drawing Board`, `Voice Note`)
            if isAttachmentTrayOpen {
                attachmentTrayView
                    .padding(.horizontal, 12)
                    .transition(.scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity))
            }

            // 4. Primary Composer Row (`Back` + `+` + Frosted Pill w/ Sticker, Field, Mic & Ink Send)
            HStack(alignment: .bottom, spacing: 8) {
                if showsLeadingBackButton {
                    stationaryBackButton
                        .offset(x: panLeadOffset)
                }

                plusAttachmentButton

                composerFrostedFieldContainer
            }
            .padding(.horizontal, 10)
            .padding(.bottom, isStickerDrawerOpen ? 4 : 6)

            // 5. Inline Telegram Sticker Drawer (`StickerDrawerSheet`)
            if isStickerDrawerOpen {
                StickerDrawerSheet(store: store) { sticker in
                    CuvenHaptics.softImpact()
                    Task {
                        await store.sendSticker(sticker, in: roomID)
                        onSubmittedMessage()
                    }
                }
                .frame(height: 304)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(CuvenColors.cardLine, lineWidth: 0.75)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(alignment: .bottom) {
            ComposerGlowView(
                style: store.prefs.composerGlow,
                audioLevel: recorder.isRecording ? recorder.rmsLevel : 0,
                isFocused: isFieldFocused
            )
            .frame(height: 136)
            .offset(y: 12)
        }
        .onAppear {
            syncFromStoreOnRoomAppear()
        }
        .onChange(of: roomID) { oldRoomID, _ in
            if !oldRoomID.isEmpty {
                store.sendTypingPreview("", in: oldRoomID)
            }
            ghostDebounceTask?.cancel()
            if recorder.isRecording {
                recorder.cancelRecording()
            }
            isAttachmentTrayOpen = false
            isStickerDrawerOpen = false
            localValidationError = nil
            savedDraftBeforeEdit = nil
            syncFromStoreOnRoomAppear()
        }
        .onChange(of: activeEditMessage?.id) { _, newEditID in
            handleExternalEditStateChange(newEditID: newEditID)
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await sendPickedPhotoItems(newItems)
            }
        }
        .onDisappear {
            ghostDebounceTask?.cancel()
            store.sendTypingPreview("", in: roomID)
            if recorder.isRecording {
                recorder.cancelRecording()
            }
        }
    }

    // MARK: - Stationary Back Button (`thread.backButton`)

    private var stationaryBackButton: some View {
        Button {
            CuvenHaptics.lightTap()
            isFieldFocused = false
            onBack()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
                    .cuvenLiquidGlass(
                        mode: store.prefs.glassMode,
                        cornerRadius: 23,
                        interactiveBounce: true
                    )

                if otherUnreadCount > 0 {
                    Text(otherUnreadCount > 99 ? "99+" : "\(otherUnreadCount)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 17)
                        .background(CuvenColors.ctaInk, in: Capsule())
                        .overlay(Capsule().strokeBorder(CuvenColors.paperBackground, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 46, minHeight: 46)
        .accessibilityIdentifier("thread.backButton")
        .accessibilityLabel(
            otherUnreadCount > 0
                ? "Back to chats, \(otherUnreadCount) unread"
                : "Back to chats"
        )
    }

    // MARK: - `+` Attachment Button (`thread.plusButton`) & Inline Tray

    private var plusAttachmentButton: some View {
        Button {
            CuvenHaptics.lightTap()
            withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                isAttachmentTrayOpen.toggle()
                if isAttachmentTrayOpen {
                    isStickerDrawerOpen = false
                }
            }
        } label: {
            ZStack {
                if isUploadingPhotos {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .rotationEffect(.degrees(isAttachmentTrayOpen ? 45 : 0))
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: 23,
                interactiveBounce: true
            )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 46, minHeight: 46)
        .accessibilityIdentifier("thread.plusButton")
        .accessibilityLabel(isAttachmentTrayOpen ? "Close attachments" : "Add photo, drawing, or voice clip")
    }

    private var attachmentTrayView: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: 9,
                matching: .images
            ) {
                // Built here, not by the view's own helper: the picker calls this off the main actor.
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }
            .labelStyle(AttachmentPillLabelStyle())
            .buttonStyle(.plain)

            Button {
                CuvenHaptics.lightTap()
                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                    isAttachmentTrayOpen = false
                }
                store.openArtifact(.drawingBoard, for: roomID)
            } label: {
                attachmentPillLabel(symbol: "pencil.and.scribble", title: "Draw")
            }
            .buttonStyle(.plain)

            Button {
                CuvenHaptics.lightTap()
                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                    isAttachmentTrayOpen = false
                }
                startRecordingIfIdle()
            } label: {
                attachmentPillLabel(symbol: "waveform", title: "Voice")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24, interactiveBounce: false)
    }

    private func attachmentPillLabel(symbol: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(CuvenColors.sidebarBlue)
            Text(title)
                .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(CuvenColors.fieldBackground.opacity(0.85), in: Capsule())
    }

    // MARK: - Frosted Composer Pill (Reply/Edit Banner + Field + Ghost + Sticker/Mic/Send + VoiceBeam)

    private var composerFrostedFieldContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing = activeEditMessage {
                editingContextBanner(for: editing)
            } else if let replying = activeReplyMessage {
                replyingContextBanner(for: replying)
            }

            if recorder.isRecording || recorder.isTranscribing {
                recordingStatusStrip
            }

            HStack(alignment: .bottom, spacing: 4) {
                // Sticker Drawer Button (`thread.stickerButton`)
                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        isStickerDrawerOpen.toggle()
                        if isStickerDrawerOpen {
                            isAttachmentTrayOpen = false
                            isFieldFocused = false
                        }
                    }
                } label: {
                    Image(systemName: isStickerDrawerOpen ? "keyboard" : "face.smiling")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(isStickerDrawerOpen ? CuvenColors.sidebarBlue : CuvenColors.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("thread.stickerButton")
                .accessibilityLabel(isStickerDrawerOpen ? "Show keyboard" : "Choose sticker")

                // Multi-line Text Input + Inline Gray AI Ghost Completion
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Message", text: $textDraft, axis: .vertical)
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1...5)
                        .focused($isFieldFocused)
                        .submitLabel(activeEditMessage != nil ? .done : .send)
                        .onSubmit {
                            if canSubmitDraft {
                                submitCurrentDraft()
                            }
                        }
                        .onKeyPress(.tab) {
                            if acceptGhostCompletion() {
                                return .handled
                            }
                            return .ignored
                        }
                        .onChange(of: isFieldFocused) { _, focused in
                            if focused {
                                if isStickerDrawerOpen {
                                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                        isStickerDrawerOpen = false
                                    }
                                }
                                if textDraft.isEmpty {
                                    scheduleGhostSuggestionRequest(delayMs: 120)
                                }
                            } else {
                                store.sendTypingPreview("", in: roomID)
                            }
                        }
                        .onChange(of: textDraft) { oldVal, newVal in
                            handleDraftChanged(from: oldVal, to: newVal)
                        }
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("thread.composerField")

                    if let ghost = activeGhostSuffix {
                        Button {
                            _ = acceptGhostCompletion()
                        } label: {
                            HStack(spacing: 6) {
                                Text(ghost)
                                    .font(CuvenFonts.cappedFootnote())
                                    .foregroundStyle(CuvenColors.inkTertiary)
                                    .lineLimit(1)
                                Text("Tab")
                                    .font(.system(size: 10, weight: .semibold).monospaced())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .padding(.bottom, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Suggested completion: \(ghost). Double tap or press Tab to insert")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Whisper Dictation Mic Button (`thread.micButton`)
                Button {
                    handleMicButtonTapped()
                } label: {
                    ZStack {
                        if recorder.isTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                                .font(.system(size: recorder.isRecording ? 21 : 18.5, weight: .medium))
                                .foregroundStyle(recorder.isRecording ? CuvenColors.dangerRed : CuvenColors.inkSecondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(recorder.isTranscribing)
                .accessibilityIdentifier("thread.micButton")
                .accessibilityLabel(recorder.isRecording ? "Stop dictation and transcribe" : "Voice dictation")

                // Primary Solid Ink Send / Save Edit Button (`thread.sendButton`, `chat.css:132-143`)
                Button {
                    submitCurrentDraft()
                } label: {
                    Image(systemName: activeEditMessage != nil ? "checkmark" : "arrow.up")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(canSubmitDraft ? CuvenColors.onCtaInk : CuvenColors.inkTertiary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(canSubmitDraft ? CuvenColors.ctaInk : CuvenColors.fieldBackground)
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitDraft)
                .scaleEffect(canSubmitDraft ? 1.0 : 0.94)
                .animation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion), value: canSubmitDraft)
                .accessibilityIdentifier("thread.sendButton")
                .accessibilityLabel(activeEditMessage != nil ? "Save edited message" : "Send message")
            }
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
        }
        .overlay(alignment: .bottom) {
            VoiceBeamView(
                rmsLevel: recorder.rmsLevel,
                isRecording: recorder.isRecording,
                isProcessing: recorder.isTranscribing,
                palette: .colorful
            )
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .cuvenComposerFrost(
            cornerRadius: 24,
            isFocused: isFieldFocused,
            isDictating: recorder.isRecording || recorder.isTranscribing
        )
    }

    // MARK: - Reply, Edit, Recording & Mention Subviews

    private func replyingContextBanner(for target: Message) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(CuvenColors.sidebarBlue)
                .frame(width: 3, height: 28)

            Button {
                CuvenHaptics.lightTap()
                onJumpToMessage(target.id)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replying to \(target.senderDisplay.isEmpty ? "Message" : target.senderDisplay)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuvenColors.accessibleBlueText)
                        .lineLimit(1)
                    Text(ThreadGroupingEngine.quotePreviewText(for: target))
                        .font(.system(size: 12.5))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                CuvenHaptics.lightTap()
                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                    store.replyingToMessageByRoom.removeValue(forKey: roomID)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.top, 6)
    }

    private func editingContextBanner(for target: Message) -> some View {
        let remaining = max(0, EditPolicyValidator.maxEdits - target.editCount)
        return HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CuvenColors.accessibleBlueText)
                .frame(width: 24, height: 24)
                .background(CuvenColors.sidebarBlue.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message · \(remaining) \(remaining == 1 ? "edit" : "edits") left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CuvenColors.accessibleBlueText)
                    .lineLimit(1)
                Text(target.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                CuvenHaptics.lightTap()
                cancelEditMode()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 6)
    }

    private var recordingStatusStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.isTranscribing ? CuvenColors.systemBlue : CuvenColors.dangerRed)
                .frame(width: 7, height: 7)

            Text(
                recorder.isTranscribing
                    ? "Transcribing with Whisper…"
                    : "Listening · \(ThreadTimeFormatter.durationString(seconds: recorder.recordingDuration))"
            )
            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(CuvenColors.inkPrimary)

            Spacer(minLength: 4)

            if recorder.isRecording {
                // Direct Voice Message send option alongside Whisper text dictation
                Button {
                    Task {
                        await stopAndSendVoiceClip()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Send Voice")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(CuvenColors.accessibleBlueText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(CuvenColors.sidebarBlue.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    CuvenHaptics.lightTap()
                    recorder.cancelRecording()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var mentionAutocompleteStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mentionCandidates) { member in
                    Button {
                        insertMention(for: member)
                    } label: {
                        HStack(spacing: 6) {
                            CuvenAvatarView(
                                name: member.display,
                                urlString: member.avatarURL,
                                size: 22,
                                isOnline: member.isOnline
                            )
                            Text(member.display)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                            Text("@\(member.username)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(CuvenColors.cardSurface.opacity(0.92), in: Capsule())
                        .overlay(Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions & Logic

    private func syncFromStoreOnRoomAppear() {
        if let editing = store.editingMessageByRoom[roomID] {
            textDraft = editing.text
        } else {
            textDraft = store.draftsByRoom[roomID] ?? ""
        }
        lastBaseForGhost = textDraft
    }

    private func handleExternalEditStateChange(newEditID: String?) {
        if let newEditID,
           let target = store.editingMessageByRoom[roomID],
           target.id == newEditID
        {
            if savedDraftBeforeEdit == nil {
                savedDraftBeforeEdit = store.draftsByRoom[roomID] ?? ""
            }
            textDraft = target.text
            store.ghostSuggestionByRoom.removeValue(forKey: roomID)
            isFieldFocused = true
        } else if savedDraftBeforeEdit != nil {
            textDraft = savedDraftBeforeEdit ?? (store.draftsByRoom[roomID] ?? "")
            savedDraftBeforeEdit = nil
        }
    }

    private func cancelEditMode() {
        store.editingMessageByRoom.removeValue(forKey: roomID)
        localValidationError = nil
        if let restored = savedDraftBeforeEdit {
            textDraft = restored
            store.draftsByRoom[roomID] = restored
            savedDraftBeforeEdit = nil
        } else {
            textDraft = store.draftsByRoom[roomID] ?? ""
        }
    }

    private func handleDraftChanged(from oldVal: String, to newVal: String) {
        localValidationError = nil

        if activeEditMessage == nil {
            store.draftsByRoom[roomID] = newVal
            store.sendTypingPreview(newVal, in: roomID)
        }

        // Type-through ghost completion (`predict.js:131-139`)
        if let currentGhost = store.ghostSuggestionByRoom[roomID],
           !currentGhost.isEmpty,
           newVal.hasPrefix(lastBaseForGhost),
           newVal.count > lastBaseForGhost.count
        {
            let typedExtension = String(newVal.dropFirst(lastBaseForGhost.count))
            if currentGhost.hasPrefix(typedExtension) {
                let remaining = String(currentGhost.dropFirst(typedExtension.count))
                if remaining.isEmpty {
                    store.ghostSuggestionByRoom.removeValue(forKey: roomID)
                } else {
                    store.ghostSuggestionByRoom[roomID] = remaining
                }
                lastBaseForGhost = newVal
                return
            }
        }

        store.ghostSuggestionByRoom.removeValue(forKey: roomID)
        lastBaseForGhost = newVal

        if activeEditMessage == nil, !newVal.contains("\n"), newVal.count <= 200 {
            scheduleGhostSuggestionRequest(delayMs: 450)
        } else {
            ghostDebounceTask?.cancel()
        }
    }

    private func scheduleGhostSuggestionRequest(delayMs: Int) {
        ghostDebounceTask?.cancel()
        guard store.prefs.smartAssistEnabled, activeEditMessage == nil else { return }
        let snapshotDraft = textDraft
        let targetRoom = roomID
        ghostDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, targetRoom == roomID, textDraft == snapshotDraft else { return }
            await store.requestGhostSuggestion(for: targetRoom, draft: snapshotDraft)
            lastBaseForGhost = textDraft
        }
    }

    @discardableResult
    private func acceptGhostCompletion() -> Bool {
        guard let ghost = activeGhostSuffix, !ghost.isEmpty else { return false }
        CuvenHaptics.selectionChanged()
        store.ghostSuggestionByRoom.removeValue(forKey: roomID)
        let separator = (!textDraft.isEmpty && !textDraft.hasSuffix(" ") && !ghost.hasPrefix(" ")) ? "" : ""
        textDraft = textDraft + separator + ghost
        lastBaseForGhost = textDraft
        store.draftsByRoom[roomID] = textDraft
        store.sendTypingPreview(textDraft, in: roomID)
        return true
    }

    private func insertMention(for member: CuvenUser) {
        guard let atIdx = textDraft.lastIndex(of: "@") else { return }
        CuvenHaptics.selectionChanged()
        let prefix = String(textDraft[..<atIdx])
        textDraft = "\(prefix)@\(member.username) "
        store.draftsByRoom[roomID] = textDraft
        isFieldFocused = true
    }

    private func submitCurrentDraft() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }

        if let editing = activeEditMessage {
            let uid = store.currentUser?.id ?? "u_me"
            if let validationError = EditPolicyValidator.validateEdit(
                message: editing,
                editorUserID: uid,
                newText: trimmed
            ) {
                CuvenHaptics.error()
                localValidationError = validationError.messageText
                return
            }

            CuvenHaptics.softImpact()
            let messageID = editing.id
            let restored = savedDraftBeforeEdit ?? ""
            savedDraftBeforeEdit = nil
            textDraft = restored
            store.draftsByRoom[roomID] = restored

            Task { @MainActor in
                do {
                    try await store.editMessage(messageID, in: roomID, newText: trimmed)
                } catch {
                    localValidationError = error.localizedDescription
                }
            }
            return
        }

        // Standard outgoing message send (`chat-send` spring settle)
        CuvenHaptics.softImpact()
        let replyID = activeReplyMessage?.id
        let outgoingBody = trimmed
        textDraft = ""
        lastBaseForGhost = ""
        store.draftsByRoom[roomID] = ""
        store.ghostSuggestionByRoom.removeValue(forKey: roomID)
        store.sendTypingPreview("", in: roomID)

        Task { @MainActor in
            await store.sendText(outgoingBody, in: roomID, replyToID: replyID)
            onSubmittedMessage()
        }
    }

    // MARK: - Whisper Dictation & Voice Note Recording

    private func startRecordingIfIdle() {
        guard !recorder.isRecording, !recorder.isTranscribing else { return }
        CuvenHaptics.lightTap()
        localValidationError = nil
        Task { @MainActor in
            _ = await recorder.startRecording()
        }
    }

    private func handleMicButtonTapped() {
        if recorder.isRecording {
            Task { @MainActor in
                await stopAndTranscribeSpeech()
            }
        } else if !recorder.isTranscribing {
            startRecordingIfIdle()
        }
    }

    private func stopAndTranscribeSpeech() async {
        CuvenHaptics.lightTap()
        guard let clip = recorder.stopRecording() else { return }
        recorder.setTranscribing(true)
        defer { recorder.setTranscribing(false) }

        do {
            let transcript = try await store.transcribeWAV(clip.wavData)
            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            CuvenHaptics.success()
            let needsLeadingSpace = !textDraft.isEmpty && !(textDraft.last?.isWhitespace ?? true)
            textDraft += (needsLeadingSpace ? " " : "") + cleaned
            isFieldFocused = true
        } catch {
            CuvenHaptics.error()
            localValidationError = error.localizedDescription
        }
    }

    private func stopAndSendVoiceClip() async {
        CuvenHaptics.softImpact()
        guard let clip = recorder.stopRecording() else { return }
        await store.sendMedia(
            data: clip.wavData,
            mimeType: "audio/wav",
            kind: .voice,
            in: roomID,
            duration: max(0.5, clip.durationSeconds)
        )
        onSubmittedMessage()
    }

    // MARK: - Multi-Photo Picker Upload

    private func sendPickedPhotoItems(_ items: [PhotosPickerItem]) async {
        isUploadingPhotos = true
        defer {
            isUploadingPhotos = false
            selectedPhotoItems = []
            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                isAttachmentTrayOpen = false
            }
        }

        for item in items {
            guard let rawData = try? await item.loadTransferable(type: Data.self),
                  !rawData.isEmpty
            else { continue }

            let prepared = Self.prepareJPEGUpload(from: rawData)
            await store.sendMedia(
                data: prepared.data,
                mimeType: prepared.mimeType,
                kind: .image,
                in: roomID,
                width: prepared.width,
                height: prepared.height
            )
        }
        CuvenHaptics.softImpact()
        onSubmittedMessage()
    }

    private static func prepareJPEGUpload(from rawData: Data) -> (data: Data, mimeType: String, width: Int?, height: Int?) {
        guard let image = UIImage(data: rawData) else {
            return (rawData, "image/jpeg", nil, nil)
        }
        let maxSide: CGFloat = 1600
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let scaleFactor = min(1.0, maxSide / max(pixelW, pixelH, 1.0))
        let targetSize = CGSize(width: round(pixelW * scaleFactor), height: round(pixelH * scaleFactor))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let jpeg = rendered.jpegData(compressionQuality: 0.84) {
            return (jpeg, "image/jpeg", Int(targetSize.width), Int(targetSize.height))
        }
        return (rawData, "image/jpeg", Int(pixelW), Int(pixelH))
    }
}

// MARK: - Attachment pill (the Photos picker's label)

/// The same pill as `attachmentPillLabel(symbol:title:)`, as a label style, so the
/// Photos picker's label can be a plain `Label` made outside the main actor.
private struct AttachmentPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(CuvenColors.sidebarBlue)
            configuration.title
                .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(CuvenColors.fieldBackground.opacity(0.85), in: Capsule())
    }
}
