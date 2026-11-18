import CoreGraphics
import CoreImage
import Foundation
import SwiftUI
import UIKit

/// Extracted color palette from a user's profile avatar or cover image.
///
/// Grounded in:
/// - Apple HIG: *Color* & *Materials / Liquid Glass* (adaptive light/dark surface legibility)
/// - Apple Developer Documentation: `CoreImage` (`CIAreaAverage`) & `CoreGraphics` RGBA8 bitmap sampling
/// - Cuven Web Reference: `public/js/views/avatar-editor.js` (`averageColour`) & `public/js/ui/framing.js` (`tintOf`, `hsl`)
public struct ExtractedColorPalette: Equatable, Hashable, Sendable {
    /// Vibrant accent color in `#RRGGBB` format suitable for profile tint rings and badges.
    public let dominantTintHex: String
    /// Hardware/pixel area-average color in `#RRGGBB` format.
    public let averageHex: String
    /// Quietened light-mode sheet background wash (`hsl(h, min(s, 30)%, 80%)`) in `#RRGGBB`.
    public let sheetLightHex: String
    /// Quietened dark-mode sheet background shade (`hsl(h, min(s, 22)%, 17%)`) in `#RRGGBB`.
    public let sheetDarkHex: String
    /// Dominant hue angle in degrees (`0...360`).
    public let hueDegrees: Double
    /// Dominant HSV saturation (`0...1`).
    public let saturation: Double
    /// Dominant HSV value/brightness (`0...1`).
    public let brightness: Double

    public init(
        dominantTintHex: String,
        averageHex: String,
        sheetLightHex: String,
        sheetDarkHex: String,
        hueDegrees: Double,
        saturation: Double,
        brightness: Double
    ) {
        self.dominantTintHex = dominantTintHex
        self.averageHex = averageHex
        self.sheetLightHex = sheetLightHex
        self.sheetDarkHex = sheetDarkHex
        self.hueDegrees = hueDegrees
        self.saturation = saturation
        self.brightness = brightness
    }

    public static let neutralDefault = ExtractedColorPalette(
        dominantTintHex: "#1877F2",
        averageHex: "#8E8E93",
        sheetLightHex: "#CCCCCC",
        sheetDarkHex: "#2B2B2B",
        hueDegrees: 214,
        saturation: 0.0,
        brightness: 0.56
    )
}

/// Genuine pixel-sampling dominant color & sheet-tint extractor using both CoreImage `CIAreaAverage`
/// and a quantized 36-bin HSV vibrancy histogram over downsampled `CGImage` pixels.
public enum DominantColorExtractor: Sendable {
    private static let sampleDimension = 64
    private static let hueBinCount = 36

    private struct HueBucket {
        var weightSum: Double = 0
        var weightedRed: Double = 0
        var weightedGreen: Double = 0
        var weightedBlue: Double = 0
        var weightedSat: Double = 0
        var weightedVal: Double = 0
    }

    /// Extracts a full `ExtractedColorPalette` from raw encoded image `Data`.
    public static func extract(from imageData: Data) -> ExtractedColorPalette? {
        guard let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage ?? ciBackedCGImage(from: uiImage) else {
            return nil
        }
        return extract(from: cgImage)
    }

    /// Extracts a full `ExtractedColorPalette` from a `UIImage`.
    public static func extract(from uiImage: UIImage) -> ExtractedColorPalette? {
        guard let cgImage = uiImage.cgImage ?? ciBackedCGImage(from: uiImage) else {
            return nil
        }
        return extract(from: cgImage)
    }

    /// Extracts a full `ExtractedColorPalette` from a `CGImage` by combining `CIAreaAverage`
    /// with a quantized 36-hue HSV vibrancy histogram over an RGBA8 bitmap sample.
    public static func extract(from cgImage: CGImage) -> ExtractedColorPalette {
        let width = max(1, min(sampleDimension, cgImage.width))
        let height = max(1, min(sampleDimension, cgImage.height))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rawPixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        var drewBitmap = false
        rawPixels.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return
            }
            context.interpolationQuality = .medium
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            drewBitmap = true
        }

        // 1. Hardware/CoreImage CIAreaAverage pass (with direct pixel-mean fallback if needed)
        let ciAverage = areaAverageRGB(from: cgImage)

        guard drewBitmap else {
            let fallback = ciAverage ?? (142, 142, 147)
            return buildPaletteFromSingleRGB(r: fallback.0, g: fallback.1, b: fallback.2)
        }

        // 2. Quantized 36-bin HSV histogram + unpremultiplied opaque pixel mean
        var buckets = Array(repeating: HueBucket(), count: hueBinCount)
        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var opaqueCount: Int = 0
        var maxObservedSaturation: Double = 0

        let pixelCount = width * height
        for idx in 0..<pixelCount {
            let offset = idx * bytesPerPixel
            let alpha = rawPixels[offset + 3]
            // Match avatar-editor.js:35: ignore mostly-transparent pixels (`alpha < 128`)
            if alpha < 128 { continue }

            let alphaScale = 255.0 / Double(alpha)
            let r255 = min(255.0, Double(rawPixels[offset]) * alphaScale)
            let g255 = min(255.0, Double(rawPixels[offset + 1]) * alphaScale)
            let b255 = min(255.0, Double(rawPixels[offset + 2]) * alphaScale)

            sumR += r255
            sumG += g255
            sumB += b255
            opaqueCount += 1

            let rNorm = r255 / 255.0
            let gNorm = g255 / 255.0
            let bNorm = b255 / 255.0
            let (hue, sat, val) = rgbToHSV(r: rNorm, g: gNorm, b: bNorm)
            if sat > maxObservedSaturation {
                maxObservedSaturation = sat
            }

            // Skip near-achromatic, blown-out white, or pitch-black pixels when scoring vibrant accent bins
            guard sat >= 0.08, val >= 0.08, !(val > 0.96 && sat < 0.14) else {
                continue
            }

            // Weight favors genuinely saturated, well-lit midtone/vibrant regions
            let chromaScore = pow(sat, 1.35)
            let valueBalance = max(0.15, 1.0 - abs(val - 0.62) * 0.65)
            let weight = chromaScore * valueBalance

            let binIndex = min(hueBinCount - 1, max(0, Int((hue / 360.0) * Double(hueBinCount))))
            buckets[binIndex].weightSum += weight
            buckets[binIndex].weightedRed += rNorm * weight
            buckets[binIndex].weightedGreen += gNorm * weight
            buckets[binIndex].weightedBlue += bNorm * weight
            buckets[binIndex].weightedSat += sat * weight
            buckets[binIndex].weightedVal += val * weight
        }

        guard opaqueCount > 0 else {
            if let ciAverage {
                return buildPaletteFromSingleRGB(r: ciAverage.0, g: ciAverage.1, b: ciAverage.2)
            }
            return .neutralDefault
        }

        let pixelAvgR = Int((sumR / Double(opaqueCount)).rounded())
        let pixelAvgG = Int((sumG / Double(opaqueCount)).rounded())
        let pixelAvgB = Int((sumB / Double(opaqueCount)).rounded())

        // Blend CoreImage CIAreaAverage with opaque-filtered bitmap average when CIAreaAverage succeeded
        let avgR: Int
        let avgG: Int
        let avgB: Int
        if let ciAverage {
            avgR = clampByte(Int((Double(ciAverage.0) * 0.5 + Double(pixelAvgR) * 0.5).rounded()))
            avgG = clampByte(Int((Double(ciAverage.1) * 0.5 + Double(pixelAvgG) * 0.5).rounded()))
            avgB = clampByte(Int((Double(ciAverage.2) * 0.5 + Double(pixelAvgB) * 0.5).rounded()))
        } else {
            avgR = clampByte(pixelAvgR)
            avgG = clampByte(pixelAvgG)
            avgB = clampByte(pixelAvgB)
        }

        let averageHex = hexString(r: avgR, g: avgG, b: avgB)

        // Smooth 3-neighbor circular window over the 36 hue bins so hues straddling a 10° boundary win cleanly
        var bestBin = -1
        var bestWindowScore: Double = 0
        for i in 0..<hueBinCount {
            let prev = buckets[(i + hueBinCount - 1) % hueBinCount].weightSum * 0.25
            let curr = buckets[i].weightSum
            let next = buckets[(i + 1) % hueBinCount].weightSum * 0.25
            let windowScore = prev + curr + next
            if buckets[i].weightSum > 0 && windowScore > bestWindowScore {
                bestWindowScore = windowScore
                bestBin = i
            }
        }

        // Achromatic / grayscale image: keep neutral tones without inventing a false hue (`framing.test.js:62`)
        if bestBin < 0 || maxObservedSaturation < 0.08 {
            let (h, s, _) = rgbToHSL(r: avgR, g: avgG, b: avgB)
            let (_, _, v) = rgbToHSV(r: Double(avgR) / 255.0, g: Double(avgG) / 255.0, b: Double(avgB) / 255.0)
            let lightHex = sheetTintHex(r: avgR, g: avgG, b: avgB, isDark: false)
            let darkHex = sheetTintHex(r: avgR, g: avgG, b: avgB, isDark: true)
            return ExtractedColorPalette(
                dominantTintHex: averageHex,
                averageHex: averageHex,
                sheetLightHex: lightHex,
                sheetDarkHex: darkHex,
                hueDegrees: Double(h),
                saturation: s,
                brightness: v
            )
        }

        let winner = buckets[bestBin]
        let rawWinR = winner.weightedRed / winner.weightSum
        let rawWinG = winner.weightedGreen / winner.weightSum
        let rawWinB = winner.weightedBlue / winner.weightSum
        let winByteR = clampByte(Int((rawWinR * 255.0).rounded()))
        let winByteG = clampByte(Int((rawWinG * 255.0).rounded()))
        let winByteB = clampByte(Int((rawWinB * 255.0).rounded()))

        // Normalize vibrant accent lightness into [0.38, 0.62] and saturation >= 0.45 for crisp UI accent contrast
        let (winHueInt, winHSLSat, winHSLLight) = rgbToHSL(r: winByteR, g: winByteG, b: winByteB)
        let accentSat = min(0.92, max(0.45, winHSLSat))
        let accentLight = min(0.58, max(0.38, winHSLLight))
        let (accR, accG, accB) = hslToRGB(h: Double(winHueInt), s: accentSat, l: accentLight)
        let dominantHex = hexString(r: accR, g: accG, b: accB)

        // Sheet background wash uses the dominant hue with Cuven's exact `tintOf` quietening formula
        let lightSheetHex = sheetTintHex(r: winByteR, g: winByteG, b: winByteB, isDark: false)
        let darkSheetHex = sheetTintHex(r: winByteR, g: winByteG, b: winByteB, isDark: true)
        let (hsvH, hsvS, hsvV) = rgbToHSV(r: rawWinR, g: rawWinG, b: rawWinB)

        return ExtractedColorPalette(
            dominantTintHex: dominantHex,
            averageHex: averageHex,
            sheetLightHex: lightSheetHex,
            sheetDarkHex: darkSheetHex,
            hueDegrees: hsvH,
            saturation: hsvS,
            brightness: hsvV
        )
    }

    // MARK: - CoreImage CIAreaAverage Pass

    private static func areaAverageRGB(from cgImage: CGImage) -> (Int, Int, Int)? {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard !extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage") else {
            return nil
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        guard pixel[3] >= 32 else { return nil }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private static func ciBackedCGImage(from uiImage: UIImage) -> CGImage? {
        guard let ciImage = uiImage.ciImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private static func buildPaletteFromSingleRGB(r: Int, g: Int, b: Int) -> ExtractedColorPalette {
        let hex = hexString(r: r, g: g, b: b)
        let (h, _, _) = rgbToHSL(r: r, g: g, b: b)
        let (_, s, v) = rgbToHSV(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)
        return ExtractedColorPalette(
            dominantTintHex: hex,
            averageHex: hex,
            sheetLightHex: sheetTintHex(r: r, g: g, b: b, isDark: false),
            sheetDarkHex: sheetTintHex(r: r, g: g, b: b, isDark: true),
            hueDegrees: Double(h),
            saturation: s,
            brightness: v
        )
    }

    // MARK: - Exact Cuven Web `framing.js` Color Math (`hsl` & `tintOf`)

    /// Exact port of `hsl(r, g, b)` from `public/js/ui/framing.js:69-77`.
    /// Returns `(hue: 0...360, saturation: 0...1, lightness: 0...1)`.
    public static func rgbToHSL(r: Int, g: Int, b: Int) -> (hue: Int, saturation: Double, lightness: Double) {
        let R = min(255.0, max(0.0, Double(r))) / 255.0
        let G = min(255.0, max(0.0, Double(g))) / 255.0
        let B = min(255.0, max(0.0, Double(b))) / 255.0
        let maxC = max(R, G, B)
        let minC = min(R, G, B)
        let l = (maxC + minC) / 2.0
        if maxC == minC {
            return (0, 0.0, l)
        }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
        let h: Double
        if maxC == R {
            h = (G - B) / d + (G < B ? 6.0 : 0.0)
        } else if maxC == G {
            h = (B - R) / d + 2.0
        } else {
            h = (R - G) / d + 4.0
        }
        return (Int((h * 60.0).rounded()) % 360, s, l)
    }

    /// Exact port of `tintOf(r, g, b, dark)` from `public/js/ui/framing.js:61-66`,
    /// converted to `#RRGGBB` hex for SwiftUI/UIKit rendering.
    /// Light mode: `hsl(h, min(sat, 30)%, 80%)`; Dark mode: `hsl(h, min(sat, 22)%, 17%)`.
    public static func sheetTintHex(r: Int, g: Int, b: Int, isDark: Bool) -> String {
        let (h, s, _) = rgbToHSL(r: r, g: g, b: b)
        let satPercent = min(Int((s * 100.0).rounded()), 30)
        let effectiveSat = Double(isDark ? min(satPercent, 22) : satPercent) / 100.0
        let effectiveLight = isDark ? 0.17 : 0.80
        let (tr, tg, tb) = hslToRGB(h: Double(h), s: effectiveSat, l: effectiveLight)
        return hexString(r: tr, g: tg, b: tb)
    }

    /// Converts `(h: 0...360, s: 0...1, l: 0...1)` to 8-bit `(r, g, b)`.
    public static func hslToRGB(h: Double, s: Double, l: Double) -> (Int, Int, Int) {
        let sat = min(1.0, max(0.0, s))
        let light = min(1.0, max(0.0, l))
        if sat == 0 {
            let gray = clampByte(Int((light * 255.0).rounded()))
            return (gray, gray, gray)
        }
        let hueNorm = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0)
            .truncatingRemainder(dividingBy: 360.0) / 360.0
        let q = light < 0.5 ? light * (1.0 + sat) : light + sat - light * sat
        let p = 2.0 * light - q

        func hueToChannel(_ tInput: Double) -> Double {
            var t = tInput
            if t < 0 { t += 1.0 }
            if t > 1 { t -= 1.0 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }

        let r = clampByte(Int((hueToChannel(hueNorm + 1.0 / 3.0) * 255.0).rounded()))
        let g = clampByte(Int((hueToChannel(hueNorm) * 255.0).rounded()))
        let b = clampByte(Int((hueToChannel(hueNorm - 1.0 / 3.0) * 255.0).rounded()))
        return (r, g, b)
    }

    /// Converts normalized `(r, g, b)` in `0...1` to HSV `(hue: 0...360, saturation: 0...1, value: 0...1)`.
    public static func rgbToHSV(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let v = maxC
        let s = maxC == 0 ? 0 : delta / maxC
        if delta == 0 {
            return (0, 0, v)
        }
        let rawH: Double
        if maxC == r {
            rawH = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxC == g {
            rawH = ((b - r) / delta) + 2.0
        } else {
            rawH = ((r - g) / delta) + 4.0
        }
        let degrees = (rawH * 60.0 + 360.0).truncatingRemainder(dividingBy: 360.0)
        return (degrees, s, v)
    }

    // MARK: - Hex Formatting & Parsing

    public static func hexString(r: Int, g: Int, b: Int) -> String {
        String(format: "#%02X%02X%02X", clampByte(r), clampByte(g), clampByte(b))
    }

    public static func rgbComponents(fromHex hex: String) -> (Int, Int, Int)? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        let r = Int((value >> 16) & 0xFF)
        let g = Int((value >> 8) & 0xFF)
        let b = Int(value & 0xFF)
        return (r, g, b)
    }

    public static func color(fromHex hex: String) -> Color? {
        guard let (r, g, b) = rgbComponents(fromHex: hex) else { return nil }
        return Color(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }

    public static func uiColor(fromHex hex: String) -> UIColor? {
        guard let (r, g, b) = rgbComponents(fromHex: hex) else { return nil }
        return UIColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    private static func clampByte(_ value: Int) -> Int {
        min(255, max(0, value))
    }
}
