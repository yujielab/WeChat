import Foundation
import UIKit
import ImageIO
import AVFoundation
import CryptoKit
import CuvenCore

// MARK: - Authenticated Media, ImageIO & HTTP Range Asset Loader (ios/Cuven/Core/AuthenticatedMediaLoader.swift)
//
// Provides:
// 1. Origin + `cfm_session` Cookie + `x-tz` authenticated requests against `/api/media/*` & `/api/stickers/*`
// 2. HTTP `Range: bytes=start-end` (`206 Partial Content`) byte-range media streaming & `AVURLAsset` header injection
// 3. Coalesced `NSCache` + disk cache + off-main-thread `ImageIO` WebP/HEIC/PNG/JPEG decoding
// 4. Deterministic crisp `UIImage` & 16kHz PCM WAV synthesis for `cuven-demo://` offline seed assets

public final class AuthenticatedMediaLoader: @unchecked Sendable {
    public static let shared = AuthenticatedMediaLoader()

    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let diskCacheDirectory: URL
    private let session: URLSession
    private let lock = NSLock()
    private var inFlightImages: [String: Task<UIImage?, Never>] = [:]
    private var inFlightData: [String: Task<Data?, Never>] = [:]

    public init(
        session: URLSession = .shared,
        diskCacheDirectory: URL? = nil
    ) {
        self.session = session
        let base = diskCacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskCacheDirectory = base.appendingPathComponent("CuvenAuthenticatedMedia", isDirectory: true)
    }

    // MARK: - Memory & Disk Cache Access

    public func cachedImage(for rawURLString: String) -> UIImage? {
        let key = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return imageCache.object(forKey: key as NSString)
    }

    public func storeImage(_ image: UIImage, for rawURLString: String, rawData: Data? = nil) {
        let key = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let cost = max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        imageCache.setObject(image, forKey: key as NSString, cost: cost)
        if let rawData {
            writeDiskCache(rawData, forKey: key)
        }
    }

    public func clearCache() {
        imageCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheDirectory)
    }

    // MARK: - Authenticated Image Loading (WebP / HEIC / PNG / JPEG / Demo)

    public func loadImage(
        from rawURLString: String,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        sessionToken: String? = KeychainSessionStore.shared.loadSessionToken(),
        maxPixelDimension: Int = 2048
    ) async -> UIImage? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let hit = imageCache.object(forKey: trimmed as NSString) {
            return hit
        }

        let coalesceKey = "\(trimmed)#\(maxPixelDimension)"
        let existingTask: Task<UIImage?, Never>? = lock.withLock {
            inFlightImages[coalesceKey]
        }
        if let existingTask {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                self.lock.withLock {
                    _ = self.inFlightImages.removeValue(forKey: coalesceKey)
                }
            }

            if trimmed.hasPrefix("cuven-demo://") || trimmed.hasPrefix("demo://") {
                let rendered = Self.renderDemoImage(for: trimmed)
                if let rendered {
                    self.storeImage(rendered, for: trimmed)
                }
                return rendered
            }

            guard let data = await self.loadData(
                from: trimmed,
                serverBaseURL: serverBaseURL,
                sessionToken: sessionToken
            ) else {
                return nil
            }

            guard let decoded = Self.decodeImage(from: data, maxPixelDimension: maxPixelDimension) else {
                return nil
            }
            self.storeImage(decoded, for: trimmed)
            return decoded
        }

        lock.withLock {
            inFlightImages[coalesceKey] = task
        }
        return await task.value
    }

    // MARK: - Authenticated Data & HTTP Range (`206 Partial Content`) Streaming

    public func loadData(
        from rawURLString: String,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        sessionToken: String? = KeychainSessionStore.shared.loadSessionToken(),
        byteRange: Range<Int>? = nil
    ) async -> Data? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Inline base64 data URI
        if trimmed.hasPrefix("data:"), let comma = trimmed.firstIndex(of: ",") {
            let b64 = String(trimmed[trimmed.index(after: comma)...])
            return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        }

        // 2. Local file URL
        if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed) {
            guard let full = try? Data(contentsOf: fileURL) else { return nil }
            if let byteRange {
                let lo = max(0, min(full.count, byteRange.lowerBound))
                let hi = max(lo, min(full.count, byteRange.upperBound))
                return full.subdata(in: lo..<hi)
            }
            return full
        }

        // 3. Offline demo assets (`cuven-demo://voice/...` or image PNG bytes)
        if trimmed.hasPrefix("cuven-demo://") || trimmed.hasPrefix("demo://") {
            if trimmed.contains("/voice/") || trimmed.hasSuffix(".wav") {
                return Self.synthesizeDemoVoiceWAV(durationSeconds: 3.0)
            }
            return Self.renderDemoImage(for: trimmed)?.pngData()
        }

        // 4. Disk cache check when fetching full object
        if byteRange == nil, let diskData = readDiskCache(forKey: trimmed) {
            return diskData
        }

        if byteRange == nil {
            let existing: Task<Data?, Never>? = lock.withLock { inFlightData[trimmed] }
            if let existing {
                return await existing.value
            }
        }

        let fetchTask = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if byteRange == nil {
                    self.lock.withLock {
                        _ = self.inFlightData.removeValue(forKey: trimmed)
                    }
                }
            }

            var headers: [String: String] = [:]
            if let byteRange {
                headers["Range"] = "bytes=\(byteRange.lowerBound)-\(max(byteRange.lowerBound, byteRange.upperBound - 1))"
            }

            guard let request = try? CuvenRequestBuilder.makeHTTPRequest(
                method: "GET",
                path: trimmed,
                baseURL: serverBaseURL,
                sessionToken: sessionToken,
                additionalHeaders: headers
            ) else {
                return nil
            }

            do {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      !data.isEmpty else {
                    return nil
                }
                if byteRange == nil && http.statusCode == 200 {
                    self.writeDiskCache(data, forKey: trimmed)
                }
                return data
            } catch {
                return nil
            }
        }

        if byteRange == nil {
            lock.withLock {
                inFlightData[trimmed] = fetchTask
            }
        }
        return await fetchTask.value
    }

    // MARK: - Authenticated AVURLAsset Builder (206 Partial Content Video & Voice Playback)

    public func makeAuthenticatedAVAsset(
        for rawURLString: String,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        sessionToken: String? = KeychainSessionStore.shared.loadSessionToken()
    ) -> AVURLAsset? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed) {
            return AVURLAsset(url: fileURL)
        }

        if trimmed.hasPrefix("cuven-demo://") || trimmed.hasPrefix("demo://") {
            let fileURL = materializeDemoAudioFileIfNeeded(seed: trimmed)
            return fileURL.map { AVURLAsset(url: $0) }
        }

        guard let resolvedURL = try? CuvenRequestBuilder.resolveURL(path: trimmed, baseURL: serverBaseURL) else {
            return nil
        }

        var headers: [String: String] = [
            "Origin": CuvenRequestBuilder.originHeaderValue(for: serverBaseURL),
            "x-tz": String(CuvenRequestBuilder.minutesWestOfUTC())
        ]
        if let token = sessionToken, !token.isEmpty {
            headers["Cookie"] = "\(CuvenRequestBuilder.sessionCookieName)=\(token)"
        }
        return AVURLAsset(
            url: resolvedURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
    }

    // MARK: - Local File Persistence for Exported Drawings / Cropped Avatars

    public func persistLocalMediaFile(_ data: Data, fileExtension: String = "png", preferredName: String? = nil) -> URL? {
        do {
            try FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
            let stem = preferredName ?? UUID().uuidString.lowercased()
            let fileURL = diskCacheDirectory.appendingPathComponent("\(stem).\(fileExtension)", isDirectory: false)
            try data.write(to: fileURL, options: [.atomic])
            if let image = Self.decodeImage(from: data, maxPixelDimension: 2048) {
                storeImage(image, for: fileURL.absoluteString)
            }
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - ImageIO Decoding & Demo Synthesis

    public static func decodeImage(from data: Data, maxPixelDimension: Int = 2048) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return UIImage(data: data)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }

    public static func renderDemoImage(for seedURL: String, size: CGSize = CGSize(width: 512, height: 512)) -> UIImage? {
        let digest = SHA256.hash(data: Data(seedURL.utf8))
        let bytes = Array(digest)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            if seedURL.contains("/drawing/") {
                UIColor.white.setFill()
                cg.fill(rect)
                let strokeColor = UIColor(red: 0.09, green: 0.35, blue: 0.78, alpha: 0.9)
                cg.setStrokeColor(strokeColor.cgColor)
                cg.setLineWidth(6)
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.65))
                cg.addCurve(
                    to: CGPoint(x: size.width * 0.85, y: size.height * 0.35),
                    control1: CGPoint(x: size.width * 0.35, y: size.height * 0.20),
                    control2: CGPoint(x: size.width * 0.65, y: size.height * 0.80)
                )
                cg.strokePath()
            } else {
                let hue1 = CGFloat(bytes[0]) / 255.0
                let hue2 = CGFloat(bytes[1]) / 255.0
                let c1 = UIColor(hue: hue1, saturation: 0.45, brightness: 0.88, alpha: 1.0)
                let c2 = UIColor(hue: hue2, saturation: 0.58, brightness: 0.62, alpha: 1.0)
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [c1.cgColor, c2.cgColor] as CFArray,
                    locations: [0.0, 1.0]
                ) {
                    cg.drawLinearGradient(
                        gradient,
                        start: .zero,
                        end: CGPoint(x: size.width, y: size.height),
                        options: []
                    )
                }
            }
        }
    }

    public static func synthesizeDemoVoiceWAV(durationSeconds: Double = 2.4, sampleRate: Int = 16_000) -> Data {
        let totalSamples = max(1, Int(durationSeconds * Double(sampleRate)))
        let byteRate = sampleRate * 2
        let dataSize = totalSamples * 2
        var wav = Data(capacity: 44 + dataSize)

        func appendUInt32LE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        wav.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        appendUInt32LE(16)
        appendUInt16LE(1) // PCM
        appendUInt16LE(1) // Mono
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(2)
        appendUInt16LE(16)
        wav.append(contentsOf: "data".utf8)
        appendUInt32LE(UInt32(dataSize))

        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let envelope = sin(min(1.0, t / 0.12) * .pi / 2.0) * sin(min(1.0, (durationSeconds - t) / 0.18) * .pi / 2.0)
            let wave = sin(2.0 * .pi * 392.0 * t) * 0.22 + sin(2.0 * .pi * 587.33 * t) * 0.10
            let sample = Int16(max(-32767.0, min(32767.0, wave * envelope * 14_000.0))).littleEndian
            withUnsafeBytes(of: sample) { wav.append(contentsOf: $0) }
        }
        return wav
    }

    // MARK: - Private Disk Helpers

    private func diskFileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent("\(hex).cache", isDirectory: false)
    }

    private func readDiskCache(forKey key: String) -> Data? {
        let url = diskFileURL(forKey: key)
        return try? Data(contentsOf: url)
    }

    private func writeDiskCache(_ data: Data, forKey key: String) {
        do {
            try FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
            try data.write(to: diskFileURL(forKey: key), options: [.atomic])
        } catch {
            // Best-effort disk cache
        }
    }

    private func materializeDemoAudioFileIfNeeded(seed: String) -> URL? {
        let digest = SHA256.hash(data: Data(seed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let wavData = Self.synthesizeDemoVoiceWAV()
        return persistLocalMediaFile(wavData, fileExtension: "wav", preferredName: "demo_voice_\(digest)")
    }
}
