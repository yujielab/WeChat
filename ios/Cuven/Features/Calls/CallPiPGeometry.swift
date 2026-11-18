import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import CuvenCore

// MARK: - Apple HIG & Cuven Web Grounding
// - Apple HIG: Designing for iPhone Duo (Reserved Regions, Right System Column, Postures)
// - Apple WWDC18: Designing Fluid Interfaces (UIScrollView.DecelerationRate = 0.998 projection)
// - Cuven Web Reference: public/js/ui/corners.js (1-90), public/js/ui/float.js (1-175), public/css/call.css (323-336)

/// Canonical four safe-area corners for floating Picture-in-Picture & self-preview tiles (`corners.js:11`).
public enum CallPiPCorner: String, Codable, CaseIterable, Hashable, Sendable {
    case topLeading = "tl"
    case topTrailing = "tr"
    case bottomLeading = "bl"
    case bottomTrailing = "br"

    public var isLeading: Bool {
        self == .topLeading || self == .bottomLeading
    }

    public var isTop: Bool {
        self == .topLeading || self == .topTrailing
    }
}

/// Screen edge where a flung PiP tile tucks away leaving a 28pt peek handle (`float.js:28`).
public enum CallPiPStashSide: String, Codable, CaseIterable, Hashable, Sendable {
    case leading = "left"
    case trailing = "right"
}

/// Resting state of the floating Call PiP tile (`corners.js:60-69`).
public enum CallPiPRestingPlace: Equatable, Hashable, Sendable {
    case corner(CallPiPCorner)
    case stashed(side: CallPiPStashSide, y: CGFloat)

    public var isStashed: Bool {
        if case .stashed = self { return true }
        return false
    }

    public var stashSide: CallPiPStashSide? {
        if case let .stashed(side, _) = self { return side }
        return nil
    }

    public var corner: CallPiPCorner? {
        if case let .corner(c) = self { return c }
        return nil
    }
}

/// Pure, deterministic geometry & physics math for Call PiP corner snapping,
/// momentum velocity projection (`0.998` corner / `0.99` edge-stash), `28pt` edge-stash peek handle,
/// and `DuoLayoutMetrics`-aware safe regions.
public enum CallPiPGeometry {
    /// Visible peek handle width when PiP is tucked off-screen (`ui/float.js:28`, Follow-up Spec §4.4.3).
    public static let stashPeekWidth: CGFloat = 28

    /// Concentric squircle corner radius of the minimized PiP window (`views/call.js:593`).
    public static let pipCornerRadius: CGFloat = 18

    /// Gap inset inside safe areas for resting corners (`call.css:326` `--pip-gap: 12px`).
    public static let safeGap: CGFloat = 12

    /// Standard scroll deceleration rate for corner projection (`corners.js:67` `0.998`).
    public static let cornerDecelerationRate: CGFloat = 0.998

    /// Short-horizon deceleration rate (~100ms flight) for edge-stash detection (`corners.js:62` `0.99`).
    public static let stashDecelerationRate: CGFloat = 0.990

    /// Rubberband resistance coefficient past safe boundaries (`spring.js:98` `0.55`).
    public static let rubberbandCoefficient: CGFloat = 0.55

    /// Spring response & damping ratio matching `float.js:59` (`damping: 0.84, response: 0.38`).
    public static let settleSpringResponse: Double = 0.38
    public static let settleSpringDamping: Double = 0.84

    /// Apple's momentum travel distance formula (`Designing Fluid Interfaces`, `spring.js:93-95`):
    /// `travel(v, rate) = ((v / 1000) * rate) / (1 - rate)` where `v` is points/second.
    public static func project(velocity: CGFloat, decelerationRate: CGFloat = cornerDecelerationRate) -> CGFloat {
        let clampedRate = min(max(decelerationRate, 0.001), 0.9999)
        return ((velocity / 1000.0) * clampedRate) / (1.0 - clampedRate)
    }

    /// Progressive boundary resistance matching `spring.js:98-102`.
    public static func rubberband(
        overshoot: CGFloat,
        dimension: CGFloat,
        coefficient: CGFloat = rubberbandCoefficient
    ) -> CGFloat {
        guard dimension > 0, overshoot != 0 else { return 0 }
        let sign: CGFloat = overshoot < 0 ? -1 : 1
        let absOvershoot = abs(overshoot)
        return sign * ((absOvershoot * dimension * coefficient) / (dimension + coefficient * absOvershoot))
    }

    /// Computes the safe resting frame (`CGRect`) for the PiP tile's full bounding box,
    /// clearing Dynamic Island / top headers, bottom floating dock / Home indicator,
    /// AND iPhone Duo's asymmetric `84pt` / `91pt` right system status & `DuoRail` column.
    public static func safePiPFrame(
        in metrics: DuoLayoutMetrics,
        containerSize: CGSize? = nil,
        keyboardHeight: CGFloat = 0
    ) -> CGRect {
        let size = containerSize ?? metrics.viewportSize
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        // Top reserve clears status bar / Dynamic Island + top navigation chrome (`call.css:330`).
        let headerClearance = min(84, height * 0.13)
        let topInset = metrics.safeAreaTop + headerClearance

        // Bottom reserve clears 56pt horizontal Liquid Glass dock (when !hasRightSystemColumn)
        // or Home indicator + breathing room on Duo vertical-rail layouts (`call.css:331, 335`).
        let dockClearance: CGFloat = metrics.hasRightSystemColumn
            ? min(44, height * 0.08)
            : min(76, max(68, height * 0.12))
        let bottomInset: CGFloat
        if keyboardHeight > 0 {
            bottomInset = keyboardHeight + 16
        } else {
            bottomInset = max(metrics.safeAreaBottom, 16) + dockClearance
        }

        let leftInset = metrics.safeAreaLeft + safeGap

        // Right reserve strictly clears iPhone Duo's 84pt/91pt right system column + 52pt DuoRail.
        let duoRailSpan: CGFloat = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, metrics.railCenterFromRight + metrics.railWidth * 0.5 + 8)
            : metrics.safeAreaRight
        let rightInset = duoRailSpan + safeGap

        let minX = min(leftInset, width * 0.45)
        let maxX = max(minX, width - rightInset)
        let minY = min(topInset, height * 0.45)
        let maxY = max(minY, height - bottomInset)

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Visible horizontal canvas edges (`minX`, `maxX`) from which a stashed PiP tile hangs (`call.js:780-783`).
    /// On standard iPhone this is `0 ... width`; on iPhone Duo this stops cleanly at the right system rail edge
    /// so the `28pt` `"Show call"` peek handle never overlaps `DuoRailView` or `PagesCapsuleView`.
    public static func stashEdgeBounds(
        in metrics: DuoLayoutMetrics,
        containerSize: CGSize? = nil
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let size = containerSize ?? metrics.viewportSize
        let width = max(size.width, 1)
        let leadingEdge = metrics.safeAreaLeft
        let rightSystemSpan: CGFloat = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, metrics.railCenterFromRight + metrics.railWidth * 0.5 + 4)
            : metrics.safeAreaRight
        let trailingEdge = max(leadingEdge + stashPeekWidth * 2, width - rightSystemSpan)
        return (leading: leadingEdge, trailing: trailingEdge)
    }

    /// Proportional PiP tile size (`call.js:785-792`), ~26% of short viewport side clamped to `96...140pt` width.
    public static func pipTileSize(
        in metrics: DuoLayoutMetrics,
        mediaKind: CallMediaKind,
        containerSize: CGSize? = nil
    ) -> CGSize {
        let viewport = containerSize ?? metrics.viewportSize
        let shortSide = max(1, min(viewport.width, viewport.height))
        let baseWidth = min(138, max(96, round(shortSide * 0.26)))
        let aspectRatio: CGFloat = mediaKind == .video ? 1.44 : 1.22
        let baseHeight = round(baseWidth * aspectRatio)

        let safe = safePiPFrame(in: metrics, containerSize: viewport)
        guard safe.width > 40, safe.height > 40 else {
            return CGSize(width: baseWidth, height: baseHeight)
        }
        let scale = min(1.0, (safe.height * 0.55) / baseHeight, (safe.width * 0.48) / baseWidth)
        return CGSize(width: round(baseWidth * scale), height: round(baseHeight * scale))
    }

    /// Top-left origin of a tile resting in `corner` inside `frame` (`corners.js:16-23`).
    public static func cornerOrigin(
        in frame: CGRect,
        tileSize: CGSize,
        corner: CallPiPCorner
    ) -> CGPoint {
        let roomX = frame.width - tileSize.width
        let roomY = frame.height - tileSize.height
        let x: CGFloat
        if roomX < 0 {
            x = frame.minX + roomX * 0.5
        } else {
            x = corner.isLeading ? frame.minX : (frame.maxX - tileSize.width)
        }

        let y: CGFloat
        if roomY < 0 {
            y = frame.minY + roomY * 0.5
        } else {
            y = corner.isTop ? frame.minY : (frame.maxY - tileSize.height)
        }
        return CGPoint(x: x, y: y)
    }

    /// Nearest safe corner to `origin` (`corners.js:26-38`).
    public static func nearestCorner(
        in frame: CGRect,
        tileSize: CGSize,
        to origin: CGPoint
    ) -> CallPiPCorner {
        var bestCorner: CallPiPCorner = .topTrailing
        var bestDistSquared: CGFloat = .greatestFiniteMagnitude

        for candidate in CallPiPCorner.allCases {
            let target = cornerOrigin(in: frame, tileSize: tileSize, corner: candidate)
            let dx = target.x - origin.x
            let dy = target.y - origin.y
            let d2 = dx * dx + dy * dy
            if d2 < bestDistSquared {
                bestDistSquared = d2
                bestCorner = candidate
            }
        }
        return bestCorner
    }

    /// Top-left origin of a tile stashed off `side`, leaving `peekWidth` (`28pt`) showing (`corners.js:41-46`).
    public static func stashedOrigin(
        in frame: CGRect,
        tileSize: CGSize,
        edgeBounds: (leading: CGFloat, trailing: CGFloat),
        side: CallPiPStashSide,
        y: CGFloat,
        peekWidth: CGFloat = stashPeekWidth
    ) -> CGPoint {
        let x: CGFloat = switch side {
        case .leading:
            edgeBounds.leading - tileSize.width + peekWidth
        case .trailing:
            edgeBounds.trailing - peekWidth
        }
        let maxY = max(frame.minY, frame.maxY - tileSize.height)
        let clampedY = min(max(y, frame.minY), maxY)
        return CGPoint(x: x, y: clampedY)
    }

    /// Resolves target origin for any `CallPiPRestingPlace`.
    public static func targetOrigin(
        for place: CallPiPRestingPlace,
        in frame: CGRect,
        tileSize: CGSize,
        edgeBounds: (leading: CGFloat, trailing: CGFloat),
        peekWidth: CGFloat = stashPeekWidth
    ) -> CGPoint {
        switch place {
        case let .corner(corner):
            return cornerOrigin(in: frame, tileSize: tileSize, corner: corner)
        case let .stashed(side, y):
            return stashedOrigin(
                in: frame,
                tileSize: tileSize,
                edgeBounds: edgeBounds,
                side: side,
                y: y,
                peekWidth: peekWidth
            )
        }
    }

    /// Computes where a released tile comes to rest (`corners.js:60-69`):
    /// - If `allowStash` and `0.99` short-flight projection carries the tile's horizontal midpoint
    ///   past `edgeBounds.leading` or `edgeBounds.trailing`, tucks off-screen with `28pt` handle.
    /// - Otherwise projects with `0.998` deceleration and snaps to the nearest of the 4 safe corners.
    public static func restingPlace(
        in frame: CGRect,
        tileSize: CGSize,
        currentOrigin: CGPoint,
        velocity: CGVector,
        allowStash: Bool = true,
        edgeBounds: (leading: CGFloat, trailing: CGFloat)? = nil
    ) -> CallPiPRestingPlace {
        let edges = edgeBounds ?? (leading: frame.minX, trailing: frame.maxX)

        if allowStash {
            let projectedMidX = currentOrigin.x + project(velocity: velocity.dx, decelerationRate: stashDecelerationRate) + tileSize.width * 0.5
            let projectedY = currentOrigin.y + project(velocity: velocity.dy, decelerationRate: stashDecelerationRate)
            let clampedY = min(max(projectedY, frame.minY), max(frame.minY, frame.maxY - tileSize.height))

            if projectedMidX < edges.leading {
                return .stashed(side: .leading, y: clampedY)
            }
            if projectedMidX > edges.trailing {
                return .stashed(side: .trailing, y: clampedY)
            }
        }

        let projectedOrigin = CGPoint(
            x: currentOrigin.x + project(velocity: velocity.dx, decelerationRate: cornerDecelerationRate),
            y: currentOrigin.y + project(velocity: velocity.dy, decelerationRate: cornerDecelerationRate)
        )
        return .corner(nearestCorner(in: frame, tileSize: tileSize, to: projectedOrigin))
    }

    /// Clamps / rubberbands an interactive 1:1 drag origin (`float.js:100-114`).
    public static func interactiveDragOrigin(
        rawOrigin: CGPoint,
        in frame: CGRect,
        tileSize: CGSize,
        allowStash: Bool = true,
        edgeBounds: (leading: CGFloat, trailing: CGFloat)? = nil,
        peekWidth: CGFloat = stashPeekWidth
    ) -> CGPoint {
        let edges = edgeBounds ?? (leading: frame.minX, trailing: frame.maxX)
        let minX = allowStash ? (edges.leading - tileSize.width + peekWidth) : frame.minX
        let maxX = allowStash ? (edges.trailing - peekWidth) : max(frame.minX, frame.maxX - tileSize.width)
        let minY = frame.minY
        let maxY = max(frame.minY, frame.maxY - tileSize.height)

        let x: CGFloat
        if rawOrigin.x < minX {
            x = minX + rubberband(overshoot: rawOrigin.x - minX, dimension: tileSize.width)
        } else if rawOrigin.x > maxX {
            x = maxX + rubberband(overshoot: rawOrigin.x - maxX, dimension: tileSize.width)
        } else {
            x = rawOrigin.x
        }

        let y: CGFloat
        if rawOrigin.y < minY {
            y = minY + rubberband(overshoot: rawOrigin.y - minY, dimension: tileSize.height)
        } else if rawOrigin.y > maxY {
            y = maxY + rubberband(overshoot: rawOrigin.y - maxY, dimension: tileSize.height)
        } else {
            y = rawOrigin.y
        }

        return CGPoint(x: x, y: y)
    }

    /// Unstashes a tucked PiP tile to the nearest corner on its side (`corners.js:71-76`).
    public static func unstashCorner(
        in frame: CGRect,
        tileSize: CGSize,
        side: CallPiPStashSide,
        currentY: CGFloat
    ) -> CallPiPCorner {
        let topCorner: CallPiPCorner = side == .leading ? .topLeading : .topTrailing
        let bottomCorner: CallPiPCorner = side == .leading ? .bottomLeading : .bottomTrailing
        let topY = cornerOrigin(in: frame, tileSize: tileSize, corner: topCorner).y
        let bottomY = cornerOrigin(in: frame, tileSize: tileSize, corner: bottomCorner).y
        return abs(currentY - topY) <= abs(currentY - bottomY) ? topCorner : bottomCorner
    }

    /// Keyboard arrow-key navigation across corners (`corners.js:79-89`).
    public static func cornerToward(from current: CallPiPCorner, direction: String) -> CallPiPCorner {
        let top = current.isTop
        let leading = current.isLeading
        switch direction {
        case "ArrowLeft":
            return top ? .topLeading : .bottomLeading
        case "ArrowRight":
            return top ? .topTrailing : .bottomTrailing
        case "ArrowUp":
            return leading ? .topLeading : .topTrailing
        case "ArrowDown":
            return leading ? .bottomLeading : .bottomTrailing
        default:
            return current
        }
    }

    /// Computes elapsed call seconds safely whether `startedAt` is Unix milliseconds (`> 10_000_000_000`)
    /// or Unix seconds.
    public static func elapsedSeconds(from startedAt: Int64?, now: Date = Date()) -> Int {
        guard let startedAt, startedAt > 0 else { return 0 }
        let startSeconds: Double = startedAt > 10_000_000_000
            ? Double(startedAt) / 1000.0
            : Double(startedAt)
        let delta = now.timeIntervalSince1970 - startSeconds
        return max(0, Int(delta.rounded(.down)))
    }

    /// Tabular call duration formatter (`M:SS` or `H:MM:SS`, matching `ui/format.js` `callClock`).
    public static func formattedDuration(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
