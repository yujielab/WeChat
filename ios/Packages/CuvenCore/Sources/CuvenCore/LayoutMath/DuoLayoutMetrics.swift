import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Duo Spatial Layout Metrics (PROJECT.md § 5.1, viewport.js, columns.js, rail.css)

public struct DuoLayoutMetrics: Equatable, Sendable {
    public static let splitThreshold: CGFloat = 700
    public static let edgeColumnMinimum: CGFloat = 64
    public static let edgeAsymmetryMinimum: CGFloat = 8
    public static let innerDisplayMinimumShortSide: CGFloat = 560
    public static let defaultRailWidth: CGFloat = 52
    public static let defaultRailCenterFromRight: CGFloat = 49
    public static let outerPortraitRailTopReserve: CGFloat = 170
    public static let outerLandscapeRailTopReserve: CGFloat = 12
    public static let innerRailTopReserve: CGFloat = 118

    public let posture: DuoPosture
    public let viewportSize: CGSize
    public let safeAreaTop: CGFloat
    public let safeAreaBottom: CGFloat
    public let safeAreaLeft: CGFloat
    public let safeAreaRight: CGFloat
    public let hasRightSystemColumn: Bool       // safeRight >= 64 && abs(safeRight - safeLeft) > 8
    public let visibleColumnCount: Int          // 1 or 2
    public let leadingColumnWidth: CGFloat      // e.g. 342 on 951pt List|Thread; 525 on Thread|Details
    public let trailingColumnWidth: CGFloat     // e.g. 609 on 951pt List|Thread (525 content + 84 rail); 426 on Thread|Details
    public let threadContentWidth: CGFloat      // Constant 525pt on 951x669 Duo Open across both List|Thread & Thread|Details!
    public let hingeDivisionRect: CGRect?       // Non-nil in duoHalfBook / duoHalfLaptop
    public let railWidth: CGFloat               // 52pt when hasRightSystemColumn else 0
    public let railCenterFromRight: CGFloat     // 49pt
    public let railTopReserve: CGFloat          // 170pt closed portrait, 118pt open

    public init(
        posture: DuoPosture,
        viewportSize: CGSize,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat,
        safeAreaLeft: CGFloat,
        safeAreaRight: CGFloat,
        hasRightSystemColumn: Bool,
        visibleColumnCount: Int,
        leadingColumnWidth: CGFloat,
        trailingColumnWidth: CGFloat,
        threadContentWidth: CGFloat,
        hingeDivisionRect: CGRect?,
        railWidth: CGFloat,
        railCenterFromRight: CGFloat,
        railTopReserve: CGFloat
    ) {
        self.posture = posture
        self.viewportSize = viewportSize
        self.safeAreaTop = safeAreaTop
        self.safeAreaBottom = safeAreaBottom
        self.safeAreaLeft = safeAreaLeft
        self.safeAreaRight = safeAreaRight
        self.hasRightSystemColumn = hasRightSystemColumn
        self.visibleColumnCount = visibleColumnCount
        self.leadingColumnWidth = leadingColumnWidth
        self.trailingColumnWidth = trailingColumnWidth
        self.threadContentWidth = threadContentWidth
        self.hingeDivisionRect = hingeDivisionRect
        self.railWidth = railWidth
        self.railCenterFromRight = railCenterFromRight
        self.railTopReserve = railTopReserve
    }

    public static func compute(
        size: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        safeLeft: CGFloat,
        safeRight: CGFloat,
        activePairStartsAtThread: Bool,
        postureOverride: DuoPosture? = nil
    ) -> DuoLayoutMetrics {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let naturalRightColumn = safeRight >= edgeColumnMinimum && abs(safeRight - safeLeft) > edgeAsymmetryMinimum
        let isSplitWidth = width >= splitThreshold

        let resolvedPosture: DuoPosture
        if let override = postureOverride {
            resolvedPosture = override
        } else if naturalRightColumn {
            if isSplitWidth || min(width, height) >= innerDisplayMinimumShortSide {
                resolvedPosture = .duoOpen
            } else {
                resolvedPosture = .duoClosed
            }
        } else {
            resolvedPosture = isSplitWidth ? .iPhoneSplit : .iPhoneCompact
        }

        let hasRightColumn: Bool
        switch resolvedPosture {
        case .iPhoneCompact, .iPhoneSplit:
            hasRightColumn = false
        case .duoClosed, .duoOpen, .duoHalfBook:
            hasRightColumn = postureOverride != nil ? true : naturalRightColumn
        case .duoHalfLaptop:
            hasRightColumn = naturalRightColumn
        }

        // Effective right system column width used for content/column budget:
        // uses real safeRight when reported by iOS 27.1 Duo traits, or canonical
        // Duo reserve (84pt inner / 91pt outer) when simulating Duo postures via postureOverride.
        let effectiveRightColumnWidth: CGFloat
        if !hasRightColumn {
            effectiveRightColumnWidth = 0
        } else if naturalRightColumn {
            effectiveRightColumnWidth = safeRight
        } else {
            effectiveRightColumnWidth = (resolvedPosture == .duoClosed) ? 91 : 84
        }

        let visibleColumnCount: Int
        let leadingColumnWidth: CGFloat
        let trailingColumnWidth: CGFloat
        let threadContentWidth: CGFloat
        let hingeDivisionRect: CGRect?
        let railTopReserve: CGFloat

        switch resolvedPosture {
        case .iPhoneCompact:
            visibleColumnCount = 1
            leadingColumnWidth = width
            trailingColumnWidth = 0
            threadContentWidth = max(0, width - safeLeft - safeRight)
            hingeDivisionRect = nil
            railTopReserve = 0

        case .iPhoneSplit:
            visibleColumnCount = width > 0 ? 2 : 1
            let narrow = DuoColumnMath.narrowWidth(for: width)
            if activePairStartsAtThread {
                leadingColumnWidth = max(0, width - narrow)
                trailingColumnWidth = narrow
            } else {
                leadingColumnWidth = narrow
                trailingColumnWidth = max(0, width - narrow)
            }
            threadContentWidth = max(0, width - narrow)
            hingeDivisionRect = nil
            railTopReserve = 0

        case .duoClosed:
            visibleColumnCount = 1
            leadingColumnWidth = width
            trailingColumnWidth = 0
            threadContentWidth = max(0, width - safeLeft - effectiveRightColumnWidth)
            hingeDivisionRect = nil
            railTopReserve = (width > height) ? outerLandscapeRailTopReserve : outerPortraitRailTopReserve

        case .duoHalfBook:
            visibleColumnCount = width > 0 ? 2 : 1
            let divisionWidth: CGFloat
            let leftPaneWidth: CGFloat
            if abs(width - 951) < 1 {
                // Canonical 951pt book fold: 462 | 28pt hinge division | 461pt
                leftPaneWidth = 462
                divisionWidth = 28
            } else if width > 80 {
                divisionWidth = min(28, floor(width * 0.04))
                leftPaneWidth = floor((width - divisionWidth) / 2)
            } else {
                divisionWidth = 0
                leftPaneWidth = floor(width / 2)
            }
            let rightPaneWidth = max(0, width - leftPaneWidth - divisionWidth)
            leadingColumnWidth = leftPaneWidth
            trailingColumnWidth = rightPaneWidth
            hingeDivisionRect = CGRect(x: leftPaneWidth, y: 0, width: divisionWidth, height: height)
            if activePairStartsAtThread {
                threadContentWidth = leftPaneWidth
            } else {
                threadContentWidth = max(0, rightPaneWidth - effectiveRightColumnWidth)
            }
            railTopReserve = innerRailTopReserve

        case .duoHalfLaptop:
            visibleColumnCount = 1
            leadingColumnWidth = width
            trailingColumnWidth = 0
            let divisionHeight: CGFloat
            let topPaneHeight: CGFloat
            if abs(height - 951) < 1 {
                topPaneHeight = 462
                divisionHeight = 28
            } else if height > 80 {
                divisionHeight = 28
                topPaneHeight = floor((height - divisionHeight) / 2)
            } else {
                divisionHeight = 0
                topPaneHeight = floor(height / 2)
            }
            hingeDivisionRect = CGRect(x: 0, y: topPaneHeight, width: width, height: divisionHeight)
            let rightInset = hasRightColumn ? effectiveRightColumnWidth : safeRight
            threadContentWidth = max(0, width - safeLeft - rightInset)
            railTopReserve = hasRightColumn ? innerRailTopReserve : 0

        case .duoOpen:
            // Inner display turned upright (e.g. 669x951, <700pt) uses 1 column unless forced;
            // flat landscape (>=700pt, e.g. 951x669 or 890x626) uses 2-column split.
            let split = isSplitWidth || (postureOverride == .duoOpen && width >= 560 && width >= height) || (postureOverride == .duoOpen && width >= splitThreshold)
            if split && width > 0 {
                visibleColumnCount = 2
                let narrow = DuoColumnMath.narrowWidth(for: width)
                let edge = max(0, min(effectiveRightColumnWidth, width - 2 * narrow))
                let constantThreadWidth = max(0, width - narrow - edge)
                if activePairStartsAtThread {
                    // Thread | Details -> e.g. 525 | 426 (342 + 84) on 951pt
                    leadingColumnWidth = constantThreadWidth
                    trailingColumnWidth = max(0, width - constantThreadWidth)
                } else {
                    // Sidebar | List or List | Thread -> e.g. 342 | 609 (525 + 84) on 951pt
                    leadingColumnWidth = narrow
                    trailingColumnWidth = max(0, width - narrow)
                }
                threadContentWidth = constantThreadWidth
            } else {
                visibleColumnCount = 1
                leadingColumnWidth = width
                trailingColumnWidth = 0
                threadContentWidth = max(0, width - safeLeft - effectiveRightColumnWidth)
            }
            hingeDivisionRect = nil
            railTopReserve = innerRailTopReserve
        }

        return DuoLayoutMetrics(
            posture: resolvedPosture,
            viewportSize: size,
            safeAreaTop: safeTop,
            safeAreaBottom: safeBottom,
            safeAreaLeft: safeLeft,
            safeAreaRight: safeRight,
            hasRightSystemColumn: hasRightColumn,
            visibleColumnCount: visibleColumnCount,
            leadingColumnWidth: leadingColumnWidth,
            trailingColumnWidth: trailingColumnWidth,
            threadContentWidth: threadContentWidth,
            hingeDivisionRect: hingeDivisionRect,
            railWidth: hasRightColumn ? defaultRailWidth : 0,
            railCenterFromRight: defaultRailCenterFromRight,
            railTopReserve: hasRightColumn ? railTopReserve : 0
        )
    }
}

// MARK: - 4-Column Strip Geometry Math (Exact Port of public/js/ui/columns.js)

public struct DuoColumnBox: Equatable, Sendable {
    public var x: CGFloat
    public var width: CGFloat

    public init(x: CGFloat, width: CGFloat) {
        self.x = x
        self.width = width
    }
}

public struct DuoWindowGeometry: Equatable, Sendable {
    public var lead: CGFloat
    public var gap: CGFloat

    public init(lead: CGFloat, gap: CGFloat) {
        self.lead = lead
        self.gap = gap
    }
}

public enum DuoColumnMath {
    public static let narrowShare: CGFloat = 0.36
    public static let narrowMin: CGFloat = 300
    public static let narrowMax: CGFloat = 380
    public static let threadColumnIndex: Int = 2

    /// Matches `narrowWidth(width)` in `public/js/ui/columns.js:23-26`.
    public static func narrowWidth(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let raw = (width * narrowShare).rounded()
        let clamped = min(narrowMax, max(narrowMin, raw))
        return min(clamped, floor(width / 2))
    }

    /// Matches `openGeometry({ pose, width, fold, start, end })` in `public/js/ui/columns.js:34-45`.
    public static func openGeometry(
        isHalfBook: Bool,
        width: CGFloat,
        verticalHinge: Range<CGFloat>? = nil,
        startColumn: Int,
        rightSystemColumnWidth: CGFloat = 0
    ) -> DuoWindowGeometry {
        guard width > 0 else { return DuoWindowGeometry(lead: 0, gap: 0) }
        if isHalfBook {
            if let hinge = verticalHinge,
               hinge.upperBound > hinge.lowerBound,
               hinge.lowerBound > 0,
               hinge.upperBound < width {
                return DuoWindowGeometry(
                    lead: hinge.lowerBound,
                    gap: hinge.upperBound - hinge.lowerBound
                )
            }
            return DuoWindowGeometry(lead: width / 2, gap: 0)
        }
        let narrow = narrowWidth(for: width)
        let edge = max(0, min(rightSystemColumnWidth, width - 2 * narrow))
        let lead = startColumn < threadColumnIndex ? narrow : (width - narrow - edge)
        return DuoWindowGeometry(lead: lead, gap: 0)
    }

    /// Linearly interpolates between two window geometries (`t` may overshoot past `0...1` on springs).
    public static func mixGeometry(_ a: DuoWindowGeometry, _ b: DuoWindowGeometry, t: CGFloat) -> DuoWindowGeometry {
        DuoWindowGeometry(
            lead: a.lead + (b.lead - a.lead) * t,
            gap: a.gap + (b.gap - a.gap) * t
        )
    }

    /// Matches `boxesAt(s, { n, width, count, geo })` in `public/js/ui/columns.js:58-77`.
    public static func boxes(
        at windowStart: Int,
        columnCount n: Int = 4,
        viewportWidth width: CGFloat,
        visibleCount count: Int,
        geometryProvider geo: (Int) -> DuoWindowGeometry
    ) -> [DuoColumnBox] {
        guard n > 0 else { return [] }
        if count <= 1 {
            return (0..<n).map { i in
                DuoColumnBox(x: CGFloat(i - windowStart) * width, width: width)
            }
        }
        var result = Array(repeating: DuoColumnBox(x: 0, width: 0), count: n)
        let s = max(0, min(n - 1, windowStart))
        let here = geo(s)
        result[s] = DuoColumnBox(x: 0, width: here.lead)
        if s + 1 < n {
            result[s + 1] = DuoColumnBox(
                x: here.lead + here.gap,
                width: width - here.lead - here.gap
            )
        }
        if s > 0 {
            for i in stride(from: s - 1, through: 0, by: -1) {
                let g = geo(i)
                result[i] = DuoColumnBox(
                    x: result[i + 1].x - g.gap - g.lead,
                    width: g.lead
                )
            }
        }
        if s + 2 < n {
            for i in (s + 2)..<n {
                let g = geo(i - 1)
                let prev = result[i - 1]
                result[i] = DuoColumnBox(
                    x: prev.x + prev.width + g.gap,
                    width: width - g.lead - g.gap
                )
            }
        }
        return result
    }

    /// Matches `boxesAtPosition(p, opts)` in `public/js/ui/columns.js:80-88` for continuous gesture/spring positions.
    public static func boxesAtPosition(
        _ p: CGFloat,
        columnCount n: Int = 4,
        viewportWidth width: CGFloat,
        visibleCount count: Int,
        geometryProvider geo: (Int) -> DuoWindowGeometry
    ) -> [DuoColumnBox] {
        let lo = max(0, Int(floor(p + 1e-6)))
        let hi = min(n - 1, Int(ceil(p - 1e-6)))
        let a = boxes(at: lo, columnCount: n, viewportWidth: width, visibleCount: count, geometryProvider: geo)
        if hi == lo { return a }
        let b = boxes(at: hi, columnCount: n, viewportWidth: width, visibleCount: count, geometryProvider: geo)
        let t = (p - CGFloat(lo)) / CGFloat(hi - lo)
        return zip(a, b).map { lhs, rhs in
            DuoColumnBox(
                x: lhs.x + (rhs.x - lhs.x) * t,
                width: lhs.width + (rhs.width - lhs.width) * t
            )
        }
    }
}

// MARK: - Analytical Spring & Momentum Math (Exact Port of public/js/ui/spring.js)

public enum CuvenSpringSolver {
    /// Analytical UIKit/SwiftUI-parameterized spring displacement at `t` seconds (`public/js/ui/spring.js:7-19`).
    public static func state(
        at t: Double,
        from: Double,
        to: Double,
        velocity: Double = 0,
        damping: Double = 1.0,
        response: Double = 0.35
    ) -> Double {
        guard response > 0, t > 0 else { return t <= 0 ? from : to }
        let w0 = (2.0 * Double.pi) / response
        let x0 = from - to
        let displacement: Double
        if damping < 1.0 {
            let wd = w0 * sqrt(max(1e-9, 1.0 - damping * damping))
            let env = exp(-damping * w0 * t)
            displacement = env * (x0 * cos(wd * t) + ((velocity + damping * w0 * x0) / wd) * sin(wd * t))
        } else {
            displacement = exp(-w0 * t) * (x0 + (velocity + w0 * x0) * t)
        }
        return to + displacement
    }

    /// Analytical instantaneous velocity (units/sec) at `t` seconds (`public/js/ui/spring.js:46-47`).
    public static func velocity(
        at t: Double,
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        damping: Double = 1.0,
        response: Double = 0.35
    ) -> Double {
        guard response > 0, t >= 0 else { return initialVelocity }
        let dt = 1.0 / 2400.0
        let p0 = state(at: t, from: from, to: to, velocity: initialVelocity, damping: damping, response: response)
        let p1 = state(at: t + dt, from: from, to: to, velocity: initialVelocity, damping: damping, response: response)
        return (p1 - p0) / dt
    }

    /// Apple's Designing Fluid Interfaces momentum projection (`public/js/ui/spring.js:93-95`).
    public static func project(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        let clampedRate = min(0.9999, max(0.0001, decelerationRate))
        return ((velocity / 1000.0) * clampedRate) / (1.0 - clampedRate)
    }

    /// Progressive boundary rubber-banding (`public/js/ui/spring.js:98-102`).
    public static func rubberband(overshoot: CGFloat, dimension: CGFloat, resistance: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let sign: CGFloat = overshoot < 0 ? -1 : (overshoot > 0 ? 1 : 0)
        let mag = abs(overshoot)
        return sign * ((mag * dimension * resistance) / (dimension + resistance * mag))
    }

    public enum VelocityProjector: Sendable {
        public static let normalDecelerationRate: CGFloat = 0.998
        public static let fastDecelerationRate: CGFloat = 0.990

        public static func project(velocity: CGFloat, decelerationRate: CGFloat = normalDecelerationRate) -> CGFloat {
            CuvenSpringSolver.project(velocity: velocity, decelerationRate: decelerationRate)
        }
    }
}

public typealias SpringSolver = CuvenSpringSolver
