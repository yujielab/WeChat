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
        VStack(alignment: .leading, spacing: 10) {
            header
            if !moment.media.isEmpty {
                media
            } else if !moment.text.isEmpty {
                Text(moment.text)
                    .font(AppFont.make(moment.text.count < 80 ? 24 : 18, .medium))
                    .foregroundStyle(Theme.label)
                    .padding(.horizontal, 16)
                    .lineLimit(expanded ? nil : 8)
            }
            actions
            if !moment.media.isEmpty && !moment.text.isEmpty { caption }
            if !moment.tags.isEmpty { tagsLine }
            comments
            footer
        }
        .padding(.vertical, 12)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Button { nav.profile = moment.user.id } label: {
                HStack(spacing: 10) {
                    Avatar(user: moment.user, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(moment.user.name).font(.headlineC).foregroundStyle(Theme.label)
                        Text(moment.user.friend == false && !moment.mine ? String(localized: "Suggested for you") : "@\(moment.user.username)")
                            .font(.captionC).foregroundStyle(Theme.label2)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if moment.user.friend == false && !moment.mine {
                Button {
                    Task {
                        if let id = await model.openDM(moment.user) {
                            nav.switchPage(.chats)
                            nav.open(room: id)
                        }
                    }
                } label: {
                    Text("Message").font(.subheadMediumC).foregroundStyle(Theme.label)
                        .padding(.horizontal, 14).frame(height: 32).background(Theme.fillQuiet, in: Capsule())
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
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.label)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: media

    private var aspect: CGFloat {
        let a = moment.media.first?.aspect ?? 1
        return min(1.91, max(0.8, a))
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
                Image(systemName: "heart.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 12)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if moment.media.count > 1 && showCounter {
                Text("\(page + 1)/\(moment.media.count)")
                    .font(.caption2C.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if moment.media.contains(where: { !($0.alt ?? "").isEmpty }) {
                Text("ALT").font(.caption2C.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(12)
            }
        }
        .onChange(of: page) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { showCounter = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeOut(duration: 0.4)) { showCounter = false }
            }
        }
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 16) {
            Button { toggleLike() } label: {
                HStack(spacing: 5) {
                    Image(systemName: moment.liked ? "heart.fill" : "heart")
                        .foregroundStyle(moment.liked ? Theme.red : Theme.label)
                        .symbolEffect(.bounce, value: moment.liked)
                    if !moment.likes.isEmpty { Text("\(moment.likes.count)").contentTransition(.numericText()) }
                }
            }
            Button { commentFocused = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                    if !moment.comments.isEmpty { Text("\(moment.comments.count)") }
                }
            }
            .disabled(!moment.canComment)
            ShareLink(item: moment.text.isEmpty ? String(localized: "A moment from \(moment.user.name)") : moment.text) {
                Image(systemName: "paperplane")
            }
            Spacer()
            if moment.media.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<moment.media.count, id: \.self) { i in
                        Circle().fill(i == page ? Theme.sky : Theme.label3.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                .animation(Motion.ui, value: page)
            }
        }
        .font(.system(size: 21, weight: .regular))
        .foregroundStyle(Theme.label)
        .buttonStyle(.press(0.88))
        .padding(.horizontal, 16)
    }

    private var caption: some View {
        (Text(moment.user.name).font(.headlineC) + Text("  ") + Text(moment.text).font(.bodyC))
            .foregroundStyle(Theme.label)
            .lineLimit(expanded ? nil : 2)
            .padding(.horizontal, 16)
            .onTapGesture { withAnimation(Motion.ui) { expanded.toggle() } }
    }

    private var tagsLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.fill").font(.system(size: 11))
            Text("With")
            ForEach(Array(moment.tags.prefix(3).enumerated()), id: \.offset) { i, u in
                Button(u.name + (i < min(moment.tags.count, 3) - 1 ? "," : "")) { nav.profile = u.id }
                    .buttonStyle(.plain).fontWeight(.semibold)
            }
            if moment.tags.count > 3 { Text("+\(moment.tags.count - 3)") }
        }
        .font(.footnoteC)
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var comments: some View {
        let list = showAll ? moment.comments : Array(moment.comments.suffix(2))
        VStack(alignment: .leading, spacing: 4) {
            if moment.comments.count > 2 && !showAll {
                Button("View all \(moment.comments.count) comments") { withAnimation(Motion.ui) { showAll = true } }
                    .font(.subheadC).foregroundStyle(Theme.label2).buttonStyle(.plain)
            }
            ForEach(list) { c in
                (Text(c.user.name).font(.subheadMediumC) + Text("  ") + Text(c.text).font(.subheadC))
                    .foregroundStyle(Theme.label)
                    .contextMenu {
                        if c.mine || moment.mine {
                            Button(role: .destructive) {
                                Task { if let m = await model.deleteComment(moment, c) { moment = m } }
                            } label: { Label("Delete comment", systemImage: "trash") }
                        }
                    }
            }
            if moment.canComment {
                HStack(spacing: 8) {
                    Avatar(user: model.me, size: 24)
                    TextField("Add a comment…", text: $comment)
                        .font(.subheadC)
                        .focused($commentFocused)
                        .submitLabel(.send)
                        .onSubmit { postComment() }
                    if !comment.isEmpty {
                        Button("Post") { postComment() }.font(.subheadMediumC).foregroundStyle(Theme.sky)
                    }
                }
                .padding(.top, 4)
            } else {
                Text(moment.commenting == "off" ? "Comments are off" : "Only \(moment.user.name)'s friends can comment")
                    .font(.footnoteC).foregroundStyle(Theme.label3)
            }
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if moment.scheduled {
                Image(systemName: "clock").foregroundStyle(Theme.blue)
                Text("Scheduled for \(Fmt.dayStamp(moment.date))").foregroundStyle(Theme.blue)
            } else {
                Text(Fmt.relative(moment.date))
            }
            if friendsOnly {
                Text("·")
                Image(systemName: "person.2.fill").font(.system(size: 10))
                Text("Friends")
            }
        }
        .font(.captionC)
        .foregroundStyle(Theme.label3)
        .padding(.horizontal, 16)
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
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(.black.opacity(0.45), in: Circle())
            }
            .padding(10)
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
