// MomentsPostEditorSheet.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Full-Page / Tall-Card Moments Studio Editor (`public/js/views/moments-editor.js`,
// `public/css/moments-editor.css`, `PROJECT.md § 5.5`):
// - Accessibility IDs: `moments.editor.publishButton`, `moments.editor.filterStrip`, `moments.editor.altButton`
// - Real `CoreImagePhotoFilterEngine` 6-Tone Filter Strip (`Original`, `Vivid`, `Warm`, `Cool`, `Mono`, `Fade`)
// - `90° Rotate` & Aspect Crop presets (`Original`, `1:1`, `4:5`, `16:9`)
// - `+ALT` Accessibility Description modal (`1,000` chars) per photo
// - `@Tag Friends` multi-select picker (`<=10` friends)
// - Audience selector (`Everyone` / `Friends`) & Comment permissions (`Everyone` / `Friends` / `Off`)
// - Scheduled Publish Date/Time picker (`5 min` to `30 days` ahead + quick chips)
// - Genuine 200-step Undo / Redo state stack (`⌘Z` / `⇧⌘Z` + footer buttons) & dirty-state Discard guard.

import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import UIKit
import CuvenCore

public struct MomentsPostEditorSheet: View {
    private let store: AppStore
    private let metrics: DuoLayoutMetrics
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var history: MomentsEditorHistory<MomentEditorDraftState> = MomentsEditorHistory(
        initial: MomentEditorDraftState()
    )
    @State private var photoPickerSelections: [PhotosPickerItem] = []
    @State private var filterStripThumbnails: [String: [PhotoToneFilter: UIImage]] = [:]
    @State private var studioSampleCounter: Int = 0

    // Sub-modals
    @State private var editingStudioMediaID: String?
    @State private var editingAltMediaID: String?
    @State private var showTagFriendsSheet: Bool = false
    @State private var showScheduleSheet: Bool = false
    @State private var showCameraPicker: Bool = false
    @State private var showDiscardConfirmation: Bool = false

    // Publish progress
    @State private var isPublishing: Bool = false
    @State private var publishStatusText: String = ""
    @State private var publishProgressFraction: CGFloat = 0.0
    @FocusState private var isComposerFocused: Bool

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onDismiss = onDismiss
    }

    private var draft: MomentEditorDraftState {
        history.present
    }

    private var activeSelectedMedia: MomentEditableMediaItem? {
        if let selectedID = draft.selectedMediaID,
           let match = draft.mediaItems.first(where: { $0.id == selectedID }) {
            return match
        }
        return draft.mediaItems.first
    }

    private var eligibleFriendsToTag: [CuvenUser] {
        var byID: [String: CuvenUser] = [:]
        for contact in store.contacts where contact.status == .accepted {
            byID[contact.user.id] = contact.user
        }
        for room in store.rooms where room.kind == .dm {
            if let peerID = room.peerUserID, byID[peerID] == nil {
                if let known = store.contacts.first(where: { $0.user.id == peerID })?.user {
                    byID[peerID] = known
                } else {
                    byID[peerID] = CuvenUser(
                        id: peerID,
                        username: peerID,
                        display: room.title,
                        avatarURL: room.avatarURL
                    )
                }
            }
        }
        if let meID = store.currentUser?.id {
            byID.removeValue(forKey: meID)
        }
        return byID.values.sorted { ($0.display.isEmpty ? $0.username : $0.display) < ($1.display.isEmpty ? $1.username : $1.display) }
    }

    private var taggedFriendsSummaryText: String {
        guard !draft.taggedUserIDs.isEmpty else { return "Tag people" }
        let names = draft.taggedUserIDs.map { id -> String in
            if let u = eligibleFriendsToTag.first(where: { $0.id == id }) {
                return u.display.isEmpty ? u.username : u.display
            }
            return id
        }
        if names.count <= 2 {
            return "With " + names.joined(separator: " and ")
        }
        return "With \(names[0]) and \(names.count - 1) others"
    }

    public var body: some View {
        VStack(spacing: 0) {
            editorTopHeaderBar

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    authorAndTextComposerRow

                    if !draft.mediaItems.isEmpty {
                        horizontalMediaCardsStrip
                    }

                    inlineCoreImageStudioDeck

                    metadataActionRows
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .opacity(isPublishing ? 0.62 : 1.0)
            .allowsHitTesting(!isPublishing)

            stickyFooterDock
                .opacity(isPublishing ? 0.62 : 1.0)
                .allowsHitTesting(!isPublishing)
        }
        .background(CuvenColors.paperBackground.ignoresSafeArea())
        .interactiveDismissDisabled(draft.hasUnsavedChanges || isPublishing)
        .onChange(of: photoPickerSelections) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await loadPickedPhotos(newItems)
                photoPickerSelections = []
            }
        }
        .confirmationDialog(
            "Discard this moment?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                CuvenHaptics.rigidImpact()
                onDismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("What you wrote and the photos you picked won’t be kept.")
        }
        .sheet(isPresented: Binding(
            get: { editingAltMediaID != nil },
            set: { if !$0 { editingAltMediaID = nil } }
        )) {
            if let targetID = editingAltMediaID,
               let item = draft.mediaItems.first(where: { $0.id == targetID }) {
                MomentAltDescriptionEditorModal(
                    mediaItem: item,
                    onSave: { updatedAlt in
                        applyAltDescription(updatedAlt, toMediaID: targetID)
                        editingAltMediaID = nil
                    },
                    onCancel: { editingAltMediaID = nil }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingStudioMediaID != nil },
            set: { if !$0 { editingStudioMediaID = nil } }
        )) {
            if let targetID = editingStudioMediaID,
               let item = draft.mediaItems.first(where: { $0.id == targetID }) {
                MomentPhotoStudioModal(
                    mediaItem: item,
                    onApply: { newParams in
                        applyPhotoEditParameters(newParams, toMediaID: targetID)
                        editingStudioMediaID = nil
                    },
                    onCancel: { editingStudioMediaID = nil }
                )
            }
        }
        .sheet(isPresented: $showTagFriendsSheet) {
            MomentTagFriendsPickerSheet(
                friends: eligibleFriendsToTag,
                selectedUserIDs: draft.taggedUserIDs,
                onSave: { chosenIDs in
                    var next = draft
                    next.taggedUserIDs = chosenIDs
                    history.record(next)
                    showTagFriendsSheet = false
                },
                onCancel: { showTagFriendsSheet = false }
            )
        }
        .sheet(isPresented: $showScheduleSheet) {
            MomentSchedulePickerSheet(
                currentScheduledMillis: draft.scheduledAtMillis,
                use24HourTime: store.prefs.use24HourTime,
                onSave: { newMillis in
                    var next = draft
                    next.scheduledAtMillis = newMillis
                    history.record(next)
                    showScheduleSheet = false
                },
                onCancel: { showScheduleSheet = false }
            )
        }
        .sheet(isPresented: $showCameraPicker) {
            MomentsCameraCapturePicker { capturedImage in
                showCameraPicker = false
                if let capturedImage {
                    appendUIImageToDraft(capturedImage)
                }
            }
        }
        .onAppear {
            isComposerFocused = true
        }
    }

    // MARK: - 1. Top Header (`Cancel`, Status, `Post` / `Schedule` Pill + Progress Bar)

    private var editorTopHeaderBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    attemptDismissEditor()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPublishing)
                .accessibilityIdentifier("moments.editor.cancelButton")

                Spacer(minLength: 4)

                if !publishStatusText.isEmpty {
                    Text(publishStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    Task { await publishDraftMoment() }
                } label: {
                    Text(draft.scheduledAtMillis != nil ? "Schedule" : "Post")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .padding(.horizontal, 20)
                        .frame(minWidth: 84, minHeight: 40)
                        .background(CuvenColors.ctaInk, in: Capsule())
                        .opacity((draft.hasPublishableContent && !isPublishing) ? 1.0 : 0.35)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!draft.hasPublishableContent || isPublishing)
                .accessibilityIdentifier("moments.editor.publishButton")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 2pt upload/publish progress bar (`moments-editor.css:44-45`)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(height: 0.5)
                    if isPublishing {
                        Rectangle()
                            .fill(CuvenColors.systemBlue)
                            .frame(width: geo.size.width * publishProgressFraction, height: 2)
                            .animation(.easeOut(duration: 0.22), value: publishProgressFraction)
                    }
                }
            }
            .frame(height: 2)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 2. Author Avatar & `"What's new?"` Expanding Text Field (`moments-editor.css:50-66`)

    private var authorAndTextComposerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            CuvenAvatarView(
                name: store.currentUser?.display ?? "You",
                urlString: store.currentUser?.avatarURL,
                size: 44,
                isOnline: false
            )

            TextField(
                "What's new?",
                text: Binding(
                    get: { draft.text },
                    set: { updated in
                        let clamped = updated.count > MomentEditorDraftState.maxTextCharacters
                            ? String(updated.prefix(MomentEditorDraftState.maxTextCharacters))
                            : updated
                        guard clamped != draft.text else { return }
                        var next = draft
                        next.text = clamped
                        history.recordTyping(next)
                    }
                ),
                axis: .vertical
            )
            .font(CuvenFonts.cappedTitle(weight: .regular))
            .foregroundStyle(CuvenColors.inkPrimary)
            .lineLimit(3...14)
            .focused($isComposerFocused)
            .frame(minHeight: 84, alignment: .topLeading)
            .accessibilityLabel("What you want to say")
            .accessibilityIdentifier("moments.editor.textField")
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
    }

    // MARK: - 3. Proportional Horizontal Photo Cards Strip (`moments-editor.css:69-135`)

    private var horizontalMediaCardsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(draft.mediaItems.enumerated()), id: \.element.id) { index, item in
                    let isSelected = (activeSelectedMedia?.id == item.id)
                    let cardHeight: CGFloat = 236
                    let cardWidth = max(146, min(320, cardHeight * item.clampedCardAspectRatio))

                    ZStack {
                        if item.isVideo, let videoURL = item.mediaURLString, !videoURL.isEmpty {
                            MomentsInlineVideoView(
                                urlString: videoURL,
                                serverBaseURL: store.serverBaseURL,
                                bottomControlOffset: 10
                            )
                            .frame(width: cardWidth, height: cardHeight)
                            .clipped()
                        } else if let renderedData = item.renderedImageData,
                           let uiImage = UIImage(data: renderedData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: cardWidth, height: cardHeight)
                                .clipped()
                        } else {
                            MomentsEditorialSeedArtwork(
                                seedKey: item.id,
                                filterName: item.editParameters.tone.rawValue
                            )
                            .frame(width: cardWidth, height: cardHeight)
                        }

                        // Top-right Remove `×` button
                        VStack {
                            HStack {
                                if item.editParameters.tone != .original {
                                    Text(item.editParameters.tone.displayName)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.64), in: Capsule())
                                }
                                Spacer()
                                Button {
                                    CuvenHaptics.lightTap()
                                    removeMediaItem(id: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Color.black.opacity(0.72), in: Circle())
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.isVideo ? "Remove video" : "Remove photo \(index + 1)")
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 4)
                            .padding(.top, 4)

                            Spacer()

                            // Bottom-right Pencil (Full Studio) & `+ALT` badges (`moments-editor.js:189-201`)
                            if !item.isVideo {
                                HStack(spacing: 8) {
                                    Spacer()

                                    Button {
                                        CuvenHaptics.lightTap()
                                        selectMedia(id: item.id)
                                        editingStudioMediaID = item.id
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 44, height: 44)
                                            .background(Color.black.opacity(0.72), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit photo \(index + 1)")

                                    Button {
                                        CuvenHaptics.lightTap()
                                        selectMedia(id: item.id)
                                        editingAltMediaID = item.id
                                    } label: {
                                        HStack(spacing: 4) {
                                            if item.hasAltDescription {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                                Text("ALT")
                                            } else {
                                                Text("+ALT")
                                            }
                                        }
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(item.hasAltDescription ? .black : .white)
                                        .padding(.horizontal, 14)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .background(
                                            item.hasAltDescription ? Color.white.opacity(0.94) : Color.black.opacity(0.72),
                                            in: Capsule()
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.hasAltDescription ? "Description: \(item.altText). Edit" : "Add a description")
                                }
                                .padding(10)
                            }
                        }
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isSelected ? MomentsPalette.skyTitle : CuvenColors.hairlineSeparator,
                                lineWidth: isSelected ? 2.2 : 1.0
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture {
                        CuvenHaptics.selectionChanged()
                        selectMedia(id: item.id)
                    }
                }
            }
            .padding(.leading, 70)
            .padding(.trailing, 18)
        }
    }

    // MARK: - 4. CoreImage 6-Tone Filter Strip, 90° Rotate, Crop & `+ALT` Deck (`PROJECT.md § 5.5`)

    private var inlineCoreImageStudioDeck: some View {
        let selected = activeSelectedMedia
        let activeParams = selected?.editParameters ?? PhotoEditParameters()
        let selectedThumbMap = selected.flatMap { filterStripThumbnails[$0.id] } ?? [:]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Photo Studio", systemImage: "camera.filters")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                if selected == nil {
                    Button {
                        CuvenHaptics.lightTap()
                        attachGeneratedStudioPhoto(applyingTone: .original)
                    } label: {
                        Label("Add Sample Photo", systemImage: "sparkles.rectangle.stack")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MomentsPalette.accessibleBlueText)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(CuvenColors.incomingBubble, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("moments.editor.addSamplePhotoButton")
                }

                // Canonical `+ALT` Accessibility Description button (`moments.editor.altButton`)
                Button {
                    CuvenHaptics.lightTap()
                    if let current = activeSelectedMedia {
                        editingAltMediaID = current.id
                    } else {
                        let createdID = attachGeneratedStudioPhoto(applyingTone: .original)
                        editingAltMediaID = createdID
                    }
                } label: {
                    HStack(spacing: 4) {
                        if selected?.hasAltDescription == true {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("ALT")
                        } else {
                            Text("+ALT")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected?.hasAltDescription == true ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 52, minHeight: 36)
                    .background(
                        selected?.hasAltDescription == true ? CuvenColors.ctaInk : CuvenColors.incomingBubble,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected?.hasAltDescription == true ? "Edit accessibility description" : "Add accessibility description")
                .accessibilityIdentifier("moments.editor.altButton")
            }

            // 90° Rotate + Aspect Ratio Crop Presets (`Original`, `1:1`, `4:5`, `16:9`)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        CuvenHaptics.lightTap()
                        if let current = activeSelectedMedia {
                            applyPhotoEditParameters(current.editParameters.rotated90Clockwise(), toMediaID: current.id)
                        } else {
                            let createdID = attachGeneratedStudioPhoto(applyingTone: .original)
                            if let item = history.present.mediaItems.first(where: { $0.id == createdID }) {
                                applyPhotoEditParameters(item.editParameters.rotated90Clockwise(), toMediaID: createdID)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 13, weight: .semibold))
                            Text(activeParams.rotationDegrees == 0 ? "Rotate" : "\(activeParams.rotationDegrees)°")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(CuvenColors.incomingBubble, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("moments.editor.rotateButton")

                    HStack(spacing: 4) {
                        ForEach(PhotoAspectCropPreset.allCases) { preset in
                            let isChosen = (activeParams.cropPreset == preset)
                            Button {
                                CuvenHaptics.selectionChanged()
                                var updated = activeParams
                                updated.cropPreset = preset
                                if let current = activeSelectedMedia {
                                    applyPhotoEditParameters(updated, toMediaID: current.id)
                                } else {
                                    let createdID = attachGeneratedStudioPhoto(applyingTone: .original)
                                    applyPhotoEditParameters(updated, toMediaID: createdID)
                                }
                            } label: {
                                Text(preset.displayName)
                                    .font(.system(size: 12, weight: isChosen ? .bold : .medium))
                                    .foregroundStyle(isChosen ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                                    .padding(.horizontal, 11)
                                    .frame(height: 30)
                                    .background(
                                        isChosen ? CuvenColors.ctaInk : Color.clear,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("moments.editor.crop.\(preset.rawValue)")
                        }
                    }
                    .padding(3)
                    .background(CuvenColors.incomingBubble, in: Capsule())
                    .accessibilityIdentifier("moments.editor.cropStrip")
                }
            }

            // Canonical 6-Tone CoreImage Filter Strip (`moments.editor.filterStrip`)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PhotoToneFilter.allCases) { tone in
                        let isSelectedTone = (activeParams.tone == tone)
                        Button {
                            CuvenHaptics.selectionChanged()
                            if let current = activeSelectedMedia {
                                var updated = current.editParameters
                                updated.tone = tone
                                applyPhotoEditParameters(updated, toMediaID: current.id)
                            } else {
                                _ = attachGeneratedStudioPhoto(applyingTone: tone)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let thumb = selectedThumbMap[tone] {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        ToneSwatchFallbackPreview(tone: tone)
                                    }
                                }
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            isSelectedTone ? CuvenColors.ctaInk : CuvenColors.hairlineSeparator,
                                            lineWidth: isSelectedTone ? 2.5 : 1.0
                                        )
                                }

                                Text(tone.displayName)
                                    .font(.system(size: 12, weight: isSelectedTone ? .semibold : .regular))
                                    .foregroundStyle(isSelectedTone ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tone.displayName) filter")
                        .accessibilityAddTraits(isSelectedTone ? .isSelected : [])
                        .accessibilityIdentifier("moments.editor.filter.\(tone.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("moments.editor.filterStrip")
        }
        .padding(14)
        .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
        }
        .padding(.leading, 70)
        .padding(.trailing, 18)
    }

    // MARK: - 5. `@Tag Friends` & Scheduled Time Banner Rows (`moments-editor.css:138-150`)

    private var metadataActionRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                CuvenHaptics.lightTap()
                showTagFriendsSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text(taggedFriendsSummaryText)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .foregroundStyle(draft.taggedUserIDs.isEmpty ? MomentsPalette.accessibleBlueText : CuvenColors.inkPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("moments.editor.tagFriendsButton")

            if let scheduledMillis = draft.scheduledAtMillis {
                HStack(spacing: 8) {
                    Button {
                        CuvenHaptics.lightTap()
                        showScheduleSheet = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(MomentsPalette.accessibleBlueText)
                            Text("Scheduled for \(MomentsTimeFormatter.scheduledWhenText(timestamp: scheduledMillis, use24Hour: store.prefs.use24HourTime))")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)

                    Button {
                        CuvenHaptics.lightTap()
                        var next = draft
                        next.scheduledAtMillis = nil
                        history.record(next)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share now instead")
                }
            }
        }
        .padding(.leading, 60)
        .padding(.trailing, 14)
    }

    // MARK: - 6. Sticky Footer Dock (Audience/Comment Menu + Undo/Redo + Tools + Character Ring)

    private var stickyFooterDock: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(CuvenColors.hairlineSeparator)
                .frame(height: 0.5)

            // Top footer row: Audience & Comment Policy Menu + Undo / Redo (`moments-editor.js:122`)
            HStack(spacing: 4) {
                Menu {
                    Section("Who can see it") {
                        Button {
                            updateAudience("everyone")
                        } label: {
                            Label(
                                "Everyone can see it",
                                systemImage: draft.audience == "everyone" ? "checkmark.circle.fill" : "globe"
                            )
                        }

                        Button {
                            updateAudience("friends")
                        } label: {
                            Label(
                                "Only friends can see it",
                                systemImage: draft.audience == "friends" ? "checkmark.circle.fill" : "person.2"
                            )
                        }
                    }

                    Section("Who can comment") {
                        Button {
                            updateCommentPolicy("everyone")
                        } label: {
                            Label(
                                "Everyone can comment",
                                systemImage: draft.commentPolicy == "everyone" ? "checkmark.circle.fill" : "bubble.left"
                            )
                        }

                        Button {
                            updateCommentPolicy("friends")
                        } label: {
                            Label(
                                "Only friends can comment",
                                systemImage: draft.commentPolicy == "friends" ? "checkmark.circle.fill" : "person.2"
                            )
                        }

                        Button {
                            updateCommentPolicy("off")
                        } label: {
                            Label(
                                "Comments off",
                                systemImage: draft.commentPolicy == "off" ? "checkmark.circle.fill" : "xmark.circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: draft.audience == "friends" ? "person.2.fill" : "globe")
                            .font(.system(size: 15, weight: .semibold))
                        Text(MomentsTimeFormatter.whoSummaryText(
                            audience: draft.audience,
                            commentPolicy: draft.commentPolicy
                        ))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    }
                    .foregroundStyle(MomentsPalette.accessibleBlueText)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("moments.editor.audienceMenu")

                Spacer(minLength: 4)

                Button {
                    CuvenHaptics.selectionChanged()
                    _ = history.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                        .opacity(history.canUndo ? 1.0 : 0.28)
                }
                .buttonStyle(.plain)
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("moments.editor.undoButton")

                Button {
                    CuvenHaptics.selectionChanged()
                    _ = history.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                        .opacity(history.canRedo ? 1.0 : 0.28)
                }
                .buttonStyle(.plain)
                .disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("moments.editor.redoButton")
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 50)

            Rectangle()
                .fill(CuvenColors.hairlineSeparator)
                .frame(height: 0.5)

            // Bottom footer row: PhotosPicker, Camera, Schedule, Character Ring (`moments-editor.js:123`)
            HStack(spacing: 6) {
                PhotosPicker(
                    selection: $photoPickerSelections,
                    maxSelectionCount: max(1, MomentEditorDraftState.maxPhotosCount - draft.mediaItems.count),
                    matching: draft.mediaItems.isEmpty ? .any(of: [.images, .videos]) : .images
                ) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                        .opacity(draft.isMediaFull ? 0.30 : 1.0)
                }
                .disabled(draft.isMediaFull)
                .accessibilityLabel("Add photos or a video")
                .accessibilityIdentifier("moments.editor.photoLibraryButton")

                Button {
                    CuvenHaptics.lightTap()
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCameraPicker = true
                    } else {
                        _ = attachGeneratedStudioPhoto(applyingTone: .original)
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                        .opacity(draft.isMediaFull ? 0.30 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(draft.isMediaFull)
                .accessibilityLabel("Take a photo or video")
                .accessibilityIdentifier("moments.editor.cameraButton")

                Button {
                    CuvenHaptics.lightTap()
                    showScheduleSheet = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(draft.scheduledAtMillis != nil ? MomentsPalette.accessibleBlueText : CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Schedule")
                .accessibilityIdentifier("moments.editor.scheduleButton")

                Spacer()

                // Circular Character-Remaining Progress Ring (`moments-editor.css:176-183`)
                if !draft.text.isEmpty {
                    characterRemainingRing
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 54)
            .padding(.bottom, max(metrics.safeAreaBottom, 8))
        }
        .background(.ultraThinMaterial)
    }

    private var characterRemainingRing: some View {
        let remaining = draft.remainingCharacters
        let nearLimit = remaining <= 100
        return ZStack {
            Circle()
                .stroke(CuvenColors.incomingBubble, lineWidth: 2.6)

            Circle()
                .trim(from: 0, to: draft.characterProgress)
                .stroke(
                    nearLimit ? CuvenColors.warningAmber : CuvenColors.systemBlue,
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if nearLimit {
                Text("\(remaining)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(CuvenColors.inkSecondary)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel("\(remaining) characters left")
    }

    // MARK: - State Mutations (All Recorded Through `MomentsEditorHistory`)

    private func selectMedia(id: String) {
        guard draft.selectedMediaID != id else { return }
        var next = draft
        next.selectedMediaID = id
        history.record(next)
    }

    private func removeMediaItem(id: String) {
        var next = draft
        next.mediaItems.removeAll { $0.id == id }
        if next.selectedMediaID == id {
            next.selectedMediaID = next.mediaItems.first?.id
        }
        history.record(next)
    }

    private func updateAudience(_ newAudience: String) {
        guard draft.audience != newAudience else { return }
        CuvenHaptics.selectionChanged()
        var next = draft
        next.audience = newAudience
        history.record(next)
    }

    private func updateCommentPolicy(_ newPolicy: String) {
        guard draft.commentPolicy != newPolicy else { return }
        CuvenHaptics.selectionChanged()
        var next = draft
        next.commentPolicy = newPolicy
        history.record(next)
    }

    private func applyAltDescription(_ alt: String, toMediaID mediaID: String) {
        let normalized = alt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let idx = draft.mediaItems.firstIndex(where: { $0.id == mediaID }) else { return }
        guard draft.mediaItems[idx].altText != normalized else { return }
        var next = draft
        next.mediaItems[idx].altText = normalized
        history.record(next)
    }

    private func applyPhotoEditParameters(_ params: PhotoEditParameters, toMediaID mediaID: String) {
        guard let idx = draft.mediaItems.firstIndex(where: { $0.id == mediaID }) else { return }
        let existing = draft.mediaItems[idx]
        guard existing.editParameters != params else { return }

        var updatedItem = existing
        updatedItem.editParameters = params

        if let origData = existing.originalImageData,
           let origImage = UIImage(data: origData) {
            if params.isIdentity {
                updatedItem.renderedImageData = origData
                updatedItem.renderedWidth = existing.originalWidth
                updatedItem.renderedHeight = existing.originalHeight
            } else if let exported = CoreImagePhotoFilterEngine.shared.exportJPEG(
                from: origImage,
                parameters: params,
                maxDimension: 2048,
                compressionQuality: 0.90
            ) {
                updatedItem.renderedImageData = exported.data
                updatedItem.renderedWidth = exported.width
                updatedItem.renderedHeight = exported.height
            }

            // Refresh filter thumbnails if rotation changed
            if existing.editParameters.rotationQuarterTurns != params.rotationQuarterTurns {
                filterStripThumbnails[mediaID] = CoreImagePhotoFilterEngine.shared.generateFilterStripThumbnails(
                    from: origImage,
                    rotationQuarterTurns: params.rotationQuarterTurns
                )
            }
        }

        var next = draft
        next.mediaItems[idx] = updatedItem
        next.selectedMediaID = mediaID
        history.record(next)
    }

    @discardableResult
    private func attachGeneratedStudioPhoto(applyingTone tone: PhotoToneFilter) -> String {
        let sampleImage = CoreImagePhotoFilterEngine.makeStudioSampleImage(presetIndex: studioSampleCounter)
        studioSampleCounter += 1
        return appendUIImageToDraft(sampleImage, initialTone: tone)
    }

    @discardableResult
    private func appendUIImageToDraft(_ image: UIImage, initialTone: PhotoToneFilter = .original) -> String {
        let baseParams = PhotoEditParameters(rotationQuarterTurns: 0, cropPreset: .original, tone: .original)
        let exportedOriginal = CoreImagePhotoFilterEngine.shared.exportJPEG(
            from: image,
            parameters: baseParams,
            maxDimension: 2048,
            compressionQuality: 0.90
        )
        let origData = exportedOriginal?.data ?? image.jpegData(compressionQuality: 0.90)
        let origW = exportedOriginal?.width ?? Int(image.size.width)
        let origH = exportedOriginal?.height ?? Int(image.size.height)

        var renderedData = origData
        var renderedW = origW
        var renderedH = origH
        let editParams = PhotoEditParameters(rotationQuarterTurns: 0, cropPreset: .original, tone: initialTone)

        if initialTone != .original,
           let toned = CoreImagePhotoFilterEngine.shared.exportJPEG(
               from: image,
               parameters: editParams,
               maxDimension: 2048,
               compressionQuality: 0.90
           ) {
            renderedData = toned.data
            renderedW = toned.width
            renderedH = toned.height
        }

        let itemID = UUID().uuidString
        let mediaItem = MomentEditableMediaItem(
            id: itemID,
            isVideo: false,
            originalImageData: origData,
            renderedImageData: renderedData,
            originalWidth: origW,
            originalHeight: origH,
            renderedWidth: renderedW,
            renderedHeight: renderedH,
            altText: "",
            editParameters: editParams
        )

        filterStripThumbnails[itemID] = CoreImagePhotoFilterEngine.shared.generateFilterStripThumbnails(from: image)

        var next = draft
        if next.mediaItems.count < MomentEditorDraftState.maxPhotosCount {
            next.mediaItems.append(mediaItem)
            next.selectedMediaID = itemID
            history.record(next)
        }
        return itemID
    }

    private static let maxVideoBytes: Int = 30 * 1024 * 1024

    private static func momentsMediaCacheDirectory() -> URL {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        let dir = baseCache.appendingPathComponent("CuvenMoments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        var addedItems: [MomentEditableMediaItem] = []
        for pickerItem in items {
            if draft.mediaItems.contains(where: \.isVideo) || addedItems.contains(where: \.isVideo) {
                break
            }
            if (draft.mediaItems.count + addedItems.count) >= MomentEditorDraftState.maxPhotosCount {
                break
            }

            let isVideoItem = pickerItem.supportedContentTypes.contains {
                $0.conforms(to: .movie) || $0.conforms(to: .video)
            }

            if isVideoItem {
                // `moments-editor.js:239, 243`: A video goes on its own (up to 30 MB).
                guard draft.mediaItems.isEmpty, addedItems.isEmpty, items.count == 1 else {
                    CuvenHaptics.warning()
                    continue
                }
                guard let data = try? await pickerItem.loadTransferable(type: Data.self),
                      !data.isEmpty,
                      data.count <= Self.maxVideoBytes else {
                    CuvenHaptics.warning()
                    continue
                }
                let itemID = UUID().uuidString
                let videoURL = Self.momentsMediaCacheDirectory()
                    .appendingPathComponent("cuven-moment-video-\(itemID).mp4")
                try? data.write(to: videoURL, options: .atomic)

                var videoW = 1080
                var videoH = 1920
                let asset = AVURLAsset(url: videoURL)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let natural = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let oriented = natural.applying(transform)
                    let w = Int(abs(oriented.width).rounded())
                    let h = Int(abs(oriented.height).rounded())
                    if w > 0, h > 0 {
                        videoW = w
                        videoH = h
                    }
                }

                let editable = MomentEditableMediaItem(
                    id: itemID,
                    isVideo: true,
                    originalImageData: nil,
                    mediaURLString: videoURL.absoluteString,
                    originalWidth: videoW,
                    originalHeight: videoH,
                    renderedWidth: videoW,
                    renderedHeight: videoH
                )
                addedItems.append(editable)
                break
            } else if let data = try? await pickerItem.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) {
                let normalized = CoreImagePhotoFilterEngine.shared.exportJPEG(
                    from: uiImage,
                    parameters: PhotoEditParameters(),
                    maxDimension: 2048,
                    compressionQuality: 0.90
                )
                let origData = normalized?.data ?? data
                let w = normalized?.width ?? Int(uiImage.size.width)
                let h = normalized?.height ?? Int(uiImage.size.height)
                let itemID = UUID().uuidString
                let editable = MomentEditableMediaItem(
                    id: itemID,
                    isVideo: false,
                    originalImageData: origData,
                    renderedImageData: origData,
                    originalWidth: w,
                    originalHeight: h,
                    renderedWidth: w,
                    renderedHeight: h
                )
                filterStripThumbnails[itemID] = CoreImagePhotoFilterEngine.shared.generateFilterStripThumbnails(from: uiImage)
                addedItems.append(editable)
            }
        }
        guard !addedItems.isEmpty else { return }
        var next = draft
        next.mediaItems.append(contentsOf: addedItems)
        next.selectedMediaID = addedItems.last?.id ?? next.selectedMediaID
        history.record(next)
    }

    private func attemptDismissEditor() {
        if draft.hasUnsavedChanges {
            CuvenHaptics.warning()
            showDiscardConfirmation = true
        } else {
            onDismiss()
        }
    }

    // MARK: - Publish Execution (`store.publishMoment(...)`)

    private func publishDraftMoment() async {
        guard draft.hasPublishableContent, !isPublishing else { return }
        isPublishing = true
        publishProgressFraction = 0.15
        publishStatusText = draft.mediaItems.isEmpty ? "Sharing…" : "Preparing media…"

        var publishedMedia: [MomentMedia] = []
        let totalSteps = CGFloat(max(1, draft.mediaItems.count + 1))
        let cacheDir = Self.momentsMediaCacheDirectory()

        for (index, item) in draft.mediaItems.enumerated() {
            publishStatusText = draft.mediaItems.count > 1
                ? "Processing \(index + 1) of \(draft.mediaItems.count)…"
                : (item.isVideo ? "Processing video…" : "Processing photo…")
            publishProgressFraction = CGFloat(index + 1) / totalSteps

            let resolvedURL: String
            if let existingURL = item.mediaURLString, !existingURL.isEmpty {
                resolvedURL = existingURL
            } else if let data = item.renderedImageData {
                let cachedFileURL = cacheDir.appendingPathComponent("cuven-moment-\(item.id).jpg")
                try? data.write(to: cachedFileURL, options: .atomic)
                resolvedURL = cachedFileURL.absoluteString
            } else {
                resolvedURL = "cuven-demo://moment/\(item.id)"
            }

            let trimmedAlt = item.altText.trimmingCharacters(in: .whitespacesAndNewlines)
            publishedMedia.append(
                MomentMedia(
                    id: item.id,
                    url: resolvedURL,
                    isVideo: item.isVideo,
                    width: item.renderedWidth,
                    height: item.renderedHeight,
                    altText: trimmedAlt.isEmpty ? nil : trimmedAlt,
                    filterName: item.editParameters.tone == .original ? nil : item.editParameters.tone.rawValue
                )
            )
        }

        publishStatusText = draft.scheduledAtMillis != nil ? "Scheduling…" : "Sharing…"
        publishProgressFraction = 0.92

        await store.publishMoment(
            text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            media: publishedMedia,
            audience: draft.audience,
            commentPolicy: draft.commentPolicy,
            taggedUserIDs: draft.taggedUserIDs,
            scheduledAt: draft.scheduledAtMillis
        )

        publishProgressFraction = 1.0
        CuvenHaptics.success()
        onDismiss()
    }
}

// MARK: - Sub-Modal 1: Full-Stage CoreImage Photo Studio (`moments-editor.js:495-569`)

private struct MomentPhotoStudioModal: View {
    let mediaItem: MomentEditableMediaItem
    let onApply: (PhotoEditParameters) -> Void
    let onCancel: () -> Void

    @State private var workingParams: PhotoEditParameters
    @State private var stagePreviewImage: UIImage?
    @State private var toneThumbnails: [PhotoToneFilter: UIImage] = [:]

    init(
        mediaItem: MomentEditableMediaItem,
        onApply: @escaping (PhotoEditParameters) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mediaItem = mediaItem
        self.onApply = onApply
        self.onCancel = onCancel
        self._workingParams = State(initialValue: mediaItem.editParameters)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Dark studio stage (`moments-editor.css:223`)
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(white: 0.08))

                    if let stagePreviewImage {
                        Image(uiImage: stagePreviewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(12)
                    } else {
                        MomentsEditorialSeedArtwork(
                            seedKey: mediaItem.id,
                            filterName: workingParams.tone.rawValue
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(12)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)

                // Rotate + Aspect Crop row
                HStack(spacing: 10) {
                    Button {
                        CuvenHaptics.lightTap()
                        workingParams = workingParams.rotated90Clockwise()
                        refreshPreview(regenerateThumbs: true)
                    } label: {
                        Label("Rotate", systemImage: "rotate.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(CuvenColors.incomingBubble, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Picker("Crop", selection: $workingParams.cropPreset) {
                        ForEach(PhotoAspectCropPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: workingParams.cropPreset) { _, _ in
                        CuvenHaptics.selectionChanged()
                        refreshPreview(regenerateThumbs: false)
                    }
                }

                // 6-Tone CoreImage Strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(PhotoToneFilter.allCases) { tone in
                            let selected = (workingParams.tone == tone)
                            Button {
                                CuvenHaptics.selectionChanged()
                                workingParams.tone = tone
                                refreshPreview(regenerateThumbs: false)
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if let thumb = toneThumbnails[tone] {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            ToneSwatchFallbackPreview(tone: tone)
                                        }
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                selected ? CuvenColors.ctaInk : CuvenColors.hairlineSeparator,
                                                lineWidth: selected ? 2.5 : 1.0
                                            )
                                    }

                                    Text(tone.displayName)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(CuvenColors.paperBackground)
            .navigationTitle("Edit photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        CuvenHaptics.lightTap()
                        onApply(workingParams)
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                refreshPreview(regenerateThumbs: true)
            }
        }
    }

    private func refreshPreview(regenerateThumbs: Bool) {
        guard let origData = mediaItem.originalImageData,
              let origUIImage = UIImage(data: origData) else { return }
        stagePreviewImage = CoreImagePhotoFilterEngine.shared.apply(
            to: origUIImage,
            parameters: workingParams,
            maxDimension: 900
        )
        if regenerateThumbs {
            toneThumbnails = CoreImagePhotoFilterEngine.shared.generateFilterStripThumbnails(
                from: origUIImage,
                rotationQuarterTurns: workingParams.rotationQuarterTurns
            )
        }
    }
}

// MARK: - Sub-Modal 2: `+ALT` Accessibility Description Editor (`moments-editor.js:341-363`)

private struct MomentAltDescriptionEditorModal: View {
    let mediaItem: MomentEditableMediaItem
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var altDraft: String
    @FocusState private var isFocused: Bool

    init(
        mediaItem: MomentEditableMediaItem,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mediaItem = mediaItem
        self.onSave = onSave
        self.onCancel = onCancel
        self._altDraft = State(initialValue: mediaItem.altText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let data = mediaItem.renderedImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 200)
                        .background(CuvenColors.incomingBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                TextField("Describe what’s in the photo", text: $altDraft, axis: .vertical)
                    .font(CuvenFonts.cappedBody(weight: .regular))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(4...8)
                    .focused($isFocused)
                    .padding(12)
                    .background(CuvenColors.incomingBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onChange(of: altDraft) { _, newValue in
                        if newValue.count > MomentEditorDraftState.maxAltCharacters {
                            altDraft = String(newValue.prefix(MomentEditorDraftState.maxAltCharacters))
                        }
                    }
                    .accessibilityIdentifier("moments.editor.altTextField")

                HStack {
                    Text("Read aloud to people who use VoiceOver.")
                        .font(.system(size: 13))
                        .foregroundStyle(CuvenColors.inkSecondary)
                    Spacer()
                    Text("\(altDraft.count)/\(MomentEditorDraftState.maxAltCharacters)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }

                Spacer()
            }
            .padding(20)
            .background(CuvenColors.paperBackground)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        CuvenHaptics.lightTap()
                        onSave(altDraft)
                    }
                    .fontWeight(.bold)
                    .accessibilityIdentifier("moments.editor.altDoneButton")
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

// MARK: - Sub-Modal 3: `@Tag Friends` Multi-Select Picker (`moments-editor.js:367-404`)

private struct MomentTagFriendsPickerSheet: View {
    let friends: [CuvenUser]
    let onSave: ([String]) -> Void
    let onCancel: () -> Void

    @State private var pickedIDs: Set<String>
    @State private var searchQuery: String = ""

    init(
        friends: [CuvenUser],
        selectedUserIDs: [String],
        onSave: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.friends = friends
        self._pickedIDs = State(initialValue: Set(selectedUserIDs))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var filteredFriends: [CuvenUser] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return friends }
        return friends.filter { u in
            u.display.lowercased().contains(q) || u.username.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(CuvenColors.inkSecondary)
                    TextField("Search friends", text: $searchQuery)
                        .font(.system(size: 16))
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(CuvenColors.incomingBubble, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if filteredFriends.isEmpty {
                    VStack(spacing: 8) {
                        Text(friends.isEmpty ? "No friends to tag yet" : "No matching friends")
                            .font(CuvenFonts.cappedHeadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                        Text("You can tag your accepted contacts and people you chat with.")
                            .font(.system(size: 14))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    Spacer()
                } else {
                    List(filteredFriends) { friend in
                        let isChecked = pickedIDs.contains(friend.id)
                        Button {
                            if isChecked {
                                pickedIDs.remove(friend.id)
                                CuvenHaptics.selectionChanged()
                            } else if pickedIDs.count < MomentEditorDraftState.maxTaggedFriends {
                                pickedIDs.insert(friend.id)
                                CuvenHaptics.selectionChanged()
                            } else {
                                CuvenHaptics.warning()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                CuvenAvatarView(
                                    name: friend.display.isEmpty ? friend.username : friend.display,
                                    urlString: friend.avatarURL,
                                    size: 44,
                                    isOnline: friend.isOnline
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.display.isEmpty ? friend.username : friend.display)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                    Text("@\(friend.username)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(CuvenColors.inkSecondary)
                                }

                                Spacer()

                                ZStack {
                                    Circle()
                                        .fill(isChecked ? CuvenColors.ctaInk : Color.clear)
                                        .frame(width: 26, height: 26)
                                    if isChecked {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(CuvenColors.onCtaInk)
                                    } else {
                                        Circle()
                                            .strokeBorder(CuvenColors.inkSecondary.opacity(0.6), lineWidth: 1.5)
                                            .frame(width: 26, height: 26)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(CuvenColors.paperBackground)
                    }
                    .listStyle(.plain)
                }

                Text("\(pickedIDs.count) of up to \(MomentEditorDraftState.maxTaggedFriends) · Friends you tag see it with them.")
                    .font(.system(size: 13))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(14)
            }
            .background(CuvenColors.paperBackground)
            .navigationTitle("Tag people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let ordered = friends.map(\.id).filter { pickedIDs.contains($0) }
                        onSave(ordered)
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

// MARK: - Sub-Modal 4: Scheduled Publish Date/Time Picker (`moments-editor.js:408-447`)

private struct MomentSchedulePickerSheet: View {
    let currentScheduledMillis: Int64?
    let use24HourTime: Bool
    let onSave: (Int64?) -> Void
    let onCancel: () -> Void

    @State private var chosenDate: Date

    init(
        currentScheduledMillis: Int64?,
        use24HourTime: Bool,
        onSave: @escaping (Int64?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentScheduledMillis = currentScheduledMillis
        self.use24HourTime = use24HourTime
        self.onSave = onSave
        self.onCancel = onCancel
        if let millis = currentScheduledMillis {
            self._chosenDate = State(initialValue: MomentsTimeFormatter.date(fromEpoch: millis))
        } else {
            self._chosenDate = State(initialValue: Date().addingTimeInterval(3600))
        }
    }

    private var minimumAllowedDate: Date {
        Date().addingTimeInterval(4 * 60)
    }

    private var maximumAllowedDate: Date {
        Date().addingTimeInterval(30 * 24 * 3600)
    }

    private var isValidWindow: Bool {
        chosenDate >= Date().addingTimeInterval(60) && chosenDate <= maximumAllowedDate
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                // Quick preset chips (`In 1 hour`, `Tonight 20:00`, `Tomorrow 9:00`)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPresets, id: \.label) { preset in
                            Button {
                                CuvenHaptics.selectionChanged()
                                chosenDate = preset.date
                            } label: {
                                Text(preset.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkPrimary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background(CuvenColors.incomingBubble, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                DatePicker(
                    "Publish date and time",
                    selection: $chosenDate,
                    in: minimumAllowedDate...maximumAllowedDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                Text(isValidWindow
                     ? "Shares \(MomentsTimeFormatter.scheduledWhenText(date: chosenDate, use24Hour: use24HourTime))"
                     : "Pick a time from a few minutes to 30 days ahead")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isValidWindow ? CuvenColors.inkPrimary : CuvenColors.dangerRed)

                Text("Only you see it until then. Up to 30 days ahead.")
                    .font(.system(size: 13))
                    .foregroundStyle(CuvenColors.inkSecondary)

                if currentScheduledMillis != nil {
                    Button {
                        CuvenHaptics.lightTap()
                        onSave(nil)
                    } label: {
                        Text("Share it now instead")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MomentsPalette.accessibleBlueText)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(CuvenColors.paperBackground)
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schedule") {
                        CuvenHaptics.success()
                        onSave(MomentsTimeFormatter.epochMilliseconds(from: chosenDate))
                    }
                    .fontWeight(.bold)
                    .disabled(!isValidWindow)
                }
            }
        }
    }

    private var quickPresets: [(label: String, date: Date)] {
        let now = Date()
        let cal = Calendar.current
        let inOneHour = now.addingTimeInterval(3600)

        var tonightComps = cal.dateComponents([.year, .month, .day], from: now)
        tonightComps.hour = 20
        tonightComps.minute = 0
        let today20 = cal.date(from: tonightComps) ?? inOneHour
        let eveningTarget = (today20 > now.addingTimeInterval(300))
            ? (label: "Tonight, 20:00", date: today20)
            : (label: "Tomorrow, 20:00", date: cal.date(byAdding: .day, value: 1, to: today20) ?? inOneHour)

        let tomorrowBase = cal.date(byAdding: .day, value: 1, to: now) ?? inOneHour
        var tomorrow9Comps = cal.dateComponents([.year, .month, .day], from: tomorrowBase)
        tomorrow9Comps.hour = 9
        tomorrow9Comps.minute = 0
        let tomorrow9 = cal.date(from: tomorrow9Comps) ?? inOneHour

        return [
            (label: "In an hour", date: inOneHour),
            eveningTarget,
            (label: "Tomorrow, 9:00", date: tomorrow9)
        ]
    }
}

// MARK: - Tone Swatch Preview & Camera Picker Bridge

private struct ToneSwatchFallbackPreview: View {
    let tone: PhotoToneFilter

    var body: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Circle()
                .fill(Color.white.opacity(tone == .fade ? 0.55 : 0.80))
                .frame(width: 16, height: 16)
                .offset(x: 10, y: -10)
        }
    }

    private var gradientColors: [Color] {
        switch tone {
        case .original:
            return [Color(red: 0.25, green: 0.54, blue: 0.88), Color(red: 0.92, green: 0.54, blue: 0.42)]
        case .vivid:
            return [Color(red: 0.06, green: 0.48, blue: 1.00), Color(red: 1.00, green: 0.34, blue: 0.30)]
        case .warm:
            return [Color(red: 0.96, green: 0.64, blue: 0.24), Color(red: 0.78, green: 0.36, blue: 0.28)]
        case .cool:
            return [Color(red: 0.16, green: 0.60, blue: 0.86), Color(red: 0.24, green: 0.30, blue: 0.68)]
        case .mono:
            return [Color(white: 0.82), Color(white: 0.16)]
        case .fade:
            return [Color(red: 0.58, green: 0.64, blue: 0.72), Color(red: 0.76, green: 0.66, blue: 0.64)]
        }
    }
}

private struct MomentsCameraCapturePicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
