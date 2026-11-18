import SwiftUI
import CuvenCore

// MARK: - Honk Live Keystroke Streaming Bubble (`public/css/thread.css:687-708` + `thread.js:1501-1521`)

/// Real-time incoming ghost bubble streaming peer keystrokes character-by-character
/// with organic spring layout morphing and a blinking accent caret.
public struct HonkLiveTypingBubble: View {
    public let previewText: String
    public let peerName: String?
    public let peerAvatarURL: String?
    public let showGroupChrome: Bool

    @State private var caretVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        previewText: String,
        peerName: String? = nil,
        peerAvatarURL: String? = nil,
        showGroupChrome: Bool = false
    ) {
        self.previewText = previewText
        self.peerName = peerName
        self.peerAvatarURL = peerAvatarURL
        self.showGroupChrome = showGroupChrome
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showGroupChrome {
                CuvenAvatarView(
                    name: peerName ?? "Peer",
                    urlString: peerAvatarURL,
                    size: 28,
                    isOnline: true
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                if showGroupChrome, let peerName, !peerName.isEmpty {
                    Text("\(peerName) · live")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .padding(.leading, 12)
                }

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(previewText)
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .contentTransition(.interpolate)
                        .multilineTextAlignment(.leading)

                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(CuvenColors.sidebarBlue)
                        .frame(width: 2, height: 17)
                        .opacity(reduceMotion ? 0.85 : (caretVisible ? 1.0 : 0.12))
                        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - 2 }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .padding(.leading, 6.5)
                .background(
                    BubbleTailShape(
                        isOutgoing: false,
                        isFirstInRun: true,
                        isLastInRun: true,
                        showTail: true
                    )
                    .fill(ThreadSurfaceTokens.incomingFill.opacity(0.92))
                )
                .overlay(
                    BubbleTailShape(
                        isOutgoing: false,
                        isFirstInRun: true,
                        isLastInRun: true,
                        showTail: true
                    )
                    .stroke(CuvenColors.sidebarBlue.opacity(0.18), lineWidth: 0.75)
                )
                .animation(reduceMotion ? .none : CuvenSprings.bubblePop, value: previewText)
            }
            .frame(maxWidth: 310, alignment: .leading)

            Spacer(minLength: 36)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .offset(y: 8).combined(with: .scale(scale: 0.96, anchor: .bottomLeading)).combined(with: .opacity),
                    removal: .opacity
                )
        )
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(525))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.14)) {
                    caretVisible.toggle()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peerName ?? "Peer") is typing: \(previewText)")
    }
}
