import CoreGraphics
import Foundation
import UIKit

/// Curated high-craft procedural studio portrait swatches rendered directly via CoreGraphics
/// so users and Simulator XCUITests (e.g., Scenario S5) can deterministically pan, pinch/slider-zoom,
/// export pixel-accurate `512×512` avatars, and extract vibrant `dominantTintHex` palettes even without
/// camera roll assets.
public enum StudioAvatarPreset: String, CaseIterable, Identifiable, Sendable {
    case cobaltPrism
    case terracottaSun
    case emeraldMist
    case violetDusk
    case amberFilm
    case crimsonInk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cobaltPrism:   return "Cobalt"
        case .terracottaSun: return "Terracotta"
        case .emeraldMist:   return "Emerald"
        case .violetDusk:    return "Violet"
        case .amberFilm:     return "Amber"
        case .crimsonInk:    return "Crimson"
        }
    }

    /// Primary studio pigment (`r, g, b` in `0...255`) paired with secondary & highlight harmonic stops.
    public var paletteRGB: (primary: (Int, Int, Int), secondary: (Int, Int, Int), accent: (Int, Int, Int)) {
        switch self {
        case .cobaltPrism:
            return ((24, 119, 242), (14, 58, 152), (116, 192, 255))
        case .terracottaSun:
            return ((224, 102, 72), (148, 52, 42), (255, 196, 132))
        case .emeraldMist:
            return ((12, 168, 102), (10, 88, 66), (132, 236, 190))
        case .violetDusk:
            return ((118, 88, 248), (56, 36, 142), (204, 168, 255))
        case .amberFilm:
            return ((228, 148, 34), (138, 76, 18), (255, 222, 128))
        case .crimsonInk:
            return ((218, 48, 84), (112, 20, 46), (255, 146, 172))
        }
    }
}

/// Pixel-accurate circular `512×512` avatar cropper and wide `2.6:1` cover banner framing geometry & renderer.
///
/// Grounded in:
/// - Apple HIG: *Images* & *Gestures* (1:1 pan + focal-point pinch-to-zoom with rubberband-free edge clamping)
/// - Cuven Web Reference: `public/js/ui/framing.js` (`coverScale`, `clampFrame`, `frameBox`, `cropRect`, `zoomAbout`, `OUTPUT = 512`)
public enum AvatarCoverCropEngine: Sendable {
    /// Maximum pinch/slider zoom factor (`MAX_ZOOM = 4` in `framing.js:6`).
    public static let maxZoom: CGFloat = 4.0
    /// Canonical exported square avatar side in pixels (`OUTPUT = 512` in `framing.js:7`).
    public static let avatarOutputDimension: Int = 512
    /// Canonical exported wide profile cover banner dimensions (`~2.6:1` matching `.cv-band` in `avatar-editor.css:173`).
    public static let coverOutputSize = CGSize(width: 1200, height: 462)

    /// Scale at which an `imageWidth × imageHeight` photo just covers a circle of diameter `diameter`.
    public static func coverScale(imageWidth: CGFloat, imageHeight: CGFloat, diameter: CGFloat) -> CGFloat {
        guard imageWidth > 0, imageHeight > 0, diameter > 0 else { return 1.0 }
        return max(diameter / imageWidth, diameter / imageHeight)
    }

    /// Scale at which an `imageWidth × imageHeight` photo just covers a rectangular viewport `viewportSize`.
    public static func rectangularCoverScale(
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        viewportSize: CGSize
    ) -> CGFloat {
        guard imageWidth > 0, imageHeight > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return 1.0
        }
        return max(viewportSize.width / imageWidth, viewportSize.height / imageHeight)
    }

    // MARK: - Procedural CoreGraphics Studio Artwork & Demo URL Synthesis

    /// Synthesizes a multi-layered `dimension × dimension` (`768×768` default) studio artwork `CGImage`
    /// with rich gradient backdrops, geometric focal spheres, and off-center light arcs so zooming/panning
    /// visibly shifts composition and `DominantColorExtractor` samples real RGBA8 pixels.
    public static func renderStudioAvatarCGImage(
        preset: StudioAvatarPreset,
        dimension: Int = 768
    ) -> CGImage? {
        let side = max(64, dimension)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let s = CGFloat(side)
        let (pri, sec, acc) = preset.paletteRGB
        let cPrimary = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(pri.0) / 255.0, CGFloat(pri.1) / 255.0, CGFloat(pri.2) / 255.0, 1.0]
        ) ?? UIColor.systemBlue.cgColor
        let cSecondary = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(sec.0) / 255.0, CGFloat(sec.1) / 255.0, CGFloat(sec.2) / 255.0, 1.0]
        ) ?? UIColor.black.cgColor
        let cAccent = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(acc.0) / 255.0, CGFloat(acc.1) / 255.0, CGFloat(acc.2) / 255.0, 0.92]
        ) ?? UIColor.white.cgColor

        // 1. Diagonal gradient studio canvas
        if let bgGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [cPrimary, cSecondary] as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                bgGrad,
                start: CGPoint(x: 0, y: s),
                end: CGPoint(x: s, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 2. Luminous off-center studio sun / sphere
        context.saveGState()
        let orbRect = CGRect(x: s * 0.16, y: s * 0.24, width: s * 0.56, height: s * 0.56)
        context.addEllipse(in: orbRect)
        context.clip()
        if let orbGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [cAccent, cPrimary] as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawRadialGradient(
                orbGrad,
                startCenter: CGPoint(x: orbRect.midX - s * 0.06, y: orbRect.midY + s * 0.08),
                startRadius: s * 0.02,
                endCenter: CGPoint(x: orbRect.midX, y: orbRect.midY),
                endRadius: s * 0.34,
                options: [.drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        // 3. Crisp architectural horizon / prism arc for tactile pan & zoom feedback
        context.saveGState()
        context.setFillColor(cPrimary)
        let ribbon = CGMutablePath()
        ribbon.move(to: CGPoint(x: 0, y: 0))
        ribbon.addQuadCurve(
            to: CGPoint(x: s, y: s * 0.30),
            control: CGPoint(x: s * 0.48, y: s * 0.42)
        )
        ribbon.addLine(to: CGPoint(x: s, y: 0))
        ribbon.closeSubpath()
        context.addPath(ribbon)
        context.fillPath()
        context.restoreGState()

        return context.makeImage()
    }

    /// Maps `cuven-demo://avatar/<slug>` seed URLs (`DemoSeedFactory`) to distinct `768×768` studio `CGImage`s.
    public static func renderDemoAvatarCGImage(
        forURLString rawURLString: String,
        dimension: Int = 768
    ) -> CGImage? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("cuven-demo://avatar/") else { return nil }
        let slug = String(trimmed.dropFirst("cuven-demo://avatar/".count))
        let preset: StudioAvatarPreset
        switch slug {
        case "tokio":        preset = .cobaltPrism
        case "tokio_film":   preset = .amberFilm
        case "tokio_studio": preset = .terracottaSun
        case "tokio_sketch": preset = .emeraldMist
        case "tokio_mono":   preset = .violetDusk
        case "coisini":      preset = .terracottaSun
        case "hong":         preset = .emeraldMist
        case "gang":         preset = .amberFilm
        default:
            let hash = slug.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF }
            let all = StudioAvatarPreset.allCases
            preset = all[hash % all.count]
        }
        return renderStudioAvatarCGImage(preset: preset, dimension: dimension)
    }

    // MARK: - Normalizing Orientation & Rendering Pixel-Accurate Crops

    /// Redraws a `UIImage` with non-up EXIF orientation into a right-side-up `CGImage` before pixel cropping.
    public static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let pixelWidth = max(1, Int((image.size.width * image.scale).rounded()))
        let pixelHeight = max(1, Int((image.size.height * image.scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        )
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        return normalized.cgImage
    }

    /// Renders the exact square visible inside `frame` into a `512 × 512` (or custom `outputDimension`) `CGImage`.
    public static func cropAvatarCGImage(
        from sourceImage: CGImage,
        frame: CircularCropFrame,
        outputDimension: Int = avatarOutputDimension
    ) -> CGImage? {
        let side = max(1, outputDimension)
        let effectiveFrame = CircularCropFrame(
            imageWidth: CGFloat(sourceImage.width),
            imageHeight: CGFloat(sourceImage.height),
            viewportDiameter: frame.viewportDiameter > 0 ? frame.viewportDiameter : CGFloat(side),
            zoom: frame.zoom,
            offsetX: frame.offsetX,
            offsetY: frame.offsetY
        ).clamped()

        let crop = effectiveFrame.pixelCropSquare()
        guard crop.width > 0, crop.height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        let scale = CGFloat(side) / crop.width
        // Map source sub-rect `(crop.minX, crop.minY, crop.width, crop.height)` onto `(0, 0, side, side)`
        // Note: CoreGraphics bottom-left origin requires flipping Y relative to top-left crop coordinates.
        let fullW = CGFloat(sourceImage.width) * scale
        let fullH = CGFloat(sourceImage.height) * scale
        let drawX = -crop.minX * scale
        let drawY = -(CGFloat(sourceImage.height) - crop.maxY) * scale
        context.draw(sourceImage, in: CGRect(x: drawX, y: drawY, width: fullW, height: fullH))
        return context.makeImage()
    }

    /// Exports a framed `512 × 512` JPEG `Data` payload matching `avatar-editor.js:328-334` (`OUTPUT = 512`, quality `0.9`).
    public static func renderAvatar512JPEG(
        from sourceImage: CGImage,
        frame: CircularCropFrame,
        compressionQuality: CGFloat = 0.90
    ) -> Data? {
        guard let cropped = cropAvatarCGImage(
            from: sourceImage,
            frame: frame,
            outputDimension: avatarOutputDimension
        ) else {
            return nil
        }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: compressionQuality)
    }

    /// Renders the exact wide banner visible inside `frame` into `outputSize` (`1200 × 462` default).
    public static func cropCoverCGImage(
        from sourceImage: CGImage,
        frame: RectangularCropFrame,
        outputSize: CGSize = coverOutputSize
    ) -> CGImage? {
        let outW = max(1, Int(outputSize.width.rounded()))
        let outH = max(1, Int(outputSize.height.rounded()))
        let effectiveViewport = frame.viewportSize.width > 0 && frame.viewportSize.height > 0
            ? frame.viewportSize
            : CGSize(width: outW, height: outH)
        let effectiveFrame = RectangularCropFrame(
            imageWidth: CGFloat(sourceImage.width),
            imageHeight: CGFloat(sourceImage.height),
            viewportSize: effectiveViewport,
            zoom: frame.zoom,
            offsetX: frame.offsetX,
            offsetY: frame.offsetY
        ).clamped()

        let crop = effectiveFrame.pixelCropRect()
        guard crop.width > 0, crop.height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        let scaleX = CGFloat(outW) / crop.width
        let scaleY = CGFloat(outH) / crop.height
        let fullW = CGFloat(sourceImage.width) * scaleX
        let fullH = CGFloat(sourceImage.height) * scaleY
        let drawX = -crop.minX * scaleX
        let drawY = -(CGFloat(sourceImage.height) - crop.maxY) * scaleY
        context.draw(sourceImage, in: CGRect(x: drawX, y: drawY, width: fullW, height: fullH))
        return context.makeImage()
    }

    /// Exports a framed wide cover banner JPEG `Data` payload.
    public static func renderCoverBannerJPEG(
        from sourceImage: CGImage,
        frame: RectangularCropFrame,
        outputSize: CGSize = coverOutputSize,
        compressionQuality: CGFloat = 0.88
    ) -> Data? {
        guard let cropped = cropCoverCGImage(from: sourceImage, frame: frame, outputSize: outputSize) else {
            return nil
        }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: compressionQuality)
    }
}

// MARK: - Circular Avatar Framing State (`framing.js` 1:1 Parity)

public struct CircularCropFrame: Equatable, Sendable {
    public var imageWidth: CGFloat
    public var imageHeight: CGFloat
    public var viewportDiameter: CGFloat
    public var zoom: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat

    public init(
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        viewportDiameter: CGFloat,
        zoom: CGFloat = 1.0,
        offsetX: CGFloat = 0.0,
        offsetY: CGFloat = 0.0
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewportDiameter = viewportDiameter
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// Effective points-per-pixel scale (`coverScale * clampedZoom`).
    public var effectiveScale: CGFloat {
        let z = clampedZoom
        return AvatarCoverCropEngine.coverScale(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            diameter: viewportDiameter
        ) * z
    }

    private var clampedZoom: CGFloat {
        guard zoom.isFinite else { return 1.0 }
        return min(AvatarCoverCropEngine.maxZoom, max(1.0, zoom))
    }

    /// Clamps `zoom` to `[1, 4]` and offsets so the image never leaves an empty gap inside the circle.
    public func clamped() -> CircularCropFrame {
        let z = clampedZoom
        let scale = AvatarCoverCropEngine.coverScale(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            diameter: viewportDiameter
        ) * z
        let maxX = max(0, (imageWidth * scale - viewportDiameter) / 2.0)
        let maxY = max(0, (imageHeight * scale - viewportDiameter) / 2.0)
        let safeX = offsetX.isFinite ? min(maxX, max(-maxX, offsetX)) : 0
        let safeY = offsetY.isFinite ? min(maxY, max(-maxY, offsetY)) : 0
        return CircularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportDiameter: viewportDiameter,
            zoom: z,
            offsetX: safeX,
            offsetY: safeY
        )
    }

    /// Rescales offsets proportionally when the preview circle diameter changes on rotation/unfold.
    public func resized(toDiameter newDiameter: CGFloat) -> CircularCropFrame {
        guard newDiameter > 0 else { return self }
        let ratio = viewportDiameter > 0 ? (newDiameter / viewportDiameter) : 1.0
        return CircularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportDiameter: newDiameter,
            zoom: zoom,
            offsetX: offsetX * ratio,
            offsetY: offsetY * ratio
        ).clamped()
    }

    /// Where the photo is drawn inside the circle viewport (`frameBox` in `framing.js:27-32`).
    public func displayRect() -> CGRect {
        let f = clamped()
        let scale = f.effectiveScale
        let width = f.imageWidth * scale
        let height = f.imageHeight * scale
        let left = (f.viewportDiameter - width) / 2.0 + f.offsetX
        let top = (f.viewportDiameter - height) / 2.0 + f.offsetY
        return CGRect(x: left, y: top, width: width, height: height)
    }

    /// Square crop region in source image pixels (`cropRect` in `framing.js:35-43`).
    public func pixelCropSquare() -> CGRect {
        let f = clamped()
        let scale = max(0.0001, f.effectiveScale)
        let rawSize = f.viewportDiameter / scale
        let size = min(rawSize, f.imageWidth, f.imageHeight)
        let sx = max(0, min(f.imageWidth - size, ((f.imageWidth * scale - f.viewportDiameter) / 2.0 - f.offsetX) / scale))
        let sy = max(0, min(f.imageHeight - size, ((f.imageHeight * scale - f.viewportDiameter) / 2.0 - f.offsetY) / scale))
        return CGRect(x: sx, y: sy, width: size, height: size)
    }

    /// Zooms about `anchorFromCenter` (offset from circle center in points), keeping that exact photo pixel stationary.
    public func zooming(to nextZoom: CGFloat, anchorFromCenter: CGPoint = .zero) -> CircularCropFrame {
        let before = clamped()
        let afterUnshifted = CircularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportDiameter: viewportDiameter,
            zoom: nextZoom,
            offsetX: before.offsetX,
            offsetY: before.offsetY
        ).clamped()
        let ratio = before.effectiveScale > 0 ? (afterUnshifted.effectiveScale / before.effectiveScale) : 1.0
        let newX = anchorFromCenter.x - (anchorFromCenter.x - before.offsetX) * ratio
        let newY = anchorFromCenter.y - (anchorFromCenter.y - before.offsetY) * ratio
        return CircularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportDiameter: viewportDiameter,
            zoom: afterUnshifted.zoom,
            offsetX: newX,
            offsetY: newY
        ).clamped()
    }

    /// Pans the image by `delta` points and clamps within circle coverage bounds.
    public func panning(by delta: CGSize) -> CircularCropFrame {
        CircularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportDiameter: viewportDiameter,
            zoom: zoom,
            offsetX: offsetX + delta.width,
            offsetY: offsetY + delta.height
        ).clamped()
    }
}

// MARK: - Wide Cover Banner Framing State

public struct RectangularCropFrame: Equatable, Sendable {
    public var imageWidth: CGFloat
    public var imageHeight: CGFloat
    public var viewportSize: CGSize
    public var zoom: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat

    public init(
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        viewportSize: CGSize,
        zoom: CGFloat = 1.0,
        offsetX: CGFloat = 0.0,
        offsetY: CGFloat = 0.0
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewportSize = viewportSize
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public var effectiveScale: CGFloat {
        let z = zoom.isFinite ? min(AvatarCoverCropEngine.maxZoom, max(1.0, zoom)) : 1.0
        return AvatarCoverCropEngine.rectangularCoverScale(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize
        ) * z
    }

    public func clamped() -> RectangularCropFrame {
        let z = zoom.isFinite ? min(AvatarCoverCropEngine.maxZoom, max(1.0, zoom)) : 1.0
        let scale = AvatarCoverCropEngine.rectangularCoverScale(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize
        ) * z
        let maxX = max(0, (imageWidth * scale - viewportSize.width) / 2.0)
        let maxY = max(0, (imageHeight * scale - viewportSize.height) / 2.0)
        let safeX = offsetX.isFinite ? min(maxX, max(-maxX, offsetX)) : 0
        let safeY = offsetY.isFinite ? min(maxY, max(-maxY, offsetY)) : 0
        return RectangularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize,
            zoom: z,
            offsetX: safeX,
            offsetY: safeY
        )
    }

    public func displayRect() -> CGRect {
        let f = clamped()
        let scale = f.effectiveScale
        let width = f.imageWidth * scale
        let height = f.imageHeight * scale
        return CGRect(
            x: (f.viewportSize.width - width) / 2.0 + f.offsetX,
            y: (f.viewportSize.height - height) / 2.0 + f.offsetY,
            width: width,
            height: height
        )
    }

    public func pixelCropRect() -> CGRect {
        let f = clamped()
        let scale = max(0.0001, f.effectiveScale)
        let cropW = min(f.imageWidth, f.viewportSize.width / scale)
        let cropH = min(f.imageHeight, f.viewportSize.height / scale)
        let sx = max(0, min(f.imageWidth - cropW, ((f.imageWidth * scale - f.viewportSize.width) / 2.0 - f.offsetX) / scale))
        let sy = max(0, min(f.imageHeight - cropH, ((f.imageHeight * scale - f.viewportSize.height) / 2.0 - f.offsetY) / scale))
        return CGRect(x: sx, y: sy, width: cropW, height: cropH)
    }

    public func zooming(to nextZoom: CGFloat, anchorFromCenter: CGPoint = .zero) -> RectangularCropFrame {
        let before = clamped()
        let afterUnshifted = RectangularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize,
            zoom: nextZoom,
            offsetX: before.offsetX,
            offsetY: before.offsetY
        ).clamped()
        let ratio = before.effectiveScale > 0 ? (afterUnshifted.effectiveScale / before.effectiveScale) : 1.0
        let newX = anchorFromCenter.x - (anchorFromCenter.x - before.offsetX) * ratio
        let newY = anchorFromCenter.y - (anchorFromCenter.y - before.offsetY) * ratio
        return RectangularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize,
            zoom: afterUnshifted.zoom,
            offsetX: newX,
            offsetY: newY
        ).clamped()
    }

    public func panning(by delta: CGSize) -> RectangularCropFrame {
        RectangularCropFrame(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewportSize: viewportSize,
            zoom: zoom,
            offsetX: offsetX + delta.width,
            offsetY: offsetY + delta.height
        ).clamped()
    }
}
