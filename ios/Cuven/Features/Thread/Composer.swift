import SwiftUI
import TipKit
import ImagePlayground
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// The message field and everything that comes out of it: the "+" in the
/// field and the attachments panel growing from it, Send once there's
/// something to send, a voice message recorded by holding the empty field
/// (release to send, slide up or away to cancel), replies and edits,
/// @mentions in groups and the writing help's suggestion.
struct Composer: View {
    let room: Room
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    @Binding var stickersOpen: Bool

    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var plusOpen = false
    @State private var suggestion = ""
    /// Reply ideas from the on-device model, while the field is empty.
    @State private var ideas: [String] = []
    @State private var recorder = VoiceRecorder()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showLocation = false
    @State private var showPlayground = false
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var mentionIds: [String: String] = [:]
    @State private var savedDraft = ""
    @FocusState private var focused: Bool
    /// The field and Send are one piece of glass: Send flows out of it.
    @Namespace private var glassSpace
    /// Holding the field to talk: the finger is down past the hold, and
    /// whether it has slid far enough to cancel on release.
    @State private var holding = false
    @State private var cancelArmed = false
    @State private var holdEnded = Date.distantPast
    /// The two-minute limit has sent this hold's recording: the rest of the
    /// touch starts nothing new.
    @State private var sentAtLimit = false
    /// Resets by itself when the system cancels the hold (onEnded never comes).
    @GestureState private var pressing = false

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Send (or ✓) only once there's something to send or an edit to save.
    private var showsSend: Bool { canSend || editing != nil }
    /// The empty field records while held.
    /// Touch and hold the empty field to record, while the keyboard is down;
    /// with it up the field is the system's own (Paste, selection).
    private var holdToTalk: Bool { text.isEmpty && editing == nil && !focused }

    /// The composer's controls are 56pt (the web's .field and .composer-action).
    static let control: CGFloat = 56
    private var margin: CGFloat { ctx.size.width < 400 ? 16 : 20 }
    private var editingOrReply: Bool { editing != nil || replyTo != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let chips = mentionCandidates, !chips.isEmpty {
                mentionPicker(chips)
            } else if text.isEmpty && !ideas.isEmpty && !recorder.isRecording && editing == nil {
                ideaChips
            } else if !suggestion.isEmpty && !recorder.isRecording {
                suggestionChip
            }

            HStack(alignment: .bottom, spacing: 10) {
                // The field stays put while recording (it holds the gesture);
                // the recording shows over it. Send flows out of the field's
                // glass and back into it (one GlassGroup, matched ids).
                GlassGroup(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 10) {
                        field
                            .popoverTip(HoldToTalkTip(), arrowEdge: .bottom)
                            .overlay {
                                if recorder.isRecording {
                                    RecordingBar(recorder: recorder, cancelArmed: cancelArmed)
                                        .allowsHitTesting(false)
                                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                }
                            }
                        if showsSend {
                            trailingButton
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                PlusPanel(open: plusOpen, stickers: model.stickersEnabled, imagine: supportsImagePlayground) { action in
                    withAnimation(Motion.morph) { plusOpen = false }
                    switch action {
                    case .photos: showPhotos = true
                    case .camera: showCamera = true
                    case .location: showLocation = true
                    case .imagine: showPlayground = true
                    case .drawing: nav.show(.draw)
                    case .stickers: stickersOpen = true
                    case .file: showFiles = true
                    }
                }
                // Open, the button is the panel's corner: its + turns into × above the card.
                if plusOpen {
                    Button {
                        Haptics.tap()
                        withAnimation(Motion.morph) { plusOpen = false }
                    } label: {
                        SymbolView(.plus, size: 22, weight: 2.2)
                            .foregroundStyle(Theme.label)
                            .rotationEffect(.degrees(45))
                            .frame(width: 42, height: 42)
                            .glassCircle()
                    }
                    .buttonStyle(.press(0.9))
                    .padding(.trailing, 7)
                    .padding(.bottom, 7)
                    .transition(.identity)
                    .accessibilityLabel("Close")
                }
                }
            }
        }
        .padding(.top, 12)
        .padding(.leading, max(ctx.insets.leading, margin))
        .padding(.trailing, ctx.usesRail ? ctx.insets.trailing + margin : max(ctx.insets.trailing, margin))
        .animation(Motion.morph, value: plusOpen)
        .animation(Motion.ui, value: canSend)
        .animation(Motion.ui, value: showsSend)
        .animation(Motion.move, value: replyTo?.id)
        .animation(Motion.move, value: editing?.id)
        .animation(Motion.ui, value: suggestion)
        .animation(Motion.ui, value: recorder.isRecording)
        .onAppear {
            text = model.drafts[room.id] ?? ""
        }
        .onChange(of: text) { _, v in
            // While editing, the field holds the message, not the draft
            // (send and cancel put the draft back, which saves it here).
            if editing == nil {
                model.drafts[room.id] = v
                model.sendTyping(v, room: room.id)
            }
            if !v.isEmpty && plusOpen { withAnimation(Motion.morph) { plusOpen = false } }
        }
        .onChange(of: editing?.id) { old, _ in
            if let e = editing {
                // From one edit straight to another: the draft kept is still the one from before.
                if old == nil { savedDraft = text }
                text = e.body
                focused = true
            } else if old != nil {
                // Ended from outside (a reply instead): the draft comes back.
                text = savedDraft
            }
        }
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .task(id: text) { await fetchSuggestion() }
        .task(id: ideasKey) {
            guard onScreen else { return }
            await fetchIdeas()
        }
        // Out of sight nothing is written, but ideas for a message that's no
        // longer the last don't stay up (behind a card, or in a swipe back).
        .onChange(of: lastIncomingID) { _, _ in if !onScreen { ideas = [] } }
        .animation(Motion.ui, value: ideas)
        .onReceive(NotificationCenter.default.publisher(for: .automationPlus)) { _ in
            withAnimation(Motion.morph) { plusOpen = true }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems, maxSelectionCount: 9, matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await send(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image { model.sendPicture(image, room: room.id, replyTo: takeReply()) }
            }
            .ignoresSafeArea()
        }
        // A picture made with Image Playground, on the device, sent as a photo.
        .imagePlaygroundSheet(isPresented: $showPlayground, concepts: []) { url in
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                model.sendPicture(image, room: room.id, replyTo: takeReply())
            }
        }
        .sheet(isPresented: $showLocation) {
            LocationPicker { place in
                model.sendLocation(latitude: place.latitude, longitude: place.longitude, name: place.name,
                                   address: place.address, room: room.id, replyTo: takeReply())
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFile(url) }
        }
    }

    // MARK: field

    /// A white pill on a hairline (glass here): the words, then "+" inside its
    /// trailing end. A reply or an edit adds a strip at its top, and it
    /// eases into a rounded rectangle.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: editingOrReply ? 23 : Self.control / 2, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            if let strip = strip {
                strip
                    .padding(.trailing, 2)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(editing != nil ? "Edit message" : "Message", text: $text, axis: .vertical)
                    // Apple Intelligence's Writing Tools, in full where the device has them.
                    .writingToolsBehavior(.complete)
                    .font(.bodyC)
                    .lineSpacing(BodyMetrics.extra)
                    .lineLimit(1...5)
                    .focused($focused)
                    .tint(Theme.blue)
                    .padding(.vertical, 9 + BodyMetrics.extra / 2)
                    .frame(minHeight: 42)
                    .onSubmit { send() }
                    .overlay {
                        if holdToTalk {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(holdGesture)
                                .simultaneousGesture(TapGesture().onEnded {
                                    guard !holding, !recorder.isRecording, Date().timeIntervalSince(holdEnded) > 0.4 else { return }
                                    focused = true
                                })
                                .onChange(of: pressing) { _, down in
                                    guard !down else { return }
                                    // Let a normal release finish first; whatever is left was cancelled.
                                    DispatchQueue.main.async {
                                        sentAtLimit = false
                                        guard holding else { return }
                                        recorder.cancel()
                                        holding = false
                                        cancelArmed = false
                                        holdEnded = Date()
                                    }
                                }
                                .accessibilityElement()
                                .accessibilityLabel("Message")
                                .accessibilityHint("Double-tap to type. Touch and hold to record a voice message.")
                                .accessibilityAction(named: "Type") { focused = true }
                        }
                    }
                // Send takes over once there's something to send.
                if editing == nil && !showsSend {
                    Button {
                        withAnimation(Motion.morph) { plusOpen.toggle() }
                    } label: {
                        SymbolView(.plus, size: 22, weight: 2.2)
                            .foregroundStyle(Theme.label)
                            .rotationEffect(.degrees(plusOpen ? 45 : 0))
                            .frame(width: 42, height: 42)
                            .glassCircle()
                    }
                    .buttonStyle(.press(0.9))
                    .zIndex(3)
                    .accessibilityLabel(plusOpen ? "Close" : "Add")
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .padding(.top, editingOrReply ? 9 : 7)
        .padding(.bottom, 7)
        .frame(minHeight: Self.control)
        .glass(shape, interactive: false, morph: "field", in: glassSpace)
        .overlay(shape.strokeBorder(focused ? Theme.label3 : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .zIndex(2)
    }

    /// After the field once there's something to send: Send, filled with
    /// ink; ✓ while editing.
    private var trailingButton: some View {
        Button { send() } label: {
            SymbolView(editing != nil ? .check : .arrowUp, size: 22, weight: 2.5)
                .foregroundStyle(Theme.onInk)
                .frame(width: Self.control, height: Self.control)
                // Ink glass, the prominent action (HIG: tint the one primary control).
                .glass(Circle(), tint: Theme.ink, interactive: true, morph: "send", in: glassSpace)
        }
        .buttonStyle(.press(0.9))
        .opacity(plusOpen ? 0 : 1)
        .accessibilityLabel(editing != nil ? "Save" : "Send")
    }

    // MARK: strips, chips

    private var strip: AnyView? {
        if let e = editing {
            return AnyView(stripView(sym: .pencil, title: "Editing", text: e.body, rule: false) {
                editing = nil
                text = savedDraft
            })
        }
        if let r = replyTo {
            return AnyView(stripView(sym: nil, title: "Replying to \(model.name(of: r.sender))", text: r.preview, rule: true) {
                replyTo = nil
            })
        }
        return nil
    }

    private func stripView(sym: Sym?, title: LocalizedStringKey, text: String, rule: Bool, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if let sym { SymbolView(sym, size: 17).foregroundStyle(Theme.blue) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.make(13, .semibold)).foregroundStyle(Theme.blueText).lineLimit(1)
                Text(text).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
            }
            .padding(.leading, rule ? 11 : 0)
            .overlay(alignment: .leading) {
                if rule { RoundedRectangle(cornerRadius: 2).fill(Theme.blue).frame(width: 3).padding(.vertical, 1) }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                SymbolView(.xmark, size: 13, weight: 2.2).foregroundStyle(Theme.label2)
                    .frame(width: 30, height: 30)
                    .background(Theme.fill4, in: Circle())
                    .contentShape(Circle().inset(by: -7))
            }
            .buttonStyle(.press(0.9))
            .accessibilityLabel("Cancel")
        }
    }

    private var suggestionChip: some View {
        Button {
            let joiner = text.isEmpty || text.hasSuffix(" ") || suggestion.hasPrefix(" ") ? "" : (isCJK(suggestion) ? "" : " ")
            text += joiner + suggestion
            suggestion = ""
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                SymbolView(.sparkles, size: 13)
                Text(suggestion).lineLimit(1)
            }
            .font(.footnoteC)
            .foregroundStyle(Theme.label2)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassCapsule()
        }
        .buttonStyle(.press)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.9)))
        .accessibilityLabel(Text("Use suggestion: \(suggestion)"))
    }

    /// Up to three replies the on-device model thinks of: a tap puts one in
    /// the field to send or change (it never sends by itself).
    private var ideaChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ideas, id: \.self) { idea in
                    Button {
                        text = idea
                        ideas = []
                        focused = true
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            if idea == ideas.first { SymbolView(.sparkles, size: 13) }
                            Text(idea).lineLimit(1)
                        }
                        .font(.footnoteC)
                        .foregroundStyle(Theme.label)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glassCapsule()
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel(Text("Use suggestion: \(idea)"))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    /// The latest message from someone else, if it's the last one: what reply ideas answer.
    private var lastIncomingID: String? {
        guard let last = model.messages(room.id).last, last.sender != model.me?.id, !last.isRevoked else { return nil }
        return last.id
    }

    /// This chat is the one on screen, with the app in front: the only time
    /// the on-device model writes reply ideas for it.
    private var onScreen: Bool {
        nav.room == room.id && nav.isVisible(.chat) && !nav.sheeted && scenePhase == .active
    }

    /// What the reply ideas answer while on screen ("" for nothing to
    /// answer), nil while not: a chat out of sight never runs the model.
    private var ideasKey: String? { onScreen ? (lastIncomingID ?? "") : nil }

    private func fetchIdeas() async {
        ideas = []
        guard model.predictions, LocalAI.available, let id = lastIncomingID else { return }
        // Coming back to the chat: the ideas already written for this message.
        if let hit = IdeaCache.byMessage[id] {
            if text.isEmpty { ideas = hit }
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        let lines = LocalAI.lines(model.messages(room.id), me: model.me?.id) { model.name(of: $0) }
        let found = await LocalAI.replies(to: lines)
        if !found.isEmpty {
            if IdeaCache.byMessage.count > 64 { IdeaCache.byMessage.removeAll() }
            IdeaCache.byMessage[id] = found
        }
        if !Task.isCancelled && text.isEmpty { ideas = found }
    }

    private func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
    }

    private var mentionCandidates: [Member]? {
        guard room.isGroup, let token = text.split(separator: " ", omittingEmptySubsequences: false).last, token.hasPrefix("@") else { return nil }
        let q = token.dropFirst().lowercased()
        return (model.members[room.id] ?? []).filter { $0.id != model.me?.id && (q.isEmpty || $0.display.lowercased().hasPrefix(q) || $0.username.lowercased().hasPrefix(q)) }
    }

    private func mentionPicker(_ list: [Member]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(list) { m in
                    Button {
                        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                        parts.removeLast()
                        parts.append("@\(m.display) ")
                        text = parts.joined(separator: " ")
                        mentionIds[m.display] = m.id
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 10) {
                            Avatar(user: m.user, size: 28)
                            Text(m.display).font(.calloutC).foregroundStyle(Theme.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FillPressStyle(radius: 18, fill: Theme.fill4))
                }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(264, CGFloat(list.count) * 44 + 12))
        .glass(RoundedRectangle(cornerRadius: 23, style: .continuous), interactive: false)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    // MARK: voice

    /// Touch and hold the empty field to record; let go to send it, or slide
    /// up (or back toward the leading edge) first to cancel.
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($pressing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !holding {
                    guard !sentAtLimit else { return }
                    // Not over a call: recording would take the call's sound.
                    if model.calls.active {
                        sentAtLimit = true
                        model.show(String(localized: "You can't record during a call"), error: true)
                        return
                    }
                    holding = true
                    cancelArmed = false
                    HoldToTalkTip().invalidate(reason: .actionPerformed)
                    Haptics.press()
                    if plusOpen { withAnimation(Motion.morph) { plusOpen = false } }
                    // Two minutes is as long as one goes: it's sent as it is,
                    // and letting go afterwards does nothing more.
                    recorder.onLimit = { data, duration in
                        holding = false
                        cancelArmed = false
                        sentAtLimit = true
                        holdEnded = Date()
                        guard duration >= 0.6 else { return }
                        model.sendVoice(data, duration: duration, room: room.id)
                        Haptics.success()
                    }
                    recorder.start()
                }
                let t = drag?.translation ?? .zero
                let armed = t.height < -64 || t.width < -110
                if armed != cancelArmed {
                    cancelArmed = armed
                    Haptics.selection()
                }
            }
            .onEnded { value in
                sentAtLimit = false
                guard case .second(true, _) = value, holding else { return }
                if cancelArmed || !recorder.isRecording {
                    recorder.cancel()
                    if cancelArmed { Haptics.warning() }
                } else {
                    finishRecording()
                }
                holding = false
                cancelArmed = false
                holdEnded = Date()
            }
    }

    private func finishRecording() {
        guard let res = recorder.finish(), res.1 >= 0.6 else {
            recorder.cancel()
            return
        }
        model.sendVoice(res.0, duration: res.1, room: room.id)
        Haptics.success()
    }

    // MARK: sending

    private func takeReply() -> Message? {
        let r = replyTo
        replyTo = nil
        return r
    }

    private func send() {
        if recorder.isRecording { finishRecording(); return }
        let t = text
        if let e = editing {
            editing = nil
            text = savedDraft
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            Task { await model.edit(e, text: t) }
            return
        }
        guard canSend else { return }
        let mentions = mentionIds.filter { t.contains("@\($0.key)") }.map(\.value)
        model.sendText(t, room: room.id, replyTo: takeReply(), mentions: mentions)
        text = ""
        suggestion = ""
        mentionIds = [:]
    }

    private func send(_ items: [PhotosPickerItem]) async {
        var reply = takeReply()
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                // Re-encoding can take a moment: say so rather than look stuck.
                model.show(String(localized: "Preparing video…"))
                do {
                    let v = try await VideoPrep.load(item)
                    model.sendVideo(v.data, size: v.size, duration: v.duration, room: room.id)
                } catch VideoPrep.Failure.tooLong {
                    model.show(String(localized: "Video is too long to send"), error: true)
                } catch {}
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // Scaled and encoded off the main thread, never decoded in full.
            if let p = await Task.detached(priority: .userInitiated, operation: { Media.prepare(data: data, maxSide: 2048) }).value {
                model.sendPrepared(p, room: room.id, replyTo: reply)
                reply = nil
            }
        }
    }

    private func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        model.sendFile(data, name: url.lastPathComponent, contentType: type, room: room.id)
    }

    private func fetchSuggestion() async {
        // On the device first (Apple's model), else the server's writing help.
        let local = LocalAI.available
        guard model.predictions, local || model.assistEnabled, editing == nil, !text.contains("\n") else {
            if !suggestion.isEmpty { suggestion = "" }
            return
        }
        if !text.isEmpty { ideas = [] }
        // An empty field has the on-device reply ideas instead.
        if text.isEmpty && local {
            if !suggestion.isEmpty { suggestion = "" }
            return
        }
        // Empty field: only once focused, and only to answer the other person.
        if text.isEmpty {
            guard focused, let last = model.messages(room.id).last, last.sender != model.me?.id, last.type == "text" else {
                suggestion = ""
                return
            }
        }
        suggestion = ""
        try? await Task.sleep(for: .milliseconds(450))
        if Task.isCancelled { return }
        let s: String
        if local {
            let lines = LocalAI.lines(model.messages(room.id), me: model.me?.id) { model.name(of: $0) }
            s = await LocalAI.continuation(of: text, after: lines)
        } else {
            s = await model.suggest(room: room.id, draft: text)
        }
        if !Task.isCancelled { suggestion = s.trimmingCharacters(in: .newlines) }
    }
}

/// Reply ideas already written, by the message they answer: coming back to
/// a chat doesn't run the model again for the same message.
@MainActor
private enum IdeaCache {
    static var byMessage: [String: [String]] = [:]
}

/// While the field is held: the time, the level, and what letting go
/// will do (send, or, slid up or away, cancel). Its own view, so the
/// recorder's ticks redraw only this, not the whole composer.
private struct RecordingBar: View {
    let recorder: VoiceRecorder
    let cancelArmed: Bool

    var body: some View {
        HStack(spacing: 12) {
            if cancelArmed {
                SymbolView(.trash, size: 20).foregroundStyle(Theme.red)
                    .frame(width: 24)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle().fill(Theme.red).frame(width: 9, height: 9)
                    .opacity(recorder.blink ? 1 : 0.25)
                    .frame(width: 24)
            }
            Text(Fmt.duration(recorder.elapsed)).font(.subheadMediumC.monospacedDigit()).foregroundStyle(Theme.label)
            LevelMeter(levels: recorder.levels).frame(height: 26)
                .opacity(cancelArmed ? 0.35 : 1)
            Text(cancelArmed ? "Release to cancel" : "Slide up to cancel")
                .font(.footnoteC)
                .foregroundStyle(cancelArmed ? Theme.red : Theme.label2)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Over the field's words and "+", which stay underneath holding the gesture.
        .background(Theme.bg, in: Capsule())
        .glass(Capsule(), tint: cancelArmed ? Theme.red.opacity(0.12) : nil, interactive: false)
        .animation(Motion.quick, value: cancelArmed)
    }
}

// MARK: - The "+" panel

enum PlusAction { case photos, camera, location, drawing, imagine, stickers, file }

/// The web's .composer-panel: 212pt wide, standing on the composer's
/// trailing end, its body clipped from the button's 56pt circle out to a
/// card with 24pt corners (280ms), the tools fading in after it.
struct PlusPanel: View {
    var open: Bool
    var stickers: Bool
    /// Image Playground (Apple Intelligence), where the device has it.
    var imagine: Bool = false
    let pick: (PlusAction) -> Void

    private var items: [(PlusAction, Sym, LocalizedStringKey)] {
        var list: [(PlusAction, Sym, LocalizedStringKey)] = [
            (.photos, .photo, "Photo"),
            (.camera, .camera, "Camera"),
            (.location, .mappin, "Location"),
            (.drawing, .brush, "Drawing")
        ]
        if imagine { list.append((.imagine, .sparkles, "Image Playground")) }
        if stickers { list.append((.stickers, .face, "Stickers")) }
        list.append((.file, .doc, "File"))
        return list
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items, id: \.1) { item in
                Button {
                    Haptics.tap()
                    pick(item.0)
                } label: {
                    HStack(spacing: 12) {
                        SymbolView(item.1, size: 22).foregroundStyle(Theme.label)
                        Text(item.2).font(.bodyC).foregroundStyle(Theme.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FillPressStyle(radius: 18, fill: Theme.field))
                .opacity(open ? 1 : 0)
                .animation(open ? .easeOut(duration: 0.16).delay(0.07) : .easeOut(duration: 0.12), value: open)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 64)
        .frame(width: 212)
        .background(Theme.surface)
        .clipShape(GrowFromCorner(progress: open ? 1 : 0))
        .compositingGroup()
        .shadow(color: .black.opacity(0.14), radius: 14, y: 10)
        .shadow(color: .black.opacity(0.18), radius: 0.5)
        .allowsHitTesting(open)
        .accessibilityHidden(!open)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: open)
        // Gone once it has shrunk back into the button.
        .opacity(open ? 1 : 0)
        .animation(open ? .linear(duration: 0.01) : .linear(duration: 0.06).delay(0.24), value: open)
    }
}

/// A rect clipped from a 56pt circle in its bottom-trailing corner (0) to
/// the whole of it with 24pt corners (1).
struct GrowFromCorner: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let d: CGFloat = 56
        let w = d + (rect.width - d) * progress
        let h = d + (rect.height - d) * progress
        let r = 28 + (24 - 28) * progress
        let box = CGRect(x: rect.maxX - w, y: rect.maxY - h, width: w, height: h)
        return Path(roundedRect: box, cornerRadius: r, style: .continuous)
    }
}

struct LevelMeter: View {
    var levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(Theme.label).frame(width: 2.5, height: max(3, 26 * l))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// MARK: - Voice recorder

@MainActor
@Observable
final class VoiceRecorder {
    var isRecording = false
    var elapsed: Double = 0
    var levels: [CGFloat] = Array(repeating: 0.05, count: 30)
    var blink = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var url: URL?

    /// Still wanted when the permission answer comes back (the finger may
    /// have lifted, or the system's prompt cancelled the hold).
    @ObservationIgnored private var wanted = false
    /// Gets the recording when it reaches the two-minute limit and stops by
    /// itself (the finger still down). Kept only while recording.
    @ObservationIgnored var onLimit: ((Data, Double) -> Void)?

    func start() {
        wanted = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard granted, let self, self.wanted, !self.isRecording else { return }
                self.begin()
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return }
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        url = u
        elapsed = 0
        levels = Array(repeating: 0.05, count: 30)
        withAnimation(Motion.ui) { isRecording = true }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        let level = CGFloat(max(0.05, min(1, pow(10, db / 40))))
        levels.removeFirst()
        levels.append(level)
        elapsed = r.currentTime
        blink.toggle()
        if elapsed > 120 {
            let done = onLimit
            if let res = finish() { done?(res.0, res.1) }
        }
    }

    func finish() -> (Data, Double)? {
        wanted = false
        onLimit = nil
        guard let r = recorder, let url else { return nil }
        let d = r.currentTime
        r.stop()
        stopTimer()
        withAnimation(Motion.ui) { isRecording = false }
        recorder = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, d)
    }

    func cancel() {
        wanted = false
        onLimit = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        stopTimer()
        withAnimation(Motion.ui) { isRecording = false }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Picked videos

/// A video from the photo library, copied into a file of our own (never
/// read whole into memory).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// A picked video made ready to send (a message or a moment): made into a
/// 720p MP4, or medium quality when that's still too big, so it fits what
/// the hub takes; its upright size and length read from the result. The
/// temporary files are gone once it returns.
enum VideoPrep {
    /// The most the hub takes (src/media.js).
    static let maxBytes = 30 * 1024 * 1024

    struct Ready {
        var data: Data
        var size: CGSize
        var duration: Double
    }

    enum Failure: Error { case tooLong, failed }

    static func load(_ item: PhotosPickerItem) async throws -> Ready {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw Failure.failed }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let source = AVURLAsset(url: movie.url)
        var tooBig = false
        for preset in [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality] {
            guard let export = AVAssetExportSession(asset: source, presetName: preset) else { continue }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            export.shouldOptimizeForNetworkUse = true
            do {
                try await export.export(to: out, as: .mp4)
            } catch {
                continue
            }
            let bytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard bytes <= maxBytes else {
                tooBig = true
                continue
            }
            let asset = AVURLAsset(url: out)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var size = CGSize(width: 720, height: 1280)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(t)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: out) }.value
            return Ready(data: data, size: size, duration: duration)
        }
        throw tooBig ? Failure.tooLong : Failure.failed
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.done(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.done(nil)
            parent.dismiss()
        }
    }
}
