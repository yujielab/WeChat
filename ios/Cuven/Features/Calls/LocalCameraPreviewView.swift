import SwiftUI
import CuvenCore
#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
#endif

// MARK: - Apple HIG & Developer Documentation Grounding
// - Apple Developer Documentation: AVCaptureSession / AVCaptureVideoPreviewLayer (serial sessionQueue)
// - Apple HIG: Privacy (graceful camera permission & Simulator studio fallback, never blank black screen)
// - Cuven Web Parity: public/js/views/call.js (271-283, 427-460), public/css/call.css (198-226)

#if canImport(AVFoundation) && canImport(UIKit)
/// Thread-safe serial-queue `AVCaptureSession` controller conforming cleanly to Swift 6 concurrency.
final class CameraCaptureController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "us.cuven.calls.camera", qos: .userInitiated)
    private var currentPosition: AVCaptureDevice.Position = .front
    private var isConfigured = false

    static var hasHardwareCamera: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return !discovery.devices.isEmpty
        #endif
    }

    func startOrUpdate(isEnabled: Bool, useFrontCamera: Bool) {
        guard Self.hasHardwareCamera else { return }
        let desiredPosition: AVCaptureDevice.Position = useFrontCamera ? .front : .back

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !isEnabled {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                return
            }

            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                self.configureAndRun(position: desiredPosition)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted, let self else { return }
                    self.sessionQueue.async {
                        self.configureAndRun(position: desiredPosition)
                    }
                }
            default:
                break
            }
        }
    }

    func stop() {
        guard Self.hasHardwareCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun(position: AVCaptureDevice.Position) {
        if !isConfigured || currentPosition != position {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            for existingInput in session.inputs {
                session.removeInput(existingInput)
            }

            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video)
            if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input)
                currentPosition = position
                isConfigured = true
            }
            session.commitConfiguration()
        }

        if !session.isRunning {
            session.startRunning()
        }
    }
}

/// UIKit host view whose backing layer is `AVCaptureVideoPreviewLayer` for zero-copy GPU camera rendering.
final class CameraPreviewHostUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // Safe: layerClass is overridden to AVCaptureVideoPreviewLayer above.
        layer as! AVCaptureVideoPreviewLayer
    }

    let controller = CameraCaptureController()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoPreviewLayer.videoGravity = .resizeAspectFill
        videoPreviewLayer.session = controller.session
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        controller.stop()
    }
}

private struct HardwareCameraPreviewRepresentable: UIViewRepresentable {
    let isEnabled: Bool
    let useFrontCamera: Bool

    func makeUIView(context: Context) -> CameraPreviewHostUIView {
        let view = CameraPreviewHostUIView()
        view.controller.startOrUpdate(isEnabled: isEnabled, useFrontCamera: useFrontCamera)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewHostUIView, context: Context) {
        uiView.controller.startOrUpdate(isEnabled: isEnabled, useFrontCamera: useFrontCamera)
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = useFrontCamera
        }
    }

    static func dismantleUIView(_ uiView: CameraPreviewHostUIView, coordinator: ()) {
        uiView.controller.stop()
    }
}
#endif

/// Native local camera preview with automatic graceful Simulator animated mesh + portrait stage
/// when hardware camera is unavailable (CI Simulator) or switched off (`call.css:224-226`).
public struct LocalCameraPreviewView: View {
    public let userName: String
    public let avatarURL: String?
    public let isCameraEnabled: Bool
    public let useFrontCamera: Bool
    public let isCompactTile: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        userName: String,
        avatarURL: String? = nil,
        isCameraEnabled: Bool,
        useFrontCamera: Bool = true,
        isCompactTile: Bool = true
    ) {
        self.userName = userName
        self.avatarURL = avatarURL
        self.isCameraEnabled = isCameraEnabled
        self.useFrontCamera = useFrontCamera
        self.isCompactTile = isCompactTile
    }

    private var hasRealHardwareCamera: Bool {
        #if canImport(AVFoundation) && canImport(UIKit)
        return CameraCaptureController.hasHardwareCamera
        #else
        return false
        #endif
    }

    public var body: some View {
        ZStack {
            if !isCameraEnabled {
                cameraDisabledSurface
            } else if hasRealHardwareCamera {
                #if canImport(AVFoundation) && canImport(UIKit)
                HardwareCameraPreviewRepresentable(
                    isEnabled: isCameraEnabled,
                    useFrontCamera: useFrontCamera
                )
                #endif
            } else {
                SimulatedStudioVideoStage(
                    displayName: userName,
                    avatarURL: avatarURL,
                    isCompactTile: isCompactTile,
                    accentWarm: !useFrontCamera,
                    reduceMotion: reduceMotion
                )
            }
        }
        .clipped()
    }

    private var cameraDisabledSurface: some View {
        ZStack {
            Color(red: 0.094, green: 0.094, blue: 0.106) // #18181B (`call.css:224`)
            VStack(spacing: isCompactTile ? 6 : 12) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isCompactTile ? 22 : 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                if !isCompactTile {
                    Text("Camera Off")
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
    }
}

/// Animated 60fps Aurora/Mesh studio video stage used both for Simulator local camera preview
/// and simulated live remote video stage in Demo / Simulator environments.
struct SimulatedStudioVideoStage: View {
    let displayName: String
    let avatarURL: String?
    let isCompactTile: Bool
    let accentWarm: Bool
    let reduceMotion: Bool
    var audioLevel: Double = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : (1.0 / 30.0), paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Canvas { context, size in
                    let baseRect = CGRect(origin: .zero, size: size)
                    let bgStart = accentWarm
                        ? Color(red: 0.12, green: 0.09, blue: 0.18)
                        : Color(red: 0.06, green: 0.12, blue: 0.20)
                    let bgEnd = accentWarm
                        ? Color(red: 0.05, green: 0.05, blue: 0.09)
                        : Color(red: 0.03, green: 0.06, blue: 0.11)

                    context.fill(
                        Path(baseRect),
                        with: .linearGradient(
                            Gradient(colors: [bgStart, bgEnd]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: size.height)
                        )
                    )

                    let orbs: [(dx: Double, dy: Double, radiusRatio: CGFloat, color: Color)] = accentWarm
                        ? [
                            (0.32 + 0.16 * cos(t * 0.55), 0.34 + 0.14 * sin(t * 0.42), 0.62, Color(red: 0.96, green: 0.46, blue: 0.36).opacity(0.34)),
                            (0.70 + 0.14 * sin(t * 0.48), 0.64 + 0.15 * cos(t * 0.37), 0.58, Color(red: 0.56, green: 0.34, blue: 0.92).opacity(0.30)),
                            (0.48 + 0.12 * sin(t * 0.71), 0.50 + 0.10 * cos(t * 0.63), 0.45, Color(red: 0.24, green: 0.72, blue: 0.88).opacity(0.22))
                        ]
                        : [
                            (0.30 + 0.15 * sin(t * 0.52), 0.32 + 0.14 * cos(t * 0.44), 0.64, Color(red: 0.15, green: 0.56, blue: 0.92).opacity(0.36)),
                            (0.72 + 0.14 * cos(t * 0.46), 0.66 + 0.16 * sin(t * 0.39), 0.60, Color(red: 0.16, green: 0.78, blue: 0.68).opacity(0.28)),
                            (0.52 + 0.12 * cos(t * 0.67), 0.46 + 0.12 * sin(t * 0.59), 0.46, Color(red: 0.44, green: 0.38, blue: 0.96).opacity(0.24))
                        ]

                    let maxDim = max(size.width, size.height)
                    for orb in orbs {
                        let center = CGPoint(x: size.width * orb.dx, y: size.height * orb.dy)
                        let radius = maxDim * orb.radiusRatio
                        let rect = CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [orb.color, .clear]),
                                center: center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                }

                // Portrait + audio-reactive halo ring (`call.css:69-80`)
                VStack(spacing: isCompactTile ? 6 : 12) {
                    ZStack {
                        let pulseScale = 1.0 + CGFloat(min(0.22, audioLevel * 0.22))
                        Circle()
                            .strokeBorder(.white.opacity(0.18 + min(0.45, audioLevel * 0.5)), lineWidth: isCompactTile ? 1.5 : 2.5)
                            .frame(
                                width: (isCompactTile ? 46 : 104) * pulseScale,
                                height: (isCompactTile ? 46 : 104) * pulseScale
                            )

                        CallStageAvatarBadge(
                            name: displayName,
                            urlString: avatarURL,
                            size: isCompactTile ? 40 : 88
                        )
                    }

                    if !isCompactTile {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(CuvenColors.onlineGreen)
                                .frame(width: 6, height: 6)
                            Text("\(displayName) · HD")
                                .font(CuvenFonts.cappedCaption(weight: .semibold))
                                .foregroundStyle(.white.opacity(0.86))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.34), in: Capsule())
                    }
                }
            }
        }
    }
}

/// Self-contained high-craft circular avatar renderer for Call stages that seamlessly uses
/// `CuvenAvatarView` when `DesignSystem` is linked.
struct CallStageAvatarBadge: View {
    let name: String
    let urlString: String?
    let size: CGFloat
    var isOnline: Bool = false

    var body: some View {
        CuvenAvatarView(
            name: name,
            urlString: urlString,
            size: size,
            isOnline: isOnline
        )
    }
}
