import SwiftUI
import LinkPresentation
import UniformTypeIdentifiers

/// What a link shows of itself: its title, its site, a picture or icon.
struct LinkInfo {
    let title: String?
    let host: String
    let image: UIImage?
    let icon: UIImage?
}

/// Link previews (LinkPresentation), fetched once per link on the device and
/// kept while there's room (pictures at the size the card shows them).
@MainActor
final class LinkPreviews {
    static let shared = LinkPreviews()

    private final class Box {
        let info: LinkInfo
        init(_ info: LinkInfo) { self.info = info }
    }

    private let cache: NSCache<NSURL, Box> = {
        let c = NSCache<NSURL, Box>()
        c.totalCostLimit = 24 << 20
        return c
    }()
    private var missing: Set<URL> = []
    private var inflight: [URL: Task<LinkInfo?, Never>] = [:]

    func info(for url: URL) async -> LinkInfo? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.info }
        if missing.contains(url) { return nil }
        if let running = inflight[url] { return await running.value }
        let task = Task<LinkInfo?, Never> { @MainActor in
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let meta = try? await provider.startFetchingMetadata(for: url) else { return nil }
            // The card's picture is 260pt wide, its icon 28pt (at 3x).
            let image = await Self.load(meta.imageProvider, maxPixel: 780)
            let icon = image == nil ? await Self.load(meta.iconProvider, maxPixel: 84) : nil
            let host = (meta.url ?? meta.originalURL ?? url).host() ?? url.absoluteString
            return LinkInfo(title: meta.title, host: host.replacingOccurrences(of: "www.", with: ""), image: image, icon: icon)
        }
        inflight[url] = task
        let info = await task.value
        inflight[url] = nil
        if let info {
            cache.setObject(Box(info), forKey: url as NSURL, cost: Self.cost(of: info))
        } else {
            if missing.count > 500 { missing.removeAll() }
            missing.insert(url)
        }
        return info
    }

    /// What the pictures take in memory, decoded.
    private static func cost(of info: LinkInfo) -> Int {
        [info.image, info.icon].compactMap { $0?.cgImage }.reduce(1) { $0 + $1.bytesPerRow * $1.height }
    }

    /// The picture's bytes, decoded off the main thread at the size it's shown.
    nonisolated private static func load(_ provider: NSItemProvider?, maxPixel: CGFloat) async -> UIImage? {
        guard let provider else { return nil }
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            let decoded: UIImage? = await withCheckedContinuation { c in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    c.resume(returning: data.flatMap { ImageStore.decode($0, maxPixel: maxPixel) })
                }
            }
            if let decoded { return decoded }
        }
        // No image bytes on offer, or none ImageIO reads: the picture as it
        // comes (the cache's cost still bounds it).
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                c.resume(returning: object as? UIImage)
            }
        }
    }

    /// The first web link in a message, if any.
    static func firstURL(in text: String) -> URL? {
        guard text.contains("http"), let detector = LinkDetect.detector else { return nil }
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
