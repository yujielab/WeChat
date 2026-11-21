import SwiftUI
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

    @State private var text = ""
    @State private var plusOpen = false
    @State private var suggestion = ""
    @State private var recorder = VoiceRecorder()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var mentionIds: [String: String] = [:]
    @State private var savedDraft = ""
    @FocusState private var focused: Bool
    /// Holding the field to talk: the finger is down past the hold, and
    /// whether it has slid far enough to cancel on release.
    @State private var holding = false
    @State private var cancelArmed = false
    @State private var holdEnded = Date.distantPast
    /// Resets by itself when the system cancels the hold (onEnded never comes).
    @GestureState private var pressing = false

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Send (or ✓) only once there's something to send or an edit to save.
    private var showsSend: Bool { canSend || editing != nil }
    /// The empty field records while held.
    private var holdToTalk: Bool { text.isEmpty && editing == nil }
    private var showBack: Bool { nav.columns == 1 && !ctx.usesRail }

    /// The composer's controls are 56pt (the web's .field and .composer-action).
    static let control: CGFloat = 56
    private var margin: CGFloat { ctx.size.width < 400 ? 16 : 20 }
    private var editingOrReply: Bool { editing != nil || replyTo != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let chips = mentionCandidates, !chips.isEmpty {
                mentionPicker(chips)
            } else if !suggestion.isEmpty && !recorder.isRecording {
                suggestionChip
            }

            HStack(alignment: .bottom, spacing: 10) {
                if showBack {
                    GlassIconButton(sym: .chevronLeft, title: "Back", badge: otherUnread, badgeInk: true, size: Self.control) {
                        nav.backFromChat()
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                // The field stays put while recording (it holds the gesture);
                // the recording shows over it.
                field
                    .overlay {
                        if recorder.isRecording {
                            recordingBar
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                if showsSend {
                    trailingButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                PlusPanel(open: plusOpen, stickers: model.stickersEnabled) { action in
                    withAnimation(Motion.morph) { plusOpen = false }
                    switch action {
                    case .photos: showPhotos = true
                    case .camera: showCamera = true
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
            model.drafts[room.id] = v
            if editing == nil { model.sendTyping(v, room: room.id) }
            if !v.isEmpty && plusOpen { withAnimation(Motion.morph) { plusOpen = false } }
        }
        .onChange(of: editing?.id) { _, _ in
            if let e = editing {
                savedDraft = text
                text = e.body
                focused = true
            }
        }
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .task(id: text) { await fetchSuggestion() }
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
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFile(url) }
        }
    }

    private var otherUnread: Int {
        model.rooms.filter { $0.id != room.id && !$0.muted }.reduce(0) { $0 + $1.unread }
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
                if editing == nil {
                    Button {
                        Haptics.tap()
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
        .glass(shape, interactive: false)
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
                .background(Circle().fill(Theme.ink))
                .glassCircle(interactive: false)
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
        .padding(.leading, showBack ? Self.control + 10 : 0)
        .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.9)))
        .accessibilityLabel(Text("Use suggestion: \(suggestion)"))
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

    /// While the field is held: the time, the level, and what letting go
    /// will do (send, or, slid up or away, cancel).
    private var recordingBar: some View {
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
                    holding = true
                    cancelArmed = false
                    Haptics.press()
                    if plusOpen { withAnimation(Motion.morph) { plusOpen = false } }
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
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if isVideo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try? data.write(to: url)
                let asset = AVURLAsset(url: url)
                let dur = (try? await asset.load(.duration).seconds) ?? 0
                var size = CGSize(width: 720, height: 1280)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: natural).applying(t)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                }
                model.sendVideo(data, size: size, duration: dur, room: room.id)
            } else if let img = UIImage(data: data) {
                model.sendPicture(img, room: room.id, replyTo: reply)
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
        guard model.assistEnabled, model.predictions, editing == nil, !text.contains("\n") else {
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
        let s = await model.suggest(room: room.id, draft: text)
        if !Task.isCancelled { suggestion = s.trimmingCharacters(in: .newlines) }
    }
}

// MARK: - The "+" panel

enum PlusAction { case photos, camera, drawing, stickers, file }

/// The web's .composer-panel: 212pt wide, standing on the composer's
/// trailing end, its body clipped from the button's 56pt circle out to a
/// card with 24pt corners (280ms), the tools fading in after it.
struct PlusPanel: View {
    var open: Bool
    var stickers: Bool
    let pick: (PlusAction) -> Void

    private var items: [(PlusAction, Sym, LocalizedStringKey)] {
        var list: [(PlusAction, Sym, LocalizedStringKey)] = [
            (.photos, .photo, "Photo"),
            (.camera, .camera, "Camera"),
            (.drawing, .brush, "Drawing")
        ]
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
        if elapsed > 120 { _ = finish() }
    }

    func finish() -> (Data, Double)? {
        wanted = false
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
