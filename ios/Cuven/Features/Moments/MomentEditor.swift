import SwiftUI
import PhotosUI
import AVFoundation

/// Writing a moment: words, up to nine photos or one video, who it's with,
/// who can see and comment, and when it goes out.
struct MomentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    struct Pick: Identifiable {
        let id = UUID()
        var image: UIImage?
        var video: Data?
        var size: CGSize
        var alt = ""
    }

    @State private var text = ""
    @State private var picks: [Pick] = []
    @State private var items: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var audience = "everyone"
    @State private var commenting = "everyone"
    @State private var tags: [User] = []
    @State private var tagging = false
    @State private var scheduleOn = false
    @State private var at = Date().addingTimeInterval(3600)
    @State private var posting = false
    @State private var confirmDiscard = false
    @State private var altFor: UUID?
    @State private var altText = ""
    @FocusState private var focused: Bool

    private let limit = 2000
    private var canPost: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picks.isEmpty) && !posting }
    private var dirty: Bool { !text.isEmpty || !picks.isEmpty }

    var body: some View {
        PageScaffold(title: .inline(scheduleOn ? "Schedule" : "New moment"),
                     back: BarItem(id: "cancel", sym: .xmark, title: "Cancel") { if dirty { confirmDiscard = true } else { dismiss() } },
                     actions: [BarItem(id: "post", sym: .paperplane, title: scheduleOn ? "Schedule" : "Post",
                                       tint: canPost ? Theme.ink.opacity(0.9) : nil,
                                       foreground: canPost ? Theme.onInk : Theme.label3) { if canPost { post() } }],
                     background: Theme.paper) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Avatar(user: model.me, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.me?.name ?? "").font(.headlineC)
                            TextField("What's new?", text: $text, axis: .vertical)
                                .writingToolsBehavior(.complete)
                                .font(AppFont.make(20, .regular))
                                .lineLimit(3...)
                                .focused($focused)
                                .onChange(of: text) { _, v in if v.count > limit { text = String(v.prefix(limit)) } }
                        }
                    }
                    .padding(.horizontal, 18)

                    if !picks.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(picks) { p in pickCard(p) }
                            }
                            .padding(.horizontal, 18)
                        }
                        .frame(height: 260)
                    }

                    if !tags.isEmpty {
                        Text("With \(tags.map(\.name).joined(separator: ", "))")
                            .font(.footnoteC).foregroundStyle(Theme.label2).padding(.horizontal, 18)
                    }
                    if scheduleOn {
                        DatePicker("Goes out", selection: $at, in: Date().addingTimeInterval(120)...Date().addingTimeInterval(30 * 86400))
                            .font(.subheadC)
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 140)
                .animation(Motion.ui, value: picks.count)
                .animation(Motion.ui, value: scheduleOn)
            }
            // The tools, kept at the foot (over the keyboard when it's up).
            // Its band and line run the whole width, under the Duo's column
            // too; the tools themselves keep clear of the rail.
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Hairline()
                    bottomBar
                        .padding(.top, 10)
                        .padding(.leading, ctx.insets.leading)
                        .padding(.trailing, toolsTrailing)
                        .padding(.bottom, ctx.keyboard > 0 ? 0 : ctx.insets.bottom)
                }
                .background(.ultraThinMaterial)
                .background(Theme.paper.opacity(0.9))
                .padding(.bottom, ctx.keyboard > 0 ? ctx.keyboard : 0)
            }
            .overlay(alignment: .top) {
                if posting {
                    ProgressView().progressViewStyle(.linear).tint(Theme.blue)
                        .padding(.top, ctx.insets.top)
                }
            }
            .confirmationDialog("Discard this moment?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .photosPicker(isPresented: $showPicker, selection: $items, maxSelectionCount: max(1, 9 - picks.count), matching: .any(of: [.images, .videos]))
            .onChange(of: items) { _, list in
                guard !list.isEmpty else { return }
                items = []
                Task { await load(list) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    if let img { picks.append(Pick(image: img, size: img.size)) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $tagging) {
                PeoplePicker(title: "Tag people", exclude: Set(tags.map(\.id)), confirm: "Done") { ids in
                    tags += model.contacts.filter { ids.contains($0.id) }
                    tags = Array(tags.prefix(10))
                }
            }
            .alert("Describe this photo", isPresented: Binding(get: { altFor != nil }, set: { if !$0 { altFor = nil } })) {
                TextField("Alt text", text: $altText)
                Button("Save") {
                    if let id = altFor, let i = picks.firstIndex(where: { $0.id == id }) { picks[i].alt = String(altText.prefix(1000)) }
                    altFor = nil
                }
                Button("Cancel", role: .cancel) { altFor = nil }
            }
            .onAppear { focused = true }
    }

    private var toolsTrailing: CGFloat {
        guard ctx.usesRail, let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    private func dismiss() {
        focused = false
        withAnimation(Motion.move) { nav.composeMoment = false }
    }

    private func pickCard(_ p: Pick) -> some View {
        let a = max(0.6, min(1.8, p.size.width / max(1, p.size.height)))
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = p.image {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.fillQuiet
                        SymbolView(.video, size: 34).foregroundStyle(Theme.label2)
                    }
                }
            }
            .frame(width: 260 * a, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                withAnimation(Motion.ui) { picks.removeAll { $0.id == p.id } }
            } label: {
                SymbolView(.xmark, size: 14, weight: 2.4).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(.black.opacity(0.5), in: Circle())
            }
            .padding(8)
            .accessibilityLabel("Remove")

            if p.image != nil {
                Button {
                    altText = p.alt
                    altFor = p.id
                } label: {
                    Label(p.alt.isEmpty ? "ALT" : "ALT", systemImage: p.alt.isEmpty ? "plus" : "checkmark")
                        .font(.caption2C.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 26).background(.black.opacity(0.5), in: Capsule())
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: 260 * a, height: 260)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    Picker("Who can see it", selection: $audience) {
                        Label("Everyone", systemImage: "globe").tag("everyone")
                        Label("Friends", systemImage: "person.2").tag("friends")
                    }
                    Picker("Who can comment", selection: $commenting) {
                        Text("Everyone").tag("everyone")
                        Text("Friends").tag("friends")
                        Text("Off").tag("off")
                    }
                } label: {
                    HStack(spacing: 6) {
                        SymbolView(audience == "friends" ? .people : .globe, size: 16)
                        Text(audienceLine)
                        SymbolView(.chevronDown, size: 12)
                    }
                    .font(.footnoteC)
                    .foregroundStyle(Theme.label2)
                }
                Spacer()
            }
            HStack(spacing: 22) {
                tool(.photo, "Photos") { showPicker = true }
                    .disabled(picks.count >= 9 || picks.contains { $0.video != nil })
                tool(.camera, "Camera") { showCamera = true }
                tool(.personPlus, "Tag people") { tagging = true }
                tool(.clock, "Schedule", on: scheduleOn) { withAnimation(Motion.ui) { scheduleOn.toggle() } }
                Spacer()
                ZStack {
                    Circle().stroke(Theme.line, lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(text.count) / CGFloat(limit))
                        .stroke(limit - text.count < 100 ? Theme.orange : Theme.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if limit - text.count < 100 {
                        Text("\(limit - text.count)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(Theme.orange)
                    }
                }
                .frame(width: 26, height: 26)
                // Only once there's something written (the web's .me-ring.none).
                .opacity(text.isEmpty ? 0 : 1)
                .scaleEffect(text.isEmpty ? 0.7 : 1)
                .animation(.easeOut(duration: 0.2), value: text.isEmpty)
                .animation(.linear(duration: 0.1), value: text.count)
                .accessibilityHidden(text.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private var audienceLine: String {
        let see = audience == "friends" ? String(localized: "Friends can see") : String(localized: "Everyone can see")
        switch commenting {
        case "off": return see + String(localized: ", comments off")
        case "friends": return see + String(localized: ", friends comment")
        default: return see + String(localized: " and comment")
        }
    }

    private func tool(_ sym: Sym, _ title: LocalizedStringKey, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            SymbolView(sym, size: 24, weight: on ? 2.3 : nil)
                .foregroundStyle(on ? Theme.blue : Theme.label)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(Text(title))
    }

    private func load(_ list: [PhotosPickerItem]) async {
        for item in list {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if isVideo {
                guard picks.isEmpty else { continue }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try? data.write(to: url)
                var size = CGSize(width: 1080, height: 1920)
                if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                   let n = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: n).applying(t)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                }
                picks = [Pick(video: data, size: size)]
                return
            } else if let img = UIImage(data: data), picks.count < 9 {
                picks.append(Pick(image: img, size: img.size))
            }
        }
    }

    private func post() {
        posting = true
        focused = false
        let drafts = picks.map { AppModel.MomentDraftItem(image: $0.image, videoData: $0.video, size: $0.size, alt: $0.alt) }
        Task {
            let ok = await model.postMoment(text: text, items: drafts, audience: audience, comments: commenting,
                                            tags: tags.map(\.id), at: scheduleOn ? at : nil)
            posting = false
            if ok { dismiss() }
        }
    }
}
