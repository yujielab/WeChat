//
//  SpringPhysics.swift
//  Cuven
//
//  Apple HIG & Developer Documentation Grounding:
//  - Human Interface Guidelines › Motion (interruptible springs, frequency-tiered motion, Reduce Motion)
//  - WWDC18 Session 803 › Designing Fluid Interfaces (momentum projection `d = 0.998` & reversible rubber-banding)
//  - Cuven Web Parity: `public/js/ui/spring.js:1-103`, `tools/gen-springs.mjs:6-12`,
//    `public/css/tokens.css:176-230`, `public/css/chat.css:145-158`, `design-qa.md:407-445,944`
//

import CuvenCore
import SwiftUI
import UIKit

// MARK: - Canonical VelocityProjector (`PROJECT.md § 5.3` & `spring.js:93-95`)

/// Fluid momentum projection matching `UIScrollView.DecelerationRate` (`0.998` normal / `0.990` fast)
/// and `project(velocity, decelerationRate)` in `public/js/ui/spring.js:93-95`.
public enum CuvenVelocityProjector: Sendable {
    /// Matches `UIScrollView.DecelerationRate.normal.rawValue` (`0.998`).
    public static let normalDecelerationRate: CGFloat = 0.998

    /// Matches `UIScrollView.DecelerationRate.fast.rawValue` (`0.990`).
    public static let fastDecelerationRate: CGFloat = 0.990

    /// Computes the projected travel distance (in points) before coming to rest for an initial velocity
    /// in points/second and per-millisecond deceleration rate `decelerationRate`.
    ///
    /// Formula (`Designing Fluid Interfaces` / `spring.js:93-95`):
    /// `((velocity / 1000) * d) / (1 - d)`
    public static func project(
        velocity: CGFloat,
        decelerationRate: CGFloat = normalDecelerationRate
    ) -> CGFloat {
        CuvenSpringSolver.project(velocity: velocity, decelerationRate: decelerationRate)
    }

    /// Projects a 2D gesture velocity (`CGPoint`, pt/s) to its resting displacement offset.
    public static func project(
        velocity: CGPoint,
        decelerationRate: CGFloat = normalDecelerationRate
    ) -> CGPoint {
        CGPoint(
            x: project(velocity: velocity.x, decelerationRate: decelerationRate),
            y: project(velocity: velocity.y, decelerationRate: decelerationRate)
        )
    }

    /// Projects a 2D `CGVector` velocity (pt/s) to its resting displacement vector.
    public static func project(
        velocity: CGVector,
        decelerationRate: CGFloat = normalDecelerationRate
    ) -> CGVector {
        CGVector(
            dx: project(velocity: velocity.dx, decelerationRate: decelerationRate),
            dy: project(velocity: velocity.dy, decelerationRate: decelerationRate)
        )
    }
}

/// Canonical top-level `VelocityProjector` alias (`PROJECT.md § 5.3`).
public typealias VelocityProjector = CuvenVelocityProjector

// MARK: - Canonical CuvenSprings (`PROJECT.md § 5.3`)

/// Tuned interruptible springs, reversible rubber-banding, and Reduce-Motion-aware animation helpers.
public enum CuvenSprings: Sendable {
    /// Nested alias so both `VelocityProjector.project(...)` and `CuvenSprings.VelocityProjector.project(...)` resolve cleanly.
    public typealias VelocityProjector = CuvenVelocityProjector

    // MARK: Canonical PROJECT.md § 5.3 Springs

    /// Critically damped 4-column strip pan & edge-swipe settle (`strip.js`, `damping: 1.0, response: 0.34s`).
    /// Zero overshoot ensures adjacent columns never show seams or rebound gaps.
    public static let stripSlide: Animation = .spring(response: 0.34, dampingFraction: 1.0, blendDuration: 0)

    /// Sheet & floating card presentation/rebound (`gen-springs.mjs:10` `bouncy`, `overlay.js:314`,
    /// `response: 0.34s, dampingFraction: 0.82`).
    public static let sheetPresent: Animation = .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0)

    /// Outgoing message rise & reaction tapback pop (`chat.css:155`, `response: 0.36s, dampingFraction: 0.76`).
    public static let bubblePop: Animation = .spring(response: 0.36, dampingFraction: 0.76, blendDuration: 0)

    /// iPhone Duo posture/hinge divider glide & vertical `DuoRail` / `PagesCapsule` spatial morph
    /// (`design-qa.md:944`, `response: 0.52s, dampingFraction: 0.88`).
    public static let railMorph: Animation = .spring(response: 0.52, dampingFraction: 0.88, blendDuration: 0)

    /// Snappy Liquid Glass bead/pill press & release rebound (`gen-springs.mjs:9` `snappy: [0.86, 0.24]`).
    public static let pressBounce: Animation = .spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0)

    // MARK: Extended Frequency-Tiered Springs (`tokens.css:221-229`)

    /// Default critically damped UI transition (`gen-springs.mjs:8` `smooth: [1.0, 0.30]`).
    public static let smooth: Animation = .spring(response: 0.30, dampingFraction: 1.0, blendDuration: 0)

    /// Large surface & page cross-fade settle (`gen-springs.mjs:11` `gentle: [1.0, 0.40]`).
    public static let gentle: Animation = .spring(response: 0.40, dampingFraction: 1.0, blendDuration: 0)

    /// Floating Call PiP corner snap (`float.js:59`, `response: 0.38s, dampingFraction: 0.84`).
    public static let pipSnap: Animation = .spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0)

    /// Plain `100ms` cross-fade replacing spatial motion when Reduce Motion is active (`tokens.css:194` `--dur-reduce`).
    public static let reducedMotionFade: Animation = .easeOut(duration: 0.10)

    /// Returns `reducedMotionFade` (`100ms` fade, zero bounce/travel) when `reduceMotion` is `true`,
    /// otherwise returns the requested physics animation.
    public static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotionFade : animation
    }

    /// Returns `nil` (instant state update, zero spatial drift) when `reduceMotion` is `true`,
    /// otherwise returns the requested physics animation.
    public static func nonDrifting(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: Momentum Projection & Reversible Rubber-Banding (`spring.js:93-102`)

    /// Convenience forwarder to `VelocityProjector.project(velocity:decelerationRate:)`.
    public static func project(
        velocity: CGFloat,
        decelerationRate: CGFloat = CuvenVelocityProjector.normalDecelerationRate
    ) -> CGFloat {
        CuvenVelocityProjector.project(velocity: velocity, decelerationRate: decelerationRate)
    }

    /// Progressive resistance past a scroll/drag boundary (`spring.js:98-102`).
    ///
    /// Reversible and continuous (`C¹` smooth at `overshoot == 0`):
    /// `sign(o) * ((|o| * d * c) / (d + c * |o|))`
    public static func rubberBand(
        overshoot: CGFloat,
        dimension: CGFloat,
        resistance: CGFloat = 0.55
    ) -> CGFloat {
        CuvenSpringSolver.rubberband(
            overshoot: overshoot,
            dimension: dimension,
            resistance: resistance
        )
    }

    /// Clamps `value` to `minValue...maxValue` with reversible rubber-banding outside the range.
    public static func clampWithRubberBand(
        value: CGFloat,
        min minValue: CGFloat,
        max maxValue: CGFloat,
        dimension: CGFloat,
        resistance: CGFloat = 0.55
    ) -> CGFloat {
        if value < minValue {
            return minValue + rubberBand(overshoot: value - minValue, dimension: dimension, resistance: resistance)
        } else if value > maxValue {
            return maxValue + rubberBand(overshoot: value - maxValue, dimension: dimension, resistance: resistance)
        }
        return value
    }

    /// Analytical instantaneous velocity (units/sec) at `t` seconds along a UIKit/SwiftUI spring (`spring.js:46-47`).
    public static func instantaneousVelocity(
        at t: Double,
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        damping: Double = 1.0,
        response: Double = 0.35
    ) -> Double {
        let dt = 1.0 / 240.0
        let v0 = CuvenSpringSolver.state(
            at: max(0, t),
            from: from,
            to: to,
            velocity: initialVelocity,
            damping: damping,
            response: response
        )
        let v1 = CuvenSpringSolver.state(
            at: max(0, t) + dt,
            from: from,
            to: to,
            velocity: initialVelocity,
            damping: damping,
            response: response
        )
        return (v1 - v0) / dt
    }
}

// MARK: - 100ms Sliding-Window Gesture Velocity Tracker (`spring.js:72-90`)

/// Tracks pointer samples over the trailing `100ms` window to compute smooth release velocity (pt/s)
/// for mid-flight catch and interactive sheet/strip gestures.
public struct CuvenGestureVelocityTracker: Sendable {
    private struct Sample: Sendable {
        let point: CGPoint
        let timestamp: TimeInterval
    }

    private var samples: [Sample] = []

    public init() {}

    public mutating func addSample(
        _ point: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        samples.append(Sample(point: point, timestamp: timestamp))
        while samples.count > 2, let oldest = samples.first, (timestamp - oldest.timestamp) > 0.10 {
            samples.removeFirst()
        }
    }

    public func velocity() -> CGPoint {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else {
            return .zero
        }
        let dt = max(last.timestamp - first.timestamp, 1.0 / 120.0)
        return CGPoint(
            x: (last.point.x - first.point.x) / dt,
            y: (last.point.y - first.point.y) / dt
        )
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
