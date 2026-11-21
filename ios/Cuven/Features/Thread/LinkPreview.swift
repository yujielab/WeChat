import SwiftUI
import LinkPresentation

/// What a link shows of itself: its title, its site, a picture or icon.
struct LinkInfo {
    let title: String?
    let host: String
    let image: UIImage?
    let icon: UIImage?
}

/// Link previews (LinkPresentation), fetched once per link on the device and
/// kept for the session.
@MainActor
final class LinkPreviews {
    static let shared = LinkPreviews()
    private var cache: [URL: LinkInfo] = [:]
    private var missing: Set<URL> = []
    private var inflight: [URL: Task<LinkInfo?, Never>] = [:]

    func info(for url: URL) async -> LinkInfo? {
        if let hit = cache[url] { return hit }
        if missing.contains(url) { return nil }
        if let running = inflight[url] { return await running.value }
        let task = Task<LinkInfo?, Never> { @MainActor in
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let meta = try? await provider.startFetchingMetadata(for: url) else { return nil }
            let image = await Self.load(meta.imageProvider)
            let icon = image == nil ? await Self.load(meta.iconProvider) : nil
            let host = (meta.url ?? meta.originalURL ?? url).host() ?? url.absoluteString
            return LinkInfo(title: meta.title, host: host.replacingOccurrences(of: "www.", with: ""), image: image, icon: icon)
        }
        inflight[url] = task
        let info = await task.value
        inflight[url] = nil
        if let info { cache[url] = info } else { missing.insert(url) }
        return info
    }

    private static func load(_ provider: NSItemProvider?) async -> UIImage? {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { c in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                c.resume(returning: object as? UIImage)
            }
        }
    }

    /// The first web link in a message, if any.
    static func firstURL(in text: String) -> URL? {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" { return url }
        }
        return nil
    }
}

/// A link's preview under its message: the picture, the title, the site.
/// Nothing shows until there's something to show, so no empty box flashes.
struct LinkCard: View {
    let url: URL
    @State private var info: LinkInfo?

    var body: some View {
        Group {
            if let info {
                Button { UIApplication.shared.open(url) } label: { card(info) }
                    .buttonStyle(.press(0.97))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    .accessibilityLabel(Text("\(info.title ?? info.host), \(info.host)"))
            }
        }
        .task(id: url) {
            let found = await LinkPreviews.shared.info(for: url)
            withAnimation(Motion.ui) { info = found }
        }
    }

    private func card(_ i: LinkInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = i.image, image.size.width >= 120 {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 260, height: 136)
                    .clipped()
            }
            HStack(spacing: 10) {
                if let icon = i.icon {
                    Image(uiImage: icon).resizable().scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = i.title, !title.isEmpty {
                        Text(title).font(.subheadBoldC).foregroundStyle(Theme.label).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(i.host).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 260, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}
