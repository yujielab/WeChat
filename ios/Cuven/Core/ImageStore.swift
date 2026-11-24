import SwiftUI
import UIKit
import ImageIO
import AVFoundation

/// Loads media from the hub (cookie-authenticated), decodes it at the size
/// it's shown and keeps it in memory; URLCache keeps the bytes on disk (the
/// server marks media immutable).
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    var api: APIClient?
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// One download per address, however many sizes want it at the same time.
    private var dataInflight: [String: Task<Data?, Never>] = [:]
    /// Addresses the hub just said no to (gone, no access): not asked again for a minute.
    private var refused: [String: Date] = [:]

    init() {
        cache.totalCostLimit = 160 << 20
    }

    private func key(_ path: String, _ px: CGFloat) -> String { "\(path)#\(Int(px))" }

    func cached(_ path: String, maxPixel: CGFloat) -> UIImage? {
        if let local = cache.object(forKey: path as NSString) { return local }
        return cache.object(forKey: key(path, maxPixel) as NSString)
    }

    /// An image made on this device (a photo on its way), shown under its local key.
    func put(_ image: UIImage, for path: String) {
        cache.setObject(image, forKey: path as NSString, cost: image.cost)
    }

    func data(_ path: String) async -> Data? {
        await fetch(path).data
    }

    /// The bytes, or nil; `refused` when the hub answered and said no.
    private func fetch(_ path: String) async -> (data: Data?, refused: Bool) {
        guard let api, let req = api.mediaRequest(path) else { return (nil, false) }
        do {
            let (data, response) = try await api.session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (nil, false) }
            guard (200..<300).contains(http.statusCode) else {
                return (nil, http.statusCode == 403 || http.statusCode == 404 || http.statusCode == 410)
            }
            return (data, false)
        } catch {
            return (nil, false)
        }
    }

    /// The bytes for image(), shared by every size asked for at once.
    private func sharedData(_ path: String) async -> Data? {
        let task = lock.withLock { () -> Task<Data?, Never>? in
            if let at = refused[path] {
                if Date().timeIntervalSince(at) < 60 { return nil }
                refused[path] = nil
            }
            if let running = dataInflight[path] { return running }
            let t = Task<Data?, Never> { [weak self] in
                guard let self else { return nil }
                let got = await self.fetch(path)
                if got.refused { self.lock.withLock { self.refused[path] = Date() } }
                return got.data
            }
            dataInflight[path] = t
            return t
        }
        guard let task else { return nil }
        let data = await task.value
        lock.withLock { dataInflight[path] = nil }
        return data
    }

    func image(_ path: String, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(path, maxPixel: maxPixel) { return hit }
        let k = key(path, maxPixel)
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inflight[k] { return running }
            let t = Task<UIImage?, Never> { [weak self] in
                guard let self, let data = await self.sharedData(path) else { return nil }
                let img = Self.decode(data, maxPixel: maxPixel)
                if let img { self.cache.setObject(img, forKey: k as NSString, cost: img.cost) }
                return img
            }
            inflight[k] = t
            return t
        }
        let result = await task.value
        lock.withLock { inflight[k] = nil }
        return result
    }

    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    /// A still from a video, for its bubble or tile.
    func videoThumbnail(_ path: String, maxPixel: CGFloat) async -> UIImage? {
        let k = key(path, maxPixel) + "#v"
        if let hit = cache.object(forKey: k as NSString) { return hit }
        // One generator per still, however many views want it at once.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inflight[k] { return running }
            let t = Task<UIImage?, Never> { [weak self] in
                guard let self, let asset = AuthorizedAsset.make(path) else { return nil }
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                let img: UIImage? = await withCheckedContinuation { cont in
                    gen.generateCGImageAsynchronously(for: CMTime(seconds: 0.1, preferredTimescale: 600)) { cg, _, _ in
                        cont.resume(returning: cg.map { UIImage(cgImage: $0) })
                    }
                }
                if let img { self.cache.setObject(img, forKey: k as NSString, cost: img.cost) }
                return img
            }
            inflight[k] = t
            return t
        }
        let result = await task.value
        lock.withLock { inflight[k] = nil }
        return result
    }
}

enum AuthorizedAsset {
    /// An AVURLAsset that sends the session cookie with each range request.
    static func make(_ path: String) -> AVURLAsset? {
        guard let api = ImageStore.shared.api, let req = api.mediaRequest(path), let url = req.url else { return nil }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": api.authHeaders])
    }
}

private extension UIImage {
    var cost: Int {
        guard let cg = cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

/// A picture from the hub: shows at once when it's in memory, fades in when it arrives.
struct RemoteImage: View {
    let path: String
    var maxPixel: CGFloat = 1000
    var contentMode: ContentMode = .fill
    var placeholder: Color = Theme.fillQuiet

    @State private var image: UIImage?

    init(_ path: String, maxPixel: CGFloat = 1000, contentMode: ContentMode = .fill, placeholder: Color = Theme.fillQuiet) {
        self.path = path
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: ImageStore.shared.cached(path, maxPixel: maxPixel))
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
        .clipped()
        .task(id: path) {
            if let hit = ImageStore.shared.cached(path, maxPixel: maxPixel) {
                image = hit
                return
            }
            let loaded = await ImageStore.shared.image(path, maxPixel: maxPixel)
            if let loaded { withAnimation(.easeOut(duration: 0.22)) { image = loaded } }
        }
    }
}

struct VideoThumb: View {
    let path: String
    var maxPixel: CGFloat = 800
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.fillQuiet
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: path) {
            if image == nil {
                let img = await ImageStore.shared.videoThumbnail(path, maxPixel: maxPixel)
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
        }
    }
}
