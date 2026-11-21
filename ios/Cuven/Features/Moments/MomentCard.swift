import SwiftUI
import AVKit

/// One moment, Instagram-style: who, the photos (swipe through, double-tap
/// to like), heart / comment / share, the words, the last two comments and
/// a field to add one.
struct MomentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Binding var moment: Moment
    var onDelete: () -> Void = {}

    @State private var page = 0
    @State private var heart = false
    @State private var expanded = false
    @State private var showAll = false
    @State private var comment = ""
    @State private var showCounter = false
    @FocusState private var commentFocused: Bool

    private var friendsOnly: Bool { moment.audience == "friends" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !moment.media.isEmpty {
                media
                actions(over: true)
                    .padding(.top, -54)
                    .zIndex(3)
                Color.clear.frame(height: 10)
                if !moment.text.isEmpty { caption }
            } else {
                if !moment.text.isEmpty {
                    Text(moment.text)
                        .font(AppFont.make(20, .regular))
                        .lineSpacing(20 * 0.35 - 4)
                        .foregroundStyle(Theme.label)
                        .lineLimit(expanded ? nil : 8)
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .onTapGesture { withAnimation(Motion.ui) { expanded.toggle() } }
                }
                actions(over: false)
            }
            if !moment.tags.isEmpty { tagsLine }
            comments
            footer
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Button { nav.profile = moment.user.id } label: {
                HStack(spacing: 10) {
                    Avatar(user: moment.user, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(moment.user.name).font(AppFont.make(15, .bold)).foregroundStyle(Theme.label).lineLimit(1)
                        Text(moment.user.friend == false && !moment.mine ? String(localized: "Suggested for you") : "@\(moment.user.username)")
                            .font(.captionC).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            if moment.user.friend == false && !moment.mine {
                Button {
                    Task {
                        if let id = await model.openDM(moment.user) {
                            nav.switchPage(.chats)
                            nav.open(room: id)
                        }
                    }
                } label: {
                    Text("Message").font(AppFont.make(13, .semibold)).foregroundStyle(Theme.label)
                        .padding(.horizontal, 16).frame(height: 34)
                        .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.press)
            }
            Menu {
                Button { nav.profile = moment.user.id } label: { Label("View profile", systemImage: "person.crop.circle") }
                if moment.mine {
                    Button(role: .destructive) {
                        Task { if await model.deleteMoment(moment) { onDelete() } }
                    } label: { Label("Delete", systemImage: "trash") }
                } else {
                    Button {
                        Task {
                            if let id = await model.openDM(moment.user) {
                                nav.switchPage(.chats)
                                nav.open(room: id)
                            }
                        }
                    } label: { Label("Message", systemImage: "bubble.left") }
                }
            } label: {
                SymbolView(.ellipsis, size: 20).foregroundStyle(Theme.label)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .accessibilityLabel("More")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: 56)
    }

    // MARK: media

    private var aspect: CGFloat {
        let a = moment.media.first?.aspect ?? 1
        return min(1.91, max(0.75, a))
    }

    private var media: some View {
        GeometryReader { geo in
            TabView(selection: $page) {
                ForEach(Array(moment.media.enumerated()), id: \.offset) { i, m in
                    FrameReporting { frame in
                        ZStack {
                            if m.isVideo {
                                InlineVideo(path: m.url)
                            } else {
                                RemoteImage(m.url, maxPixel: 1400)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { likeBurst() }
                        .onTapGesture {
                            guard !m.isVideo else { return }
                            withAnimation(Motion.morph) {
                                nav.viewer = ViewerItem(path: m.url, aspect: m.aspect, source: frame(), caption: m.alt ?? "")
                            }
                        }
                        .accessibilityLabel(Text(m.alt?.isEmpty == false ? m.alt! : String(localized: "Photo")))
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay {
            if heart {
                SymbolView(.heart, size: 96, filled: true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if moment.media.count > 1 && showCounter {
                Text("\(page + 1)/\(moment.media.count)")
                    .font(AppFont.make(12, .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if moment.media.contains(where: { !($0.alt ?? "").isEmpty }) {
                Text("ALT").font(AppFont.make(12, .bold)).tracking(0.5).foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(12)
            }
        }
        .background(Theme.fill2)
        .onChange(of: page) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { showCounter = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeOut(duration: 0.4)) { showCounter = false }
            }
        }
    }

    // MARK: actions

    /// Like, comment and share: frosted glass, no edge; with a picture the
    /// row rests on its lower edge, the page dots centred above it.
    private func actions(over: Bool) -> some View {
        HStack(spacing: 4) {
            Button { toggleLike() } label: {
                act(sym: .heart, count: moment.likes.count, on: moment.liked)
            }
            .accessibilityLabel(moment.liked ? "Unlike" : "Like")
            Button { commentFocused = true } label: {
                act(sym: .bubble, count: moment.comments.count)
            }
            .disabled(!moment.canComment)
            .accessibilityLabel("Comment")
            ShareLink(item: moment.text.isEmpty ? String(localized: "A moment from \(moment.user.name)") : moment.text) {
                act(sym: .paperplane, count: 0)
            }
            .accessibilityLabel("Share")
            Spacer(minLength: 0)
        }
        // The page dots, centred under the pictures (HIG, Page controls).
        .overlay(alignment: over ? .bottom : .center) {
            if moment.media.count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<moment.media.count, id: \.self) { i in
                        Circle()
                            .fill(over ? (i == page ? Color.white : Color.white.opacity(0.55)) : (i == page ? Theme.blue : Theme.label3))
                            .frame(width: 6, height: 6)
                            .scaleEffect(i == page ? 1.15 : 1)
                            .shadow(color: .black.opacity(over ? 0.35 : 0), radius: 1.5)
                    }
                }
                // Over a picture: centred on it, just above the buttons, clear of them.
                .padding(.bottom, over ? 52 : 0)
                .animation(.easeOut(duration: 0.2), value: page)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(Text("\(page + 1)/\(moment.media.count)"))
            }
        }
        .buttonStyle(.press(0.9))
        .padding(.horizontal, over ? 10 : 8)
        .padding(.top, over ? 0 : 2)
        .padding(.bottom, over ? 10 : 0)
        .frame(height: over ? 54 : nil, alignment: .bottom)
        .frame(minHeight: over ? 0 : 48)
    }

    private func act(sym: Sym, count: Int, on: Bool = false) -> some View {
        HStack(spacing: 6) {
            SymbolView(sym, size: 25, filled: on)
                .foregroundStyle(on ? Theme.red : Theme.label)
                .keyframeAnimator(initialValue: 1.0, trigger: on) { v, s in v.scaleEffect(s) } keyframes: { _ in
                    CubicKeyframe(1.3, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
            if count > 0 {
                Text("\(count)")
                    .font(AppFont.make(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.label)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 44, minHeight: 44)
        .glassCapsule()
        .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
    }

    /// The words under a picture: two lines, with "more" for the rest.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(moment.user.name).font(AppFont.make(15, .bold)) + Text(" ") + Text(moment.text).font(.subheadC))
                .foregroundStyle(Theme.label)
                .lineSpacing(15 * 0.4 - 4)
                .lineLimit(expanded ? nil : 2)
            if !expanded && moment.text.count > 90 {
                Button("more") { withAnimation(Motion.ui) { expanded = true } }
                    .font(.subheadC).foregroundStyle(Theme.label2).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var tagsLine: some View {
        HStack(spacing: 3) {
            SymbolView(.people, size: 16).padding(.trailing, 4)
            Text("With")
            ForEach(Array(moment.tags.prefix(3).enumerated()), id: \.offset) { i, u in
                Button(u.name + (i < min(moment.tags.count, 3) - 1 ? "," : "")) { nav.profile = u.id }
                    .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.label)
                    .padding(.vertical, 4)
            }
            if moment.tags.count > 3 { Text("+\(moment.tags.count - 3)") }
        }
        .font(.subheadC)
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var comments: some View {
        let list = showAll ? moment.comments : Array(moment.comments.suffix(2))
        VStack(alignment: .leading, spacing: 2) {
            if moment.comments.count > 2 && !showAll {
                Button("View all \(moment.comments.count) comments") { withAnimation(Motion.ui) { showAll = true } }
                    .font(.subheadC).foregroundStyle(Theme.label2).buttonStyle(.plain)
                    .padding(.top, 4)
            }
            ForEach(list) { c in
                (Text(c.user.name).font(AppFont.make(15, .semibold)) + Text(" ") + Text(c.text).font(.subheadC))
                    .foregroundStyle(Theme.label)
                    .lineSpacing(2)
                    .contextMenu {
                        if c.mine || moment.mine {
                            Button(role: .destructive) {
                                Task { if let m = await model.deleteComment(moment, c) { moment = m } }
                            } label: { Label("Delete comment", systemImage: "trash") }
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, list.isEmpty ? 0 : 4)
        if moment.canComment {
            HStack(spacing: 10) {
                Avatar(user: model.me, size: 26)
                TextField("Add a comment…", text: $comment)
                    .font(.subheadC)
                    .focused($commentFocused)
                    .submitLabel(.send)
                    .onSubmit { postComment() }
                    .frame(height: 38)
                if !comment.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { postComment() } label: {
                        SymbolView(.arrowUp, size: 16, weight: 2.5).foregroundStyle(Theme.onInk)
                            .frame(width: 34, height: 34).background(Theme.ink, in: Circle())
                    }
                    .buttonStyle(.press(0.9))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Post")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 6)
            .animation(Motion.ui, value: comment.isEmpty)
        } else {
            HStack(spacing: 8) {
                SymbolView(.lock, size: 16)
                Text(moment.commenting == "off" ? "Comments are off" : "Only \(moment.user.name)'s friends can comment")
            }
            .font(.subheadC)
            .foregroundStyle(Theme.label2)
            .frame(minHeight: 34)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if moment.scheduled {
                HStack(spacing: 5) {
                    SymbolView(.clock, size: 14)
                    Text("Scheduled for \(Fmt.dayStamp(moment.date))")
                }
                .font(AppFont.make(12, .semibold))
                .foregroundStyle(Theme.blueText)
            } else {
                Text(Fmt.relative(moment.date))
            }
            if friendsOnly {
                Text("·")
                SymbolView(.people, size: 13)
                Text("Friends")
            }
        }
        .font(.captionC)
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: behaviour

    private func likeBurst() {
        Haptics.press()
        withAnimation(Motion.bouncy) { heart = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { heart = false }
        }
        if !moment.liked { toggleLike() }
    }

    private func toggleLike() {
        let on = !moment.liked
        withAnimation(Motion.bouncy) {
            moment.liked = on
            if on, let me = model.me { moment.likes.append(me) } else { moment.likes.removeAll { $0.id == model.me?.id } }
        }
        Task { if let fresh = await model.like(moment, on: on) { moment = fresh } }
    }

    private func postComment() {
        let t = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        comment = ""
        commentFocused = false
        Task { if let fresh = await model.comment(moment, text: t) { withAnimation(Motion.ui) { moment = fresh } } }
    }
}

/// A moment's video: muted and looping while it's on screen; the speaker toggles sound.
struct InlineVideo: View {
    let path: String
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var muted = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VideoThumb(path: path)
            if let player {
                VideoPlayer(player: player).disabled(true)
            }
            Button {
                muted.toggle()
                player?.isMuted = muted
            } label: {
                SymbolView(muted ? .speakerOff : .speaker, size: 17).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(.black.opacity(0.55), in: Circle())
            }
            .padding(10)
            .padding(.bottom, 54)
        }
        .onAppear {
            guard player == nil, let asset = AuthorizedAsset.make(path) else { return }
            let item = AVPlayerItem(asset: asset)
            let q = AVQueuePlayer()
            looper = AVPlayerLooper(player: q, templateItem: item)
            q.isMuted = true
            player = q
            if !reduceMotion { q.play() }
        }
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
        }
    }
}
