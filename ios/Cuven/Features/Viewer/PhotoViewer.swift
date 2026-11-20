import SwiftUI
import AVKit

/// A photo grows out of its bubble into the full screen and goes back into
/// it; pinch or double-tap to zoom, drag down to close.
struct PhotoViewer: View {
    let item: ViewerItem
    let nav: Nav
    let insets: EdgeInsets

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var drag: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var chrome = true
    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geo in
            let target = fit(item.aspect, in: geo.size)
            let source = item.source.width > 1 ? item.source : target.insetBy(dx: target.width * 0.1, dy: target.height * 0.1)
            let rect = expanded ? target : source
            let progress = min(1, abs(drag.height) / 300)

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(expanded ? 1 - progress * 0.9 : 0)
                    .ignoresSafeArea()

                content
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 18, style: .continuous))
                    .scaleEffect(scale * (1 - progress * 0.25))
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(dragGesture(geo.size))
                    .simultaneousGesture(zoomGesture)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }

                if chrome && expanded {
                    HStack {
                        Button { close() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).glassCircle(tint: .black.opacity(0.3))
                        }
                        .accessibilityLabel("Close")
                        Spacer()
                        Button { share() } label: {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).glassCircle(tint: .black.opacity(0.3))
                        }
                        .accessibilityLabel("Share")
                    }
                    .padding(.horizontal, max(insets.leading, 16))
                    .padding(.trailing, max(insets.trailing - 16, 0))
                    .padding(.bottom, max(insets.bottom, 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(1 - progress)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if item.isVideo, let asset = AuthorizedAsset.make(item.path) {
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                p.play()
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.morph) { expanded = true }
        }
        .onDisappear { player?.pause() }
        .statusBarHidden(expanded)
    }

    @ViewBuilder
    private var content: some View {
        if item.isVideo {
            ZStack {
                Color.black
                if let player { VideoPlayer(player: player) }
            }
        } else {
            ZStack {
                RemoteImage(item.path, maxPixel: 900, contentMode: .fill, placeholder: .clear)
                RemoteImage(item.path, maxPixel: 2600, contentMode: .fill, placeholder: .clear)
            }
        }
    }

    private func fit(_ aspect: CGFloat, in size: CGSize) -> CGRect {
        let a = max(0.1, aspect)
        var w = size.width
        var h = w / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if scale > 1.01 {
                    pan = CGSize(width: basePan.width + v.translation.width, height: basePan.height + v.translation.height)
                } else {
                    drag = v.translation
                }
            }
            .onEnded { v in
                if scale > 1.01 {
                    basePan = pan
                    return
                }
                if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 360 {
                    close()
                } else {
                    withAnimation(Motion.pressOut) { drag = .zero }
                }
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = max(1, min(5, baseScale * v.magnification)) }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 {
                    withAnimation(Motion.ui) { scale = 1; pan = .zero; basePan = .zero; baseScale = 1 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(Motion.ui) {
            if scale > 1.01 { scale = 1; pan = .zero; basePan = .zero }
            else { scale = 2.5 }
            baseScale = scale
        }
        Haptics.tap()
    }

    private func close() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.morph) {
            expanded = false
            drag = .zero
            scale = 1
            pan = .zero
        }
        Task {
            try? await Task.sleep(for: .milliseconds(330))
            nav.viewer = nil
        }
    }

    private func share() {
        Task {
            guard let data = await ImageStore.shared.data(item.path) else { return }
            if item.isVideo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("video.mp4")
                try? data.write(to: url)
                Share.present([url])
            } else if let img = UIImage(data: data) {
                Share.present([img])
            }
        }
    }
}
