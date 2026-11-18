import SwiftUI
import UIKit
import ImageIO

// MARK: - Authenticated & Offline-Resilient Media Asset View (M10)
//
// Supports:
// 1. Authenticated R2 `/api/media/...` & `https://` URLs (injecting `Origin` + shared `HTTPCookieStorage`,
//    decoded off-main-thread via `ImageIO` `CGImageSource` supporting JPEG, PNG, HEIC, and WebP).
// 2. Local `file://` URLs and `data:image/...;base64,...` inline data URIs (e.g., freshly exported
//    sketches from `DrawingBoardCanvasView` via `store.sendDrawing`).
// 3. Procedural Cuven editorial gallery artwork fallback when running offline (`--uitest-demo`),
//    ensuring Memories tiles, Flashback slides, and Lightbox views never display blank placeholders.

@MainActor
public final class CuvenDecodedImageCache {
    public static let shared = CuvenDecodedImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 160
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private init() {}

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    public func store(_ image: UIImage, forKey key: String) {
        let pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: max(1, pixelCost))
    }
}

public enum CuvenImageIODecoder {
    /// Decodes raw image bytes (WebP, PNG, JPEG, HEIC, GIF) into a `UIImage` via Apple `ImageIO`.
    public static func decodeUIImage(from data: Data, maxPixelDimension: Int = 2048) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return UIImage(data: data)
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }

    public static func loadOrFetchImage(
        rawURL: String,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        maxPixelDimension: Int = 2048
    ) async -> UIImage? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = await MainActor.run(body: { CuvenDecodedImageCache.shared.image(forKey: trimmed) }) {
            return cached
        }

        // 1. Inline `data:image/...;base64,...` URI
        if trimmed.hasPrefix("data:"),
           let commaIndex = trimmed.firstIndex(of: ",") {
            let payload = String(trimmed[trimmed.index(after: commaIndex)...])
            if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
               let decoded = decodeUIImage(from: data, maxPixelDimension: maxPixelDimension) {
                await MainActor.run { CuvenDecodedImageCache.shared.store(decoded, forKey: trimmed) }
                return decoded
            }
            return nil
        }

        // 2. Local file URL or path
        if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed) {
            if let data = try? Data(contentsOf: fileURL),
               let decoded = decodeUIImage(from: data, maxPixelDimension: maxPixelDimension) {
                await MainActor.run { CuvenDecodedImageCache.shared.store(decoded, forKey: trimmed) }
                return decoded
            }
            return nil
        }

        // 3. Demo/synthetic scheme -> immediately use procedural editorial artwork
        if trimmed.hasPrefix("demo://") || trimmed.hasPrefix("cuven-demo://") {
            return nil
        }

        // 4. Remote HTTP/HTTPS or server-relative `/api/...` URL
        let resolvedURL: URL? = {
            if let direct = URL(string: trimmed), let scheme = direct.scheme, (scheme == "http" || scheme == "https") {
                return direct
            }
            if trimmed.hasPrefix("/") {
                var base = serverBaseURL.absoluteString
                if base.hasSuffix("/") { base.removeLast() }
                return URL(string: base + trimmed)
            }
            return nil
        }()

        guard let targetURL = resolvedURL else { return nil }

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 8.0
        request.httpShouldHandleCookies = true
        if let scheme = targetURL.scheme, let host = targetURL.host {
            let portPart = targetURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(portPart)", forHTTPHeaderField: "Origin")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let decoded = decodeUIImage(from: data, maxPixelDimension: maxPixelDimension) else {
                return nil
            }
            await MainActor.run { CuvenDecodedImageCache.shared.store(decoded, forKey: trimmed) }
            return decoded
        } catch {
            return nil
        }
    }
}

/// Renders a media URL (photo, video poster, or drawing) with smooth fade-in and rich editorial fallback.
public struct CuvenMediaAssetView: View {
    public let urlString: String
    public let isDrawing: Bool
    public let contentMode: ContentMode
    public let serverBaseURL: URL

    @State private var loadedImage: UIImage?
    @State private var loadCompleted = false

    public init(
        urlString: String,
        isDrawing: Bool = false,
        contentMode: ContentMode = .fill,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!
    ) {
        self.urlString = urlString
        self.isDrawing = isDrawing
        self.contentMode = contentMode
        self.serverBaseURL = serverBaseURL
    }

    public var body: some View {
        ZStack {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .background(isDrawing ? Color.white : Color.clear)
            } else {
                ProceduralEditorialArtworkView(
                    seedKey: urlString,
                    isDrawing: isDrawing
                )
            }
        }
        .task(id: urlString) {
            if let cached = CuvenDecodedImageCache.shared.image(forKey: urlString) {
                loadedImage = cached
                loadCompleted = true
                return
            }
            let fetched = await CuvenImageIODecoder.loadOrFetchImage(
                rawURL: urlString,
                serverBaseURL: serverBaseURL
            )
            if let fetched {
                withAnimation(.easeOut(duration: 0.18)) {
                    loadedImage = fetched
                }
            }
            loadCompleted = true
        }
    }
}

/// Deterministic editorial canvas artwork for offline/demo Memories, Drawings, and Lightbox items.
private struct ProceduralEditorialArtworkView: View {
    let seedKey: String
    let isDrawing: Bool

    private var hashSeed: UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in seedKey.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return h
    }

    var body: some View {
        Canvas { context, size in
            let seed = hashSeed
            let rect = CGRect(origin: .zero, size: size)

            if isDrawing || seedKey.localizedCaseInsensitiveContains("draw") || seedKey.localizedCaseInsensitiveContains("sketch") {
                // Crisp white paper with expressive hand-sketched curves
                context.fill(Path(rect), with: .color(.white))
                let colors: [Color] = [
                    Color(.sRGB, red: 0.09, green: 0.09, blue: 0.11, opacity: 0.92),
                    Color(.sRGB, red: 0.00, green: 0.48, blue: 1.00, opacity: 0.85),
                    Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19, opacity: 0.78)
                ]
                for idx in 0..<3 {
                    var stroke = Path()
                    let yBase = size.height * CGFloat(0.28 + Double(idx) * 0.22)
                    let phase = CGFloat((seed >> (idx * 8)) & 0xFF) / 255.0 * .pi * 2
                    stroke.move(to: CGPoint(x: size.width * 0.14, y: yBase))
                    stroke.addCurve(
                        to: CGPoint(x: size.width * 0.86, y: yBase + sin(phase) * size.height * 0.12),
                        control1: CGPoint(x: size.width * 0.36, y: yBase - size.height * 0.18),
                        control2: CGPoint(x: size.width * 0.64, y: yBase + size.height * 0.20)
                    )
                    context.stroke(
                        stroke,
                        with: .color(colors[idx % colors.count]),
                        style: StrokeStyle(lineWidth: max(2.2, min(size.width, size.height) * 0.025), lineCap: .round)
                    )
                }
            } else {
                // Warm atmospheric gradient + geometric horizon / sun disc
                let palettes: [(Color, Color, Color)] = [
                    (Color(red: 0.12, green: 0.22, blue: 0.38), Color(red: 0.28, green: 0.49, blue: 0.66), Color(red: 0.95, green: 0.76, blue: 0.56)),
                    (Color(red: 0.21, green: 0.16, blue: 0.33), Color(red: 0.58, green: 0.34, blue: 0.49), Color(red: 0.96, green: 0.68, blue: 0.52)),
                    (Color(red: 0.10, green: 0.27, blue: 0.25), Color(red: 0.24, green: 0.54, blue: 0.47), Color(red: 0.84, green: 0.91, blue: 0.80)),
                    (Color(red: 0.24, green: 0.19, blue: 0.16), Color(red: 0.64, green: 0.46, blue: 0.34), Color(red: 0.95, green: 0.86, blue: 0.74)),
                    (Color(red: 0.09, green: 0.15, blue: 0.28), Color(red: 0.18, green: 0.38, blue: 0.68), Color(red: 0.56, green: 0.82, blue: 0.96))
                ]
                let palette = palettes[Int(seed % UInt64(palettes.count))]
                context.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [palette.0, palette.1, palette.2]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )

                let sunX = size.width * CGFloat(0.28 + Double((seed >> 8) & 0xFF) / 255.0 * 0.44)
                let sunY = size.height * CGFloat(0.24 + Double((seed >> 16) & 0xFF) / 255.0 * 0.24)
                let sunR = min(size.width, size.height) * 0.16
                context.fill(
                    Path(ellipseIn: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2)),
                    with: .color(Color.white.opacity(0.32))
                )

                var hill = Path()
                hill.move(to: CGPoint(x: 0, y: size.height * 0.72))
                hill.addQuadCurve(
                    to: CGPoint(x: size.width, y: size.height * 0.66),
                    control: CGPoint(x: size.width * 0.48, y: size.height * 0.52)
                )
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: size.height))
                hill.closeSubpath()
                context.fill(hill, with: .color(Color.black.opacity(0.18)))
            }
        }
    }
}
