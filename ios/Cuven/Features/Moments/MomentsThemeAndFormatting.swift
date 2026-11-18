// MomentsThemeAndFormatting.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Apple Human Interface Guidelines & Developer Documentation Grounding:
// - Designing for iPhone Duo: Asymmetric right system column clearance & posture-aware insets.
// - Materials / Liquid Glass: Frosted overlay pills with Reduce Transparency solid fallbacks.
// - Typography & Dynamic Type: Clarinetta editorial display + Dynamic Type capped at 21pt on chrome.
// - Accessibility: WCAG AA (>=4.5:1) color tokens, >=44x44pt hit targets, VoiceOver ALT descriptions,
//   and UIAccessibility.isReduceMotionEnabled / accessibilityReduceMotion transitions.

import SwiftUI
import UIKit
import AVFoundation
import CuvenCore

// MARK: - Moments Palette (Exact Web tokens.css & moments.css Parity)

enum MomentsPalette {
    /// Cuven `--sky-title` (`tokens.css:62,285`): `#0099FF` in Light, `#4CC2FF` in Dark,
    /// with darker high-contrast variant when Increase Contrast is enabled.
    static var skyTitle: Color {
        Color(UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return highContrast
                    ? UIColor(red: 0.42, green: 0.82, blue: 1.00, alpha: 1.0)
                    : UIColor(red: 0x4C / 255.0, green: 0xC2 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            } else {
                return highContrast
                    ? UIColor(red: 0x00 / 255.0, green: 0x62 / 255.0, blue: 0xCC / 255.0, alpha: 1.0)
                    : UIColor(red: 0x00 / 255.0, green: 0x99 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            }
        })
    }

    /// Accessible `--blue-text` (`>=4.5:1` WCAG AA contrast): `#0062CC` light / `#0A84FF` dark.
    static var accessibleBlueText: Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            } else {
                return UIColor(red: 0x00 / 255.0, green: 0x62 / 255.0, blue: 0xCC / 255.0, alpha: 1.0)
            }
        })
    }

    /// Conic gradient ring for unseen Moments stories (`moments.css:96`).
    static var freshStoryRingGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 0.00, green: 0.48, blue: 1.00), // #007AFF
                Color(red: 0.35, green: 0.34, blue: 0.84), // #5856D6
                Color(red: 0.75, green: 0.35, blue: 0.95), // #BF5AF2
                Color(red: 1.00, green: 0.22, blue: 0.37), // #FF375F
                Color(red: 1.00, green: 0.58, blue: 0.00), // #FF9500
                Color(red: 0.00, green: 0.48, blue: 1.00)  // loop seamlessly
            ]),
            center: .center,
            angle: .degrees(200)
        )
    }

    /// Default cover ribbon when user has no custom cover (`moments.css:325-330`).
    static func coverGradient(dominantTintHex: String?) -> LinearGradient {
        if let hex = dominantTintHex, let tint = color(fromHex: hex) {
            return LinearGradient(
                colors: [
                    tint.opacity(0.92),
                    Color(red: 0.11, green: 0.18, blue: 0.42),
                    Color(red: 0.04, green: 0.06, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0x0D / 255.0, green: 0x14 / 255.0, blue: 0x30 / 255.0),
                Color(red: 0x1C / 255.0, green: 0x2F / 255.0, blue: 0x6B / 255.0),
                Color(red: 0x0A / 255.0, green: 0x0F / 255.0, blue: 0x24 / 255.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Resolves built-in cover presets across raw names (`"mist"`), profile-editor prefixes (`"preset:mist"`),
    /// and seeded demo cover URLs (`"cuven-demo://cover/mist"`).
    static func resolveCoverPreset(_ rawCover: String?) -> BackdropPreset? {
        guard let trimmed = rawCover?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        let candidate: String
        if trimmed.hasPrefix("preset:") {
            candidate = String(trimmed.dropFirst(7))
        } else if trimmed.hasPrefix("backdrop:") {
            candidate = String(trimmed.dropFirst(9))
        } else if trimmed.hasPrefix("cuven-demo://cover/") {
            candidate = String(trimmed.dropFirst("cuven-demo://cover/".count))
        } else if trimmed.hasPrefix("demo://cover/") {
            candidate = String(trimmed.dropFirst("demo://cover/".count))
        } else {
            candidate = trimmed
        }
        if candidate == "dune" {
            return .sand
        }
        return BackdropPreset(rawValue: candidate)
    }

    static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Timestamp & Policy Formatting (Exact Port of moments.js & moments-editor.js)

public enum MomentsTimeFormatter {
    private static let fullMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]
    private static let shortMonths = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]
    private static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Normalizes epoch timestamps whether stored in milliseconds (`1763400000000`) or seconds (`1763400000`).
    public static func date(fromEpoch raw: Int64) -> Date {
        if raw > 10_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw) / 1000.0)
        } else {
            return Date(timeIntervalSince1970: TimeInterval(raw))
        }
    }

    public static func epochMilliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    /// Matches `agoLong(ts, now)` in `public/js/views/moments.js:766-776`.
    public static func agoLong(timestamp: Int64, now: Date = Date()) -> String {
        let target = date(fromEpoch: timestamp)
        let elapsed = max(0, now.timeIntervalSince(target))

        if elapsed < 60 {
            return "Just now"
        }
        if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "\(mins) \(mins == 1 ? "minute" : "minutes") ago"
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3600)
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        if elapsed < 7 * 86_400 {
            let days = Int(elapsed / 86_400)
            return "\(days) \(days == 1 ? "day" : "days") ago"
        }

        let calendar = Calendar.current
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: target)
        let nowYear = calendar.component(.year, from: now)
        let monthIndex = max(1, min(12, targetComponents.month ?? 1)) - 1
        let day = targetComponents.day ?? 1
        let yearSuffix = (targetComponents.year == nowYear) ? "" : ", \(targetComponents.year ?? nowYear)"
        return "\(fullMonths[monthIndex]) \(day)\(yearSuffix)"
    }

    /// Matches `whenText(ts, now)` in `public/js/views/moments-editor.js:31-40`.
    public static func scheduledWhenText(timestamp: Int64, now: Date = Date(), use24Hour: Bool = true) -> String {
        scheduledWhenText(date: date(fromEpoch: timestamp), now: now, use24Hour: use24Hour)
    }

    public static func scheduledWhenText(date target: Date, now: Date = Date(), use24Hour: Bool = true) -> String {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTarget = calendar.startOfDay(for: target)
        let dayDiff = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day ?? 0

        let comps = calendar.dateComponents([.hour, .minute, .month, .day, .weekday], from: target)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let timeStr: String
        if use24Hour {
            timeStr = String(format: "%d:%02d", hour, minute)
        } else {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            let period = hour < 12 ? "AM" : "PM"
            timeStr = String(format: "%d:%02d %@", h12, minute, period)
        }

        if dayDiff == 0 {
            return "Today \(timeStr)"
        }
        if dayDiff == 1 {
            return "Tomorrow \(timeStr)"
        }

        let weekdayIndex = max(1, min(7, comps.weekday ?? 1)) - 1
        let monthIndex = max(1, min(12, comps.month ?? 1)) - 1
        let day = comps.day ?? 1
        return "\(shortWeekdays[weekdayIndex]), \(shortMonths[monthIndex]) \(day), \(timeStr)"
    }

    /// Matches `whoText(audience, comments)` in `public/js/views/moments-editor.js:43-49`.
    public static func whoSummaryText(audience: String, commentPolicy: String) -> String {
        let see = (audience == "friends") ? "Friends" : "Everyone"
        if commentPolicy == "off" {
            return "\(see) can see · Comments off"
        }
        let say = (commentPolicy == "friends") ? "Friends" : "Everyone"
        if say == see {
            return "\(see) can see and comment"
        }
        return "\(see) can see · \(say) can comment"
    }
}

// MARK: - Media Resolution, Procedural Seed Artwork & Blur-to-Sharp Image Loader

@MainActor
final class MomentsDecodedImageCache {
    static let shared = MomentsDecodedImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 120
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Renders remote URLs, local `file://` URLs, `data:image/...;base64,...` inline payloads,
/// and deterministic procedural editorial landscapes when offline demo URLs are used in Simulator tests,
/// with smooth blur-to-sharp `reveal.js` arrival transition.
struct MomentsMediaThumbnailView: View {
    let urlString: String
    let serverBaseURL: URL
    let filterName: String?
    let altLabel: String?
    var contentMode: ContentMode = .fill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedImage: UIImage?
    @State private var isRevealed: Bool = false

    var body: some View {
        ZStack {
            if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .blur(radius: (isRevealed || reduceMotion) ? 0 : 10)
                    .scaleEffect((isRevealed || reduceMotion) ? 1.0 : 1.03)
                    .opacity(isRevealed ? 1.0 : 0.85)
            } else {
                MomentsEditorialSeedArtwork(seedKey: urlString, filterName: filterName)
            }
        }
        .accessibilityLabel(altLabel ?? "Photo")
        .task(id: "\(urlString)|\(filterName ?? "")") {
            await loadMediaImage()
        }
    }

    private func loadMediaImage() async {
        let cacheKey = "\(urlString)|\(filterName ?? "original")"
        if let cached = MomentsDecodedImageCache.shared.image(for: cacheKey) {
            loadedImage = cached
            isRevealed = true
            return
        }

        var rawImage: UIImage?
        var filterAlreadyBakedInFile = false

        if urlString.hasPrefix("data:image"),
           let commaIndex = urlString.firstIndex(of: ",") {
            let base64Part = String(urlString[urlString.index(after: commaIndex)...])
            if let data = Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters) {
                rawImage = UIImage(data: data)
            }
        } else if urlString.hasPrefix("cuven-demo://") || urlString.hasPrefix("demo://") {
            if let filterName,
               let tone = PhotoToneFilter.fromStoredName(filterName),
               tone != .original {
                rawImage = CoreImagePhotoFilterEngine.makeSeededEditorialImage(seedKey: urlString)
            }
        } else if let resolved = resolveURL(urlString) {
            if resolved.isFileURL {
                if let data = try? Data(contentsOf: resolved) {
                    rawImage = UIImage(data: data)
                    filterAlreadyBakedInFile = resolved.lastPathComponent.hasPrefix("cuven-moment-")
                }
            } else if let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                var request = URLRequest(url: resolved)
                request.httpShouldHandleCookies = true
                request.timeoutInterval = 12
                if let host = resolved.host {
                    let portSuffix = resolved.port.map { ":\($0)" } ?? ""
                    request.setValue("\(scheme)://\(host)\(portSuffix)", forHTTPHeaderField: "Origin")
                }
                let tzMinutesWest = -(TimeZone.current.secondsFromGMT() / 60)
                request.setValue(String(tzMinutesWest), forHTTPHeaderField: "x-tz")
                if let cookies = HTTPCookieStorage.shared.cookies(for: resolved), !cookies.isEmpty {
                    for (header, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                        request.setValue(value, forHTTPHeaderField: header)
                    }
                }
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let decoded = UIImage(data: data) {
                    rawImage = decoded
                }
            }
        }

        guard let baseImage = rawImage else { return }

        let finalImage: UIImage
        if !filterAlreadyBakedInFile,
           let filterName,
           let tone = PhotoToneFilter.fromStoredName(filterName),
           tone != .original {
            finalImage = CoreImagePhotoFilterEngine.shared.apply(
                to: baseImage,
                parameters: PhotoEditParameters(rotationQuarterTurns: 0, cropPreset: .original, tone: tone),
                maxDimension: 1600
            ) ?? baseImage
        } else {
            finalImage = baseImage
        }

        MomentsDecodedImageCache.shared.store(finalImage, for: cacheKey)
        loadedImage = finalImage
        if reduceMotion {
            isRevealed = true
        } else {
            isRevealed = false
            withAnimation(.easeOut(duration: 0.28)) {
                isRevealed = true
            }
        }
    }

    private func resolveURL(_ raw: String) -> URL? {
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: serverBaseURL)?.absoluteURL
        }
        return URL(string: raw)
    }
}

/// Deterministic editorial landscape artwork for offline/demo seed Moments (`Coisini` ridge sunrise,
/// `Mira` mountain trilogy, etc.) when network assets are unreachable in sandboxed Simulator runs.
struct MomentsEditorialSeedArtwork: View {
    let seedKey: String
    let filterName: String?

    var body: some View {
        GeometryReader { geo in
            let palette = Self.palette(for: seedKey, filterName: filterName)
            ZStack {
                LinearGradient(
                    colors: palette.skyColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Sun / moon orb matching `tools/e2e/moments.cjs:22`
                Circle()
                    .fill(palette.orbColor)
                    .frame(
                        width: min(geo.size.width, geo.size.height) * 0.28,
                        height: min(geo.size.width, geo.size.height) * 0.28
                    )
                    .blur(radius: 1.5)
                    .position(
                        x: geo.size.width * palette.orbPosition.x,
                        y: geo.size.height * palette.orbPosition.y
                    )

                // Layered mountain ridge silhouette
                Path { path in
                    let w = geo.size.width
                    let h = geo.size.height
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.64))
                    path.addQuadCurve(
                        to: CGPoint(x: w * 0.46, y: h * 0.52),
                        control: CGPoint(x: w * 0.22, y: h * 0.44)
                    )
                    path.addQuadCurve(
                        to: CGPoint(x: w, y: h * 0.60),
                        control: CGPoint(x: w * 0.74, y: h * 0.68)
                    )
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(palette.ridgeBackColor)

                Path { path in
                    let w = geo.size.width
                    let h = geo.size.height
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.78))
                    path.addQuadCurve(
                        to: CGPoint(x: w * 0.58, y: h * 0.68),
                        control: CGPoint(x: w * 0.30, y: h * 0.60)
                    )
                    path.addQuadCurve(
                        to: CGPoint(x: w, y: h * 0.75),
                        control: CGPoint(x: w * 0.82, y: h * 0.82)
                    )
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(palette.ridgeFrontColor)
            }
        }
    }

    private struct SeedPalette {
        let skyColors: [Color]
        let orbColor: Color
        let orbPosition: CGPoint
        let ridgeBackColor: Color
        let ridgeFrontColor: Color
    }

    private static func palette(for key: String, filterName: String?) -> SeedPalette {
        let hash = abs(key.unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) })
        let tone = filterName.flatMap { PhotoToneFilter.fromStoredName($0) } ?? .original

        if tone == .mono {
            return SeedPalette(
                skyColors: [Color(white: 0.78), Color(white: 0.34)],
                orbColor: Color.white.opacity(0.86),
                orbPosition: CGPoint(x: 0.68, y: 0.32),
                ridgeBackColor: Color(white: 0.22).opacity(0.75),
                ridgeFrontColor: Color(white: 0.11).opacity(0.92)
            )
        }

        let presets: [SeedPalette] = [
            // Sunrise ridge (#f6a35b -> #6a4c93)
            SeedPalette(
                skyColors: [
                    Color(red: 0.96, green: 0.64, blue: 0.36),
                    Color(red: 0.85, green: 0.44, blue: 0.52),
                    Color(red: 0.42, green: 0.30, blue: 0.58)
                ],
                orbColor: Color(red: 1.0, green: 0.94, blue: 0.80).opacity(0.90),
                orbPosition: CGPoint(x: 0.68, y: 0.34),
                ridgeBackColor: Color(red: 0.26, green: 0.18, blue: 0.40).opacity(0.72),
                ridgeFrontColor: Color(red: 0.14, green: 0.10, blue: 0.24).opacity(0.90)
            ),
            // Alpine lake (#355c7d -> #c06c84)
            SeedPalette(
                skyColors: [
                    Color(red: 0.21, green: 0.36, blue: 0.49),
                    Color(red: 0.45, green: 0.36, blue: 0.52),
                    Color(red: 0.75, green: 0.42, blue: 0.52)
                ],
                orbColor: Color.white.opacity(0.82),
                orbPosition: CGPoint(x: 0.32, y: 0.30),
                ridgeBackColor: Color(red: 0.16, green: 0.24, blue: 0.35).opacity(0.76),
                ridgeFrontColor: Color(red: 0.09, green: 0.14, blue: 0.22).opacity(0.92)
            ),
            // Emerald ridge (#2a9d8f -> #e9c46a)
            SeedPalette(
                skyColors: [
                    Color(red: 0.16, green: 0.62, blue: 0.56),
                    Color(red: 0.42, green: 0.70, blue: 0.54),
                    Color(red: 0.91, green: 0.77, blue: 0.42)
                ],
                orbColor: Color(red: 1.0, green: 0.97, blue: 0.86).opacity(0.86),
                orbPosition: CGPoint(x: 0.72, y: 0.28),
                ridgeBackColor: Color(red: 0.12, green: 0.34, blue: 0.32).opacity(0.72),
                ridgeFrontColor: Color(red: 0.07, green: 0.21, blue: 0.20).opacity(0.90)
            ),
            // Dusk coast (#264653 -> #e76f51)
            SeedPalette(
                skyColors: [
                    Color(red: 0.15, green: 0.27, blue: 0.33),
                    Color(red: 0.54, green: 0.35, blue: 0.36),
                    Color(red: 0.91, green: 0.44, blue: 0.32)
                ],
                orbColor: Color(red: 1.0, green: 0.86, blue: 0.72).opacity(0.88),
                orbPosition: CGPoint(x: 0.62, y: 0.36),
                ridgeBackColor: Color(red: 0.14, green: 0.19, blue: 0.25).opacity(0.78),
                ridgeFrontColor: Color(red: 0.08, green: 0.11, blue: 0.16).opacity(0.92)
            )
        ]
        return presets[hash % presets.count]
    }
}

// MARK: - Viewport-Gated Muted Looping Video View (`moments.js:732-762`)

@MainActor
final class MomentsVideoSoundCoordinator: ObservableObject {
    static let shared = MomentsVideoSoundCoordinator()
    @Published var isSoundEnabled: Bool = false
    private init() {}
}

struct MomentsInlineVideoView: View {
    let urlString: String
    let serverBaseURL: URL
    var bottomControlOffset: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var soundCoordinator = MomentsVideoSoundCoordinator.shared
    @State private var player: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?
    @State private var isPlaying: Bool = false

    var body: some View {
        ZStack {
            MomentsEditorialSeedArtwork(seedKey: urlString, filterName: nil)

            if let player {
                MomentsAVPlayerLayerRepresentable(player: player)
            }

            if !isPlaying {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: 1.5)
                    }
                    .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        CuvenHaptics.lightTap()
                        soundCoordinator.isSoundEnabled.toggle()
                        player?.isMuted = !soundCoordinator.isSoundEnabled
                    } label: {
                        Image(systemName: soundCoordinator.isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.58), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(soundCoordinator.isSoundEnabled ? "Mute" : "Unmute")
                    .padding(.trailing, 6)
                    .padding(.bottom, bottomControlOffset)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let player else {
                isPlaying.toggle()
                return
            }
            if isPlaying {
                soundCoordinator.isSoundEnabled.toggle()
                player.isMuted = !soundCoordinator.isSoundEnabled
            } else {
                player.play()
                isPlaying = true
            }
        }
        .onAppear {
            configurePlayerIfNeeded()
            if !reduceMotion {
                player?.play()
                isPlaying = player != nil
            }
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
            playerLooper?.disableLooping()
            playerLooper = nil
            player = nil
        }
        .onChange(of: soundCoordinator.isSoundEnabled) { _, newValue in
            player?.isMuted = !newValue
        }
    }

    private func configurePlayerIfNeeded() {
        guard player == nil else { return }
        let resolved: URL?
        if urlString.hasPrefix("/") {
            resolved = URL(string: urlString, relativeTo: serverBaseURL)?.absoluteURL
        } else {
            resolved = URL(string: urlString)
        }
        guard let url = resolved,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            return
        }
        let templateItem = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = !soundCoordinator.isSoundEnabled
        let looper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
        playerLooper = looper
        player = queuePlayer
    }
}

private struct MomentsAVPlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerContainerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
