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
        guard let api, let req = api.mediaRequest(path) else { return nil }
        do {
            let (data, response) = try await api.session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func image(_ path: String, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(path, maxPixel: maxPixel) { return hit }
        let k = key(path, maxPixel)
        lock.lock()
        if let running = inflight[k] {
            lock.unlock()
            return await running.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self, let data = await self.data(path) else { return nil }
            let img = Self.decode(data, maxPixel: maxPixel)
            if let img { self.cache.setObject(img, forKey: k as NSString, cost: img.cost) }
            return img
        }
        inflight[k] = task
        lock.unlock()
        let result = await task.value
        lock.lock()
        inflight[k] = nil
        lock.unlock()
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
        guard let asset = AuthorizedAsset.make(path) else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let img: UIImage? = await withCheckedContinuation { cont in
            gen.generateCGImageAsynchronously(for: CMTime(seconds: 0.1, preferredTimescale: 600)) { cg, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
        if let img { cache.setObject(img, forKey: k as NSString, cost: img.cost) }
        return img
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
