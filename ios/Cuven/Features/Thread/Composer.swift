import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// The message field and everything that comes out of it: the "+" that
/// turns into Send when there's something to send, the attachments panel
/// growing from that button, voice recording, replies and edits, @mentions
/// in groups and the writing help's suggestion.
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

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showBack: Bool { nav.columns == 1 && !ctx.usesRail }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if plusOpen {
                PlusPanel(stickers: model.stickersEnabled) { action in
                    withAnimation(Motion.morph) { plusOpen = false }
                    switch action {
                    case .photos: showPhotos = true
                    case .camera: showCamera = true
                    case .drawing: nav.show(.draw)
                    case .stickers: stickersOpen = true
                    case .file: showFiles = true
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity),
                    removal: .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity)))
            }

            if let chips = mentionCandidates, !chips.isEmpty {
                mentionBar(chips)
            } else if !suggestion.isEmpty && !recorder.isRecording {
                suggestionChip
            }

            if let banner = bannerMessage {
                banner
            }

            HStack(alignment: .bottom, spacing: Bar.gap) {
                if showBack {
                    GlassIconButton(symbol: "chevron.left", title: "Back", badge: otherUnread) { nav.backFromChat() }
                        .transition(.scale.combined(with: .opacity))
                }
                if recorder.isRecording {
                    recordingBar
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    field
                }
                trailingButton
            }
        }
        .padding(.leading, max(ctx.insets.leading, 14))
        .padding(.trailing, ctx.usesRail ? ctx.insets.trailing + 8 : max(ctx.insets.trailing, 14))
        .background(alignment: .bottom) {
            GlowField(palette: model.composerGlow, intensity: focused ? 1.5 : 0.9)
                .frame(height: 240)
                .offset(y: 90)
                .allowsHitTesting(false)
        }
        .animation(Motion.morph, value: plusOpen)
        .animation(Motion.ui, value: canSend)
        .animation(Motion.ui, value: replyTo?.id)
        .animation(Motion.ui, value: editing?.id)
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

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(editing != nil ? "Edit message" : "Message", text: $text, axis: .vertical)
                .font(.bodyC)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.vertical, 15)
                .padding(.leading, 18)
                .onSubmit { send() }
            if text.isEmpty && editing == nil {
                Button {
                    Haptics.press()
                    recorder.start()
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.label2)
                        .frame(width: 44, height: Bar.height)
                }
                .buttonStyle(.press(0.9))
                .accessibilityLabel("Record voice message")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.trailing, text.isEmpty && editing == nil ? 2 : 14)
        .frame(minHeight: Bar.height)
        .glass(RoundedRectangle(cornerRadius: Bar.height / 2, style: .continuous), interactive: false)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var trailingButton: some View {
        Button {
            if canSend || editing != nil {
                send()
            } else if recorder.isRecording {
                finishRecording()
            } else {
                Haptics.tap()
                withAnimation(Motion.morph) { plusOpen.toggle() }
            }
        } label: {
            let sending = canSend || recorder.isRecording
            ZStack {
                Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(sending || editing != nil ? 1 : 0)
                    .scaleEffect(sending || editing != nil ? 1 : 0.4)
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .rotationEffect(.degrees(plusOpen ? 45 : 0))
                    .opacity(sending || editing != nil ? 0 : 1)
                    .scaleEffect(sending || editing != nil ? 0.4 : 1)
            }
            .frame(width: Bar.height, height: Bar.height)
            .background {
                Circle().fill(Theme.blue)
                    .opacity(sending || editing != nil ? 1 : 0)
                    .scaleEffect(sending || editing != nil ? 1 : 0.5)
            }
            .glassCircle(interactive: !(sending || editing != nil))
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(canSend ? "Send" : (plusOpen ? "Close" : "More"))
    }

    // MARK: banners & chips

    private var bannerMessage: AnyView? {
        if let e = editing {
            return AnyView(banner(icon: "pencil", title: "Editing message", text: e.body) {
                editing = nil
                text = savedDraft
            })
        }
        if let r = replyTo {
            return AnyView(banner(icon: "arrowshape.turn.up.left.fill", title: "Replying to \(model.name(of: r.sender))", text: r.preview) {
                replyTo = nil
            })
        }
        return nil
    }

    private func banner(icon: String, title: LocalizedStringKey, text: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2C.weight(.bold)).foregroundStyle(Theme.blue)
                Text(text).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.label2)
                    .frame(width: 26, height: 26).background(Theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
        .padding(.leading, showBack ? Bar.height + Bar.gap : 0)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var suggestionChip: some View {
        Button {
            let joiner = text.isEmpty || text.hasSuffix(" ") || suggestion.hasPrefix(" ") ? "" : (isCJK(suggestion) ? "" : " ")
            text += joiner + suggestion
            suggestion = ""
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .bold))
                Text(suggestion).lineLimit(1)
                Image(systemName: "arrow.turn.down.left").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .font(.footnoteC)
            .foregroundStyle(Theme.label2)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassCapsule()
        }
        .buttonStyle(.press)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, showBack ? Bar.height + Bar.gap : 0)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    private func mentionBar(_ list: [Member]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list) { m in
                    Button {
                        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                        parts.removeLast()
                        parts.append("@\(m.display) ")
                        text = parts.joined(separator: " ")
                        mentionIds[m.display] = m.id
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            Avatar(user: m.user, size: 24)
                            Text(m.display).font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label)
                        }
                        .padding(.leading, 4).padding(.trailing, 12).frame(height: 34)
                        .glassCapsule()
                    }
                    .buttonStyle(.press)
                }
            }
            .padding(.vertical, 2)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: voice

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
                Haptics.warning()
            } label: {
                Image(systemName: "trash").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.red)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.press(0.9))
            .accessibilityLabel("Discard recording")
            Circle().fill(Theme.red).frame(width: 9, height: 9)
                .opacity(recorder.blink ? 1 : 0.25)
            Text(Fmt.duration(recorder.elapsed)).font(.subheadMediumC.monospacedDigit()).foregroundStyle(Theme.label)
            LevelMeter(levels: recorder.levels).frame(height: 26)
        }
        .padding(.horizontal, 8)
        .frame(height: Bar.height)
        .frame(maxWidth: .infinity)
        .glass(Capsule(), interactive: false)
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

struct PlusPanel: View {
    var stickers: Bool
    let pick: (PlusAction) -> Void

    private var items: [(PlusAction, String, LocalizedStringKey, Color)] {
        var list: [(PlusAction, String, LocalizedStringKey, Color)] = [
            (.photos, "photo.on.rectangle", "Photos", Theme.blue),
            (.camera, "camera.fill", "Camera", Color(hex: 0x5e5ce6)),
            (.drawing, "scribble.variable", "Drawing", Color(hex: 0xff9f0a))
        ]
        if stickers { list.append((.stickers, "face.smiling.inverse", "Stickers", Color(hex: 0xff375f))) }
        list.append((.file, "doc.fill", "File", Color(hex: 0x30b0c7)))
        return list
    }

    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(78), spacing: 6), count: min(3, items.count))
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    Haptics.tap()
                    pick(item.0)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.1)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(item.3.gradient, in: Circle())
                        Text(item.2).font(.caption2C).foregroundStyle(Theme.label)
                    }
                }
                .buttonStyle(.press(0.9))
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)
    }
}

struct LevelMeter: View {
    var levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(Theme.blue).frame(width: 3, height: max(3, 26 * l))
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

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard granted, let self else { return }
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
