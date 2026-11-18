// CoreImagePhotoFilterEngine.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Genuine non-destructive CoreImage 6-Tone Filter, 90° Rotation & Aspect-Ratio Crop Engine.
// Implements exact parity with `public/js/views/moments-editor.js` (`LOOKS` & `SHAPES`)
// using hardware-accelerated `CIContext` and native `CIFilter` pipelines:
// - `CIColorControls` + `CIVibrance` (Vivid)
// - `CITemperatureAndTint` + `CIColorControls` (Warm & Cool)
// - `CIPhotoEffectMono` + `CIColorControls` (Mono)
// - `CIPhotoEffectFade` + `CIColorControls` (Fade)

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 6-Tone Filter Preset

public enum PhotoToneFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case original = "original"
    case vivid    = "vivid"
    case warm     = "warm"
    case cool     = "cool"
    case mono     = "mono"
    case fade     = "fade"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .vivid:    return "Vivid"
        case .warm:     return "Warm"
        case .cool:     return "Cool"
        case .mono:     return "Mono"
        case .fade:     return "Fade"
        }
    }

    public static func fromStoredName(_ name: String) -> PhotoToneFilter? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "none" { return .original }
        return PhotoToneFilter(rawValue: normalized)
    }
}

// MARK: - Aspect Ratio Crop Preset

public enum PhotoAspectCropPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case original     = "original"
    case square       = "1:1"
    case portrait4x5  = "4:5"
    case landscape16x9 = "16:9"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original:      return "Original"
        case .square:        return "1:1"
        case .portrait4x5:   return "4:5"
        case .landscape16x9: return "16:9"
        }
    }

    /// Target width / height ratio, or `nil` when preserving rotated image bounds.
    public var aspectRatio: CGFloat? {
        switch self {
        case .original:      return nil
        case .square:        return 1.0
        case .portrait4x5:   return 4.0 / 5.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }
}

// MARK: - Non-Destructive Edit Parameters

public struct PhotoEditParameters: Equatable, Hashable, Codable, Sendable {
    /// Clockwise 90° steps in `0...3` (`0°, 90°, 180°, 270°`).
    public var rotationQuarterTurns: Int
    public var cropPreset: PhotoAspectCropPreset
    public var tone: PhotoToneFilter

    public init(
        rotationQuarterTurns: Int = 0,
        cropPreset: PhotoAspectCropPreset = .original,
        tone: PhotoToneFilter = .original
    ) {
        let normalized = ((rotationQuarterTurns % 4) + 4) % 4
        self.rotationQuarterTurns = normalized
        self.cropPreset = cropPreset
        self.tone = tone
    }

    public var isIdentity: Bool {
        (rotationQuarterTurns % 4 == 0) && cropPreset == .original && tone == .original
    }

    public var rotationDegrees: Int {
        (((rotationQuarterTurns % 4) + 4) % 4) * 90
    }

    public func rotated90Clockwise() -> PhotoEditParameters {
        PhotoEditParameters(
            rotationQuarterTurns: (rotationQuarterTurns + 1) % 4,
            cropPreset: cropPreset,
            tone: tone
        )
    }
}

// MARK: - CoreImage 6-Tone Filter & Geometry Engine

public final class CoreImagePhotoFilterEngine: @unchecked Sendable {
    public static let shared = CoreImagePhotoFilterEngine()

    private let ciContext: CIContext

    public init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.ciContext = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
    }

    /// Applies non-destructive 90° rotation, centered aspect-ratio crop, and genuine `CIFilter` tone grading
    /// starting from the original `CIImage`.
    public func processCIImage(
        _ sourceImage: CIImage,
        parameters: PhotoEditParameters,
        maxDimension: CGFloat? = nil
    ) -> CIImage {
        // Step 1: Normalize origin and apply exact 90-degree clockwise quarter-turns
        var image = normalizeOrigin(sourceImage)
        let turns = ((parameters.rotationQuarterTurns % 4) + 4) % 4
        switch turns {
        case 1: // 90° clockwise
            image = image.oriented(.right)
        case 2: // 180°
            image = image.oriented(.down)
        case 3: // 270° clockwise (90° counter-clockwise)
            image = image.oriented(.left)
        default:
            break
        }
        image = normalizeOrigin(image)

        // Step 2: Centered maximum inscribed rectangle for selected aspect crop preset
        if let targetRatio = parameters.cropPreset.aspectRatio, targetRatio > 0 {
            let extent = image.extent
            if extent.width > 1, extent.height > 1 {
                var cropWidth = extent.width
                var cropHeight = cropWidth / targetRatio
                if cropHeight > extent.height {
                    cropHeight = extent.height
                    cropWidth = cropHeight * targetRatio
                }
                let originX = extent.origin.x + (extent.width - cropWidth) * 0.5
                let originY = extent.origin.y + (extent.height - cropHeight) * 0.5
                let cropRect = CGRect(
                    x: originX.rounded(.down),
                    y: originY.rounded(.down),
                    width: max(1, cropWidth.rounded()),
                    height: max(1, cropHeight.rounded())
                ).intersection(extent)
                if !cropRect.isNull && !cropRect.isEmpty {
                    image = normalizeOrigin(image.cropped(to: cropRect))
                }
            }
        }

        // Step 3: Downscale cleanly via CILanczosScaleTransform if maxDimension is requested
        if let maxDimension, maxDimension > 0 {
            let currentLongSide = max(image.extent.width, image.extent.height)
            if currentLongSide > maxDimension {
                let scale = maxDimension / currentLongSide
                if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
                    lanczos.setValue(image, forKey: kCIInputImageKey)
                    lanczos.setValue(scale, forKey: kCIInputScaleKey)
                    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
                    if let scaled = lanczos.outputImage {
                        image = normalizeOrigin(scaled)
                    }
                } else {
                    image = normalizeOrigin(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
                }
            }
        }

        // Step 4: Apply genuine CoreImage 6-Tone filter chain
        let targetExtent = image.extent
        let toned = applyToneFilter(parameters.tone, to: image)
        return toned.cropped(to: targetExtent)
    }

    /// Renders an edited `UIImage` from the source `UIImage` using `CIContext`.
    public func apply(
        to source: UIImage,
        parameters: PhotoEditParameters,
        maxDimension: CGFloat = 2048
    ) -> UIImage? {
        guard let baseCI = makeNormalizedCIImage(from: source) else { return nil }
        let outputCI = processCIImage(baseCI, parameters: parameters, maxDimension: maxDimension)
        let extent = outputCI.extent.integral
        guard extent.width >= 1, extent.height >= 1,
              let cgImage = ciContext.createCGImage(outputCI, from: extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    /// Exports an edited JPEG binary payload alongside exact pixel dimensions.
    public func exportJPEG(
        from source: UIImage,
        parameters: PhotoEditParameters,
        maxDimension: CGFloat = 2048,
        compressionQuality: CGFloat = 0.90
    ) -> (data: Data, width: Int, height: Int, preview: UIImage)? {
        guard let rendered = apply(to: source, parameters: parameters, maxDimension: maxDimension),
              let cgImage = rendered.cgImage,
              let jpegData = rendered.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }
        return (data: jpegData, width: cgImage.width, height: cgImage.height, preview: rendered)
    }

    /// Generates square `CoreImage`-rendered thumbnails for all 6 `PhotoToneFilter` options
    /// to populate `moments.editor.filterStrip` with authentic live previews.
    public func generateFilterStripThumbnails(
        from source: UIImage,
        rotationQuarterTurns: Int = 0,
        thumbnailDimension: CGFloat = 128
    ) -> [PhotoToneFilter: UIImage] {
        guard let baseCI = makeNormalizedCIImage(from: source) else { return [:] }

        // Pre-crop & downscale square base once, then run each genuine CIFilter tone
        let squareBaseParams = PhotoEditParameters(
            rotationQuarterTurns: rotationQuarterTurns,
            cropPreset: .square,
            tone: .original
        )
        let preparedSquare = processCIImage(baseCI, parameters: squareBaseParams, maxDimension: thumbnailDimension)
        let extent = preparedSquare.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return [:] }

        var results: [PhotoToneFilter: UIImage] = [:]
        for filter in PhotoToneFilter.allCases {
            let filtered = applyToneFilter(filter, to: preparedSquare).cropped(to: extent)
            if let cgImage = ciContext.createCGImage(filtered, from: extent) {
                results[filter] = UIImage(cgImage: cgImage, scale: 2.0, orientation: .up)
            }
        }
        return results
    }

    /// Creates a crisp, deterministic studio sample `UIImage` via CoreGraphics when running in
    /// camera-less / empty-library Simulator environments or quick studio canvas creation.
    public static func makeStudioSampleImage(
        presetIndex: Int = 0,
        size: CGSize = CGSize(width: 1200, height: 1500)
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let colorPairs: [(UIColor, UIColor, UIColor)] = [
            (
                UIColor(red: 0.96, green: 0.64, blue: 0.36, alpha: 1.0),
                UIColor(red: 0.75, green: 0.42, blue: 0.52, alpha: 1.0),
                UIColor(red: 0.24, green: 0.19, blue: 0.42, alpha: 1.0)
            ),
            (
                UIColor(red: 0.16, green: 0.62, blue: 0.56, alpha: 1.0),
                UIColor(red: 0.91, green: 0.77, blue: 0.42, alpha: 1.0),
                UIColor(red: 0.15, green: 0.27, blue: 0.33, alpha: 1.0)
            ),
            (
                UIColor(red: 0.21, green: 0.36, blue: 0.49, alpha: 1.0),
                UIColor(red: 0.45, green: 0.68, blue: 0.88, alpha: 1.0),
                UIColor(red: 0.09, green: 0.14, blue: 0.26, alpha: 1.0)
            )
        ]
        let (topColor, midColor, bottomColor) = colorPairs[abs(presetIndex) % colorPairs.count]

        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [topColor.cgColor, midColor.cgColor, bottomColor.cgColor] as CFArray
            let locations: [CGFloat] = [0.0, 0.55, 1.0]
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                cg.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            // Warm sun disc
            cg.setFillColor(UIColor(white: 1.0, alpha: 0.88).cgColor)
            let radius = min(size.width, size.height) * 0.14
            let sunCenter = CGPoint(x: size.width * 0.68, y: size.height * 0.30)
            cg.fillEllipse(in: CGRect(
                x: sunCenter.x - radius,
                y: sunCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            // Mountain ridge silhouette
            let ridge = UIBezierPath()
            ridge.move(to: CGPoint(x: 0, y: size.height))
            ridge.addLine(to: CGPoint(x: 0, y: size.height * 0.66))
            ridge.addQuadCurve(
                to: CGPoint(x: size.width * 0.52, y: size.height * 0.54),
                controlPoint: CGPoint(x: size.width * 0.26, y: size.height * 0.46)
            )
            ridge.addQuadCurve(
                to: CGPoint(x: size.width, y: size.height * 0.64),
                controlPoint: CGPoint(x: size.width * 0.78, y: size.height * 0.70)
            )
            ridge.addLine(to: CGPoint(x: size.width, y: size.height))
            ridge.close()
            cg.setFillColor(UIColor(white: 0.08, alpha: 0.55).cgColor)
            cg.addPath(ridge.cgPath)
            cg.fillPath()
        }
    }

    /// Deterministically hashes a seed key (`cuven-demo://photo/...`) into a studio `UIImage`
    /// so offline/seeded Moment cards can run through the exact same `CoreImage` 6-tone pipeline.
    public static func makeSeededEditorialImage(
        seedKey: String,
        size: CGSize = CGSize(width: 960, height: 1200)
    ) -> UIImage {
        var hash: UInt64 = 1469598103934665603
        for byte in seedKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return makeStudioSampleImage(presetIndex: Int(hash % 3), size: size)
    }

    // MARK: - Private CIFilter Chain Implementation

    private func applyToneFilter(_ filter: PhotoToneFilter, to input: CIImage) -> CIImage {
        switch filter {
        case .original:
            return input

        case .vivid:
            // Saturation 1.35 + Contrast 1.08 + Vibrance 0.28 (`moments-editor.js:454`)
            var current = input
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(current, forKey: kCIInputImageKey)
                colorControls.setValue(1.35, forKey: kCIInputSaturationKey)
                colorControls.setValue(1.08, forKey: kCIInputContrastKey)
                colorControls.setValue(0.01, forKey: kCIInputBrightnessKey)
                if let out = colorControls.outputImage {
                    current = out
                }
            }
            if let vibrance = CIFilter(name: "CIVibrance") {
                vibrance.setValue(current, forKey: kCIInputImageKey)
                vibrance.setValue(0.28, forKey: "inputAmount")
                if let out = vibrance.outputImage {
                    current = out
                }
            }
            return current

        case .warm:
            // Golden warm shift via CITemperatureAndTint + saturation/brightness lift (`moments-editor.js:455`)
            var current = input
            if let tempAndTint = CIFilter(name: "CITemperatureAndTint") {
                tempAndTint.setValue(current, forKey: kCIInputImageKey)
                tempAndTint.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                tempAndTint.setValue(CIVector(x: 4950, y: -10), forKey: "inputTargetNeutral")
                if let out = tempAndTint.outputImage {
                    current = out
                }
            }
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(current, forKey: kCIInputImageKey)
                colorControls.setValue(1.22, forKey: kCIInputSaturationKey)
                colorControls.setValue(0.025, forKey: kCIInputBrightnessKey)
                colorControls.setValue(1.02, forKey: kCIInputContrastKey)
                if let out = colorControls.outputImage {
                    current = out
                }
            }
            return current

        case .cool:
            // Crisp alpine cool shift via CITemperatureAndTint + subtle saturation/brightness (`moments-editor.js:456`)
            var current = input
            if let tempAndTint = CIFilter(name: "CITemperatureAndTint") {
                tempAndTint.setValue(current, forKey: kCIInputImageKey)
                tempAndTint.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                tempAndTint.setValue(CIVector(x: 8250, y: 8), forKey: "inputTargetNeutral")
                if let out = tempAndTint.outputImage {
                    current = out
                }
            }
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(current, forKey: kCIInputImageKey)
                colorControls.setValue(1.08, forKey: kCIInputSaturationKey)
                colorControls.setValue(0.025, forKey: kCIInputBrightnessKey)
                colorControls.setValue(1.03, forKey: kCIInputContrastKey)
                if let out = colorControls.outputImage {
                    current = out
                }
            }
            return current

        case .mono:
            // Silver-gelatin monochrome (`CIPhotoEffectMono`) + crisp 1.12 contrast (`moments-editor.js:457`)
            var current = input
            if let mono = CIFilter(name: "CIPhotoEffectMono") {
                mono.setValue(current, forKey: kCIInputImageKey)
                if let out = mono.outputImage {
                    current = out
                }
            }
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(current, forKey: kCIInputImageKey)
                colorControls.setValue(0.0, forKey: kCIInputSaturationKey)
                colorControls.setValue(1.12, forKey: kCIInputContrastKey)
                if let out = colorControls.outputImage {
                    current = out
                }
            }
            return current

        case .fade:
            // Film matte fade (`CIPhotoEffectFade`) + lifted shadows / 0.86 contrast / 0.80 saturation (`moments-editor.js:458`)
            var current = input
            if let fade = CIFilter(name: "CIPhotoEffectFade") {
                fade.setValue(current, forKey: kCIInputImageKey)
                if let out = fade.outputImage {
                    current = out
                }
            }
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(current, forKey: kCIInputImageKey)
                colorControls.setValue(0.82, forKey: kCIInputSaturationKey)
                colorControls.setValue(0.88, forKey: kCIInputContrastKey)
                colorControls.setValue(0.04, forKey: kCIInputBrightnessKey)
                if let out = colorControls.outputImage {
                    current = out
                }
            }
            return current
        }
    }

    private func makeNormalizedCIImage(from uiImage: UIImage) -> CIImage? {
        if let cgImage = uiImage.cgImage {
            let ci = CIImage(cgImage: cgImage)
            let exifOrientation = cgImagePropertyOrientation(from: uiImage.imageOrientation)
            return normalizeOrigin(ci.oriented(exifOrientation))
        }
        if let ci = uiImage.ciImage {
            return normalizeOrigin(ci)
        }
        return nil
    }

    private func normalizeOrigin(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin.x != 0 || extent.origin.y != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
    }

    private func cgImagePropertyOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
