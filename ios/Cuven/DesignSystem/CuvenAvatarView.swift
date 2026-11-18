//
//  CuvenAvatarView.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Images & Color (crisp Retina borders, deterministic accessible monograms)
//  - Cuven Web Parity: `public/css/base.css:215-250,339-342`, `public/css/chat.css:51-52`,
//    `public/js/ui/format.js:72-89`, `src/index.js:18-20` (`Origin` + `cfm_session` authenticated media)
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Canonical CuvenAvatarView (`PROJECT.md § 5.3`)

/// Circular (or `30%` group squircle) avatar with deterministic HSL-tinted initials fallback,
/// memory-cached & cookie/Origin-authenticated async image loading, `0.5pt` inner outline,
/// and live green online presence indicator.
public struct CuvenAvatarView: View {
    public let name: String
    public let urlString: String?
    public let size: CGFloat
    public let isOnline: Bool
    public let isGroupSquircle: Bool
    public let showElevationRing: Bool

    @State private var loadedImage: UIImage?
    @State private var didAnimateArrival = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Canonical `PROJECT.md § 5.3` initializer.
    public init(
        name: String,
        urlString: String?,
        size: CGFloat,
        isOnline: Bool = false
    ) {
        self.name = name
        self.urlString = urlString
        self.size = size
        self.isOnline = isOnline
        self.isGroupSquircle = false
        self.showElevationRing = false
    }

    /// Extended initializer supporting `30%`-radius group squircles (`base.css:231`) and
    /// `3pt` conversation-header / profile-cover elevation rings (`chat.css:51`, `backdrops.css:133`).
    public init(
        name: String,
        urlString: String?,
        size: CGFloat,
        isOnline: Bool = false,
        isGroupSquircle: Bool,
        showElevationRing: Bool = false
    ) {
        self.name = name
        self.urlString = urlString
        self.size = size
        self.isOnline = isOnline
        self.isGroupSquircle = isGroupSquircle
        self.showElevationRing = showElevationRing
    }

    private var cornerRadius: CGFloat {
        isGroupSquircle ? (size * 0.30) : (size * 0.50)
    }

    private var hairlineWidth: CGFloat {
        displayScale >= 2.0 ? (1.0 / displayScale) : 1.0
    }

    private var effectiveImage: UIImage? {
        if let loadedImage {
            return loadedImage
        }
        return CuvenDesignMediaLoader.shared.cachedImage(for: urlString)
    }

    public var body: some View {
        let avatarShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let monogram = Self.initials(for: name)
        let tintSeed = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cuven" : name

        ZStack {
            // 1. Deterministic HSL pastel monogram fallback (`base.css:223-229, 339-342`)
            avatarShape
                .fill(CuvenColors.avatarBackground(for: tintSeed))

            if monogram.isEmpty {
                Image(systemName: isGroupSquircle ? "person.2.fill" : "person.fill")
                    .font(.system(size: max(10, size * 0.40), weight: .semibold))
                    .foregroundStyle(CuvenColors.avatarForeground(for: tintSeed))
            } else {
                Text(monogram)
                    .font(.system(size: max(10, size * 0.40), weight: .semibold, design: .default))
                    .tracking(-0.01 * size)
                    .foregroundStyle(CuvenColors.avatarForeground(for: tintSeed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // 2. Authenticated / cached remote or local photo (`base.css:232-241`)
            if let uiImage = effectiveImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(avatarShape)
                    .transition(.opacity)
            }

            // 3. Crisp inner hairline outline (`--image-outline`, `base.css:242-249`)
            avatarShape
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                    lineWidth: hairlineWidth
                )
        }
        .frame(width: size, height: size)
        .clipShape(avatarShape)
        .background {
            if showElevationRing {
                avatarShape
                    .stroke(CuvenColors.cardSurface, lineWidth: 3.0)
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isOnline {
                onlinePresenceDot
            }
        }
        .task(id: urlString) {
            await loadAvatarIfNeeded()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Live Online Presence Dot (`chat.css:52`)

    private var onlinePresenceDot: some View {
        let dotDiameter = min(max((size * 0.22).rounded(), 9.0), 16.0)
        let ringWidth = max(1.75, (size * 0.045).rounded() * 0.5)
        let inset = isGroupSquircle ? -ringWidth * 0.5 : max(0.0, size * 0.02 - ringWidth * 0.5)

        return Circle()
            .fill(CuvenColors.onlineGreen)
            .frame(width: dotDiameter, height: dotDiameter)
            .overlay {
                Circle()
                    .stroke(CuvenColors.paperBackground, lineWidth: ringWidth)
            }
            .padding(.trailing, inset)
            .padding(.bottom, inset)
            .accessibilityHidden(true)
    }

    private var accessibilityDescription: String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleanName.isEmpty ? "Avatar" : cleanName
        return isOnline ? "\(base), online" : base
    }

    // MARK: - Monogram Initials Extraction (`public/js/ui/format.js:73-82`)

    /// Exact Swift port of `initials(name)` in `public/js/ui/format.js:73-82`:
    /// - Returns the first CJK ideograph if present (`U+3400...U+9FFF`, `U+F900...U+FAFF`).
    /// - Returns two uppercase initials for two-word alphabetic names (`"Ada Lovelace"` -> `"AL"`).
    /// - Otherwise returns the first extended grapheme cluster uppercased (preserving flag/family emoji intact).
    public static func initials(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for char in trimmed {
            if char.unicodeScalars.contains(where: { scalar in
                (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            }) {
                return String(char)
            }
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 2,
           let firstChar = words[0].first, firstChar.isLetter,
           let secondChar = words[1].first, secondChar.isLetter {
            return (String(firstChar) + String(secondChar)).uppercased()
        }

        if let firstGrapheme = trimmed.first {
            return String(firstGrapheme).uppercased()
        }
        return ""
    }

    // MARK: - Async Load Pipeline

    @MainActor
    private func loadAvatarIfNeeded() async {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            loadedImage = nil
            return
        }
        if let cached = CuvenDesignMediaLoader.shared.cachedImage(for: raw) {
            loadedImage = cached
            return
        }
        let fetched = await CuvenDesignMediaLoader.shared.loadImage(for: raw)
        guard !Task.isCancelled else { return }
        if reduceMotion || didAnimateArrival {
            loadedImage = fetched
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                loadedImage = fetched
                didAnimateArrival = true
            }
        }
    }
}

// MARK: - Shared Authenticated & Coalesced Media Image Loader (Avatars & Backdrops)

/// `@MainActor` `NSCache` + request-coalescing image loader supporting relative `/api/media/...` paths,
/// `Origin` + `cfm_session` cookie authentication (`src/index.js:18-20`), `file://` URLs, and inline `data:` URIs.
@MainActor
final class CuvenDesignMediaLoader {
    static let shared = CuvenDesignMediaLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB decoded bitmap budget
    }

    func cachedImage(for rawURLString: String?) -> UIImage? {
        guard let key = normalizedCacheKey(for: rawURLString) else { return nil }
        return cache.object(forKey: key as NSString)
    }

    func loadImage(for rawURLString: String) async -> UIImage? {
        guard let key = normalizedCacheKey(for: rawURLString) else { return nil }
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            let decoded = await Self.fetchAndDecodeImage(rawURLString: key)
            if let self, let decoded {
                let pixelCost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
                self.cache.setObject(decoded, forKey: key as NSString, cost: max(1, pixelCost))
            }
            self?.inFlightTasks.removeValue(forKey: key)
            return decoded
        }

        inFlightTasks[key] = task
        return await task.value
    }

    private func normalizedCacheKey(for rawURLString: String?) -> String? {
        guard let trimmed = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func fetchAndDecodeImage(rawURLString: String) async -> UIImage? {
        // 1. Inline `data:image/...;base64,...` URI support
        if rawURLString.hasPrefix("data:"),
           let url = URL(string: rawURLString),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return await image.byPreparingForDisplay() ?? image
        }

        // 2. Resolve relative `/api/media/...` paths against configured `serverBaseURL`
        guard let resolvedURL = resolveURL(from: rawURLString) else {
            return nil
        }

        // 3. Local file URL fast path (offloaded from MainActor)
        if resolvedURL.isFileURL {
            let fileData = await Task.detached(priority: .utility) {
                try? Data(contentsOf: resolvedURL)
            }.value
            guard let data = fileData,
                  let image = UIImage(data: data) else {
                return nil
            }
            return await image.byPreparingForDisplay() ?? image
        }

        // 4. Remote HTTP(S) request with `Origin` + shared `HTTPCookieStorage` (`cfm_session`)
        var request = URLRequest(url: resolvedURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20

        if let scheme = resolvedURL.scheme, let host = resolvedURL.host {
            let portSuffix = resolvedURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(portSuffix)", forHTTPHeaderField: "Origin")
        }
        let tzMinutesWest = -(TimeZone.current.secondsFromGMT() / 60)
        request.setValue(String(tzMinutesWest), forHTTPHeaderField: "x-tz")

        if let cookies = HTTPCookieStorage.shared.cookies(for: resolvedURL), !cookies.isEmpty {
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (field, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let rawImage = UIImage(data: data) else {
                return nil
            }
            return await rawImage.byPreparingForDisplay() ?? rawImage
        } catch {
            return nil
        }
    }

    private static func resolveURL(from raw: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        let defaultBase = UserDefaults.standard.string(forKey: "cuven.serverBaseURL") ?? "https://wechat.cuven.us"
        guard let baseURL = URL(string: defaultBase) else {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            if let querySplit = raw.firstIndex(of: "?") {
                components?.path = String(raw[..<querySplit])
                components?.percentEncodedQuery = String(raw[raw.index(after: querySplit)...])
            } else {
                components?.path = raw
            }
            return components?.url
        }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
