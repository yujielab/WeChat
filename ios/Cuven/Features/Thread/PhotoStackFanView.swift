import SwiftUI
import UIKit
import CuvenCore

// MARK: - Media Image Loader with Offline/Demo Artistic Fallback

struct ThreadMediaImageView: View {
    let urlString: String
    let serverBaseURL: URL
    let contentMode: ContentMode
    let isDrawing: Bool

    init(
        urlString: String,
        serverBaseURL: URL,
        contentMode: ContentMode = .fill,
        isDrawing: Bool = false
    ) {
        self.urlString = urlString
        self.serverBaseURL = serverBaseURL
        self.contentMode = contentMode
        self.isDrawing = isDrawing
    }

    private var resolvedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: serverBaseURL)?.absoluteURL
        }
        return URL(string: trimmed)
    }

    private var inlineBase64Image: UIImage? {
        guard urlString.hasPrefix("data:image"),
              let commaIndex = urlString.firstIndex(of: ",")
        else { return nil }
        let base64Part = String(urlString[urlString.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if let uiImage = inlineBase64Image {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else if let url = resolvedURL, url.isFileURL, let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else if let url = resolvedURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                case .empty:
                    fallbackArtwork(isLoading: true)
                case .failure:
                    fallbackArtwork(isLoading: false)
                @unknown default:
                    fallbackArtwork(isLoading: false)
                }
            }
        } else {
            fallbackArtwork(isLoading: false)
        }
    }

    @ViewBuilder
    private func fallbackArtwork(isLoading: Bool) -> some View {
        if isDrawing {
            ZStack {
                Color.white
                Canvas { context, size in
                    var stroke = Path()
                    let midY = size.height * 0.54
                    stroke.move(to: CGPoint(x: size.width * 0.16, y: midY + 18))
                    stroke.addCurve(
                        to: CGPoint(x: size.width * 0.52, y: midY - 22),
                        control1: CGPoint(x: size.width * 0.28, y: midY - 34),
                        control2: CGPoint(x: size.width * 0.42, y: midY + 28)
                    )
                    stroke.addCurve(
                        to: CGPoint(x: size.width * 0.84, y: midY + 6),
                        control1: CGPoint(x: size.width * 0.64, y: midY - 46),
                        control2: CGPoint(x: size.width * 0.74, y: midY + 26)
                    )
                    context.stroke(
                        stroke,
                        with: .color(Color(red: 0.09, green: 0.09, blue: 0.11)),
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                    )
                }
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Ink Sketch")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.black.opacity(0.45))
                    .padding(.bottom, 8)
                }
            }
        } else {
            let palette = deterministicPalette(for: urlString)
            ZStack {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                GeometryReader { proxy in
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: proxy.size.width * 0.34, height: proxy.size.width * 0.34)
                        .offset(x: proxy.size.width * 0.56, y: proxy.size.height * 0.14)

                    Path { path in
                        let w = proxy.size.width
                        let h = proxy.size.height
                        path.move(to: CGPoint(x: 0, y: h))
                        path.addLine(to: CGPoint(x: 0, y: h * 0.68))
                        path.addQuadCurve(
                            to: CGPoint(x: w * 0.52, y: h * 0.56),
                            control: CGPoint(x: w * 0.28, y: h * 0.44)
                        )
                        path.addQuadCurve(
                            to: CGPoint(x: w, y: h * 0.62),
                            control: CGPoint(x: w * 0.78, y: h * 0.70)
                        )
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(Color.black.opacity(0.18))
                }
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
    }

    private func deterministicPalette(for seedText: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in seedText.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let palettes: [[Color]] = [
            [Color(red: 0.16, green: 0.36, blue: 0.58), Color(red: 0.92, green: 0.58, blue: 0.42)],
            [Color(red: 0.14, green: 0.44, blue: 0.46), Color(red: 0.52, green: 0.78, blue: 0.72)],
            [Color(red: 0.28, green: 0.24, blue: 0.56), Color(red: 0.68, green: 0.46, blue: 0.76)],
            [Color(red: 0.86, green: 0.46, blue: 0.34), Color(red: 0.96, green: 0.76, blue: 0.44)],
            [Color(red: 0.12, green: 0.30, blue: 0.52), Color(red: 0.30, green: 0.62, blue: 0.84)]
        ]
        return palettes[Int(hash % UInt64(palettes.count))]
    }
}

// MARK: - 3D Tilted PhotoStackFanView (`public/css/photo-stack.css` + `photo-stack.js`)

public struct PhotoStackFanView: View {
    public let messages: [Message]
    public let mediaURLs: [String]
    public let isOutgoing: Bool
    public let senderDisplay: String
    public let senderAvatarURL: String?
    public let serverBaseURL: URL
    public let maxMediaWidth: CGFloat
    public let use24HourTime: Bool
    public let onOpenLightbox: ([String], Int) -> Void
    public let onExpandInline: () -> Void

    @State private var isFannedOut: Bool = false
    @State private var isPressed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fanReserve: CGFloat = 32

    public init(
        messages: [Message],
        mediaURLs: [String],
        isOutgoing: Bool,
        senderDisplay: String,
        senderAvatarURL: String?,
        serverBaseURL: URL,
        maxMediaWidth: CGFloat = 240,
        use24HourTime: Bool = true,
        onOpenLightbox: @escaping ([String], Int) -> Void,
        onExpandInline: @escaping () -> Void
    ) {
        self.messages = messages
        self.mediaURLs = mediaURLs
        self.isOutgoing = isOutgoing
        self.senderDisplay = senderDisplay
        self.senderAvatarURL = senderAvatarURL
        self.serverBaseURL = serverBaseURL
        self.maxMediaWidth = maxMediaWidth
        self.use24HourTime = use24HourTime
        self.onOpenLightbox = onOpenLightbox
        self.onExpandInline = onExpandInline
    }

    private var coverSize: CGSize {
        let first = messages.first
        return ThreadGroupingEngine.mediaDisplaySize(
            width: first?.mediaWidth,
            height: first?.mediaHeight,
            maxWidth: max(124, maxMediaWidth - fanReserve),
            maxHeight: 264
        )
    }

    private var visibleStackURLs: [String] {
        Array(mediaURLs.prefix(3))
    }

    public var body: some View {
        let size = coverSize
        let directionSign: CGFloat = isOutgoing ? -1 : 1
        let firstTimestamp = messages.first?.createdAt ?? 0
        let headerTime = ThreadTimeFormatter.clockString(from: firstTimestamp, use24Hour: use24HourTime)

        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            // Sender header badge sitting at the album's top corner (`photo-stack-head`)
            HStack(spacing: 7) {
                if !isOutgoing {
                    CuvenAvatarView(
                        name: senderDisplay,
                        urlString: senderAvatarURL,
                        size: 26,
                        isOnline: false
                    )
                    .overlay(Circle().stroke(CuvenColors.paperBackground, lineWidth: 2.5))
                }
                Text("\(senderDisplay) · \(headerTime)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .lineLimit(1)
                if isOutgoing {
                    CuvenAvatarView(
                        name: senderDisplay,
                        urlString: senderAvatarURL,
                        size: 26,
                        isOnline: false
                    )
                    .overlay(Circle().stroke(CuvenColors.paperBackground, lineWidth: 2.5))
                }
            }
            .padding(.horizontal, 2)

            // 3D fanned print stack
            ZStack(alignment: isOutgoing ? .bottomTrailing : .bottomLeading) {
                ForEach(Array(visibleStackURLs.enumerated().reversed()), id: \.offset) { index, url in
                    let depth = CGFloat(index)
                    let spreadAngle = (isFannedOut || isPressed) ? 5.2 : 2.6
                    let spreadShift: CGFloat = (isFannedOut || isPressed) ? 16 : 8.5
                    let cardPitch: Double = isFannedOut ? Double(depth) * 4.0 : Double(depth) * 1.8

                    Button {
                        CuvenHaptics.lightTap()
                        if !isFannedOut && visibleStackURLs.count > 1 {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : CuvenSprings.bubblePop) {
                                isFannedOut = true
                            }
                        } else {
                            onOpenLightbox(mediaURLs, index)
                        }
                    } label: {
                        ThreadMediaImageView(
                            urlString: url,
                            serverBaseURL: serverBaseURL,
                            contentMode: .fill,
                            isDrawing: false
                        )
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .saturation(index == 0 ? 1.0 : (isFannedOut ? 0.94 : 0.78))
                        .overlay {
                            if index > 0 && !isFannedOut {
                                CuvenColors.paperBackground.opacity(0.18)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1)
                        )
                        .shadow(
                            color: Color.black.opacity(index == 0 ? 0.10 : 0.14),
                            radius: index == 0 ? 6 : 8,
                            x: 0,
                            y: 3
                        )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(index == 0 && isPressed ? 0.985 : 1.0)
                    .rotation3DEffect(
                        .degrees(reduceMotion ? 0 : cardPitch),
                        axis: (x: 0.25, y: directionSign, z: 0),
                        perspective: 0.55
                    )
                    .rotationEffect(
                        .degrees(reduceMotion ? 0 : Double(depth * directionSign) * spreadAngle),
                        anchor: isOutgoing ? .bottomTrailing : .bottomLeading
                    )
                    .offset(
                        x: reduceMotion ? 0 : depth * directionSign * spreadShift,
                        y: isFannedOut ? -depth * 4 : 0
                    )
                    .zIndex(Double(visibleStackURLs.count - index))
                }
            }
            .frame(width: size.width + fanReserve, height: size.height + (isFannedOut ? 10 : 0), alignment: isOutgoing ? .trailing : .leading)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            withAnimation(.easeOut(duration: 0.12)) { isPressed = true }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(CuvenSprings.pressBounce) { isPressed = false }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(mediaURLs.count) photos shared by \(senderDisplay)")
            .accessibilityAddTraits(.isButton)

            // Caption & Expand / View All bar (`photo-stack-caption`)
            HStack(spacing: 6) {
                Button {
                    CuvenHaptics.lightTap()
                    onOpenLightbox(mediaURLs, 0)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12, weight: .medium))
                        Text("\(mediaURLs.count) photos")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .frame(minHeight: 32)
                }
                .buttonStyle(.plain)

                if isFannedOut {
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(CuvenColors.inkSecondary.opacity(0.6))
                    Button {
                        CuvenHaptics.selectionChanged()
                        onOpenLightbox(mediaURLs, 0)
                    } label: {
                        Text("Open Lightbox")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                }

                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(CuvenColors.inkSecondary.opacity(0.6))

                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(CuvenSprings.bubblePop) {
                        onExpandInline()
                    }
                } label: {
                    Text("Expand")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
