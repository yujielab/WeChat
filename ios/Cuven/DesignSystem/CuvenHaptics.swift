//
//  CuvenHaptics.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Playing Haptics (subtle, crisp, synchronized with gesture thresholds)
//  - Human Interface Guidelines › Accessibility › Motion (respect Reduce Motion & user Haptics toggle)
//  - Cuven Web Parity: `public/js/ui/haptics.js:1-35`, `public/js/ui/appearance.js:18,77-79`
//

import Foundation
import UIKit

/// Centralized tactile feedback dispatcher backed by pre-warmed UIKit feedback generators.
///
/// - Gated by both the user's `Haptics` preference (`cuven.haptics.enabled`, default `true`) and
///   `UIAccessibility.isReduceMotionEnabled` (suppressing kinetic impact bounces under Reduce Motion).
/// - Safe to invoke synchronously from any concurrency context (`@MainActor` views execute with zero
///   frame latency via `MainActor.assumeIsolated`).
public enum CuvenHaptics: Sendable {

    public static let preferenceDefaultsKey = "cuven.haptics.enabled"

    /// Reads or updates the user's Haptics setting (`appearance.js:18,77-79`).
    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: preferenceDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: preferenceDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceDefaultsKey)
        }
    }

    // MARK: - Canonical PROJECT.md § 5.3 Haptic Actions

    /// Crisp light tap for Liquid Glass beads, toolbar actions, and note/card taps.
    public static func lightTap() {
        performOnMain {
            guard shouldPlayKineticHaptic else { return }
            HapticEnginePool.shared.lightGenerator.impactOccurred(intensity: 0.78)
            HapticEnginePool.shared.lightGenerator.prepare()
        }
    }

    /// Subtle detent tick for filter pills, `Pages` capsule slots, invite-code segments, and scrubbers.
    public static func selectionChanged() {
        performOnMain {
            guard isEnabled else { return }
            HapticEnginePool.shared.selectionGenerator.selectionChanged()
            HapticEnginePool.shared.selectionGenerator.prepare()
        }
    }

    /// Cushioned organic impact for double-tap ❤️ reaction, bubble snap, and sheet settle.
    public static func softImpact() {
        performOnMain {
            guard shouldPlayKineticHaptic else { return }
            HapticEnginePool.shared.softGenerator.impactOccurred(intensity: 0.85)
            HapticEnginePool.shared.softGenerator.prepare()
        }
    }

    /// Firm mechanical detent when crossing the `55%` swipe-to-delete threshold, long-press bubble lift,
    /// or form validation rejection.
    public static func rigidImpact() {
        performOnMain {
            guard shouldPlayKineticHaptic else { return }
            HapticEnginePool.shared.rigidGenerator.impactOccurred(intensity: 0.92)
            HapticEnginePool.shared.rigidGenerator.prepare()
        }
    }

    /// Positive confirmation chime haptic for sign-in, Moment publish, or friend request acceptance.
    public static func success() {
        performOnMain {
            guard isEnabled else { return }
            HapticEnginePool.shared.notificationGenerator.notificationOccurred(.success)
            HapticEnginePool.shared.notificationGenerator.prepare()
        }
    }

    // MARK: - Extended Semantic Notifications

    /// Cautionary feedback for discard guards and unstable call warnings.
    public static func warning() {
        performOnMain {
            guard isEnabled else { return }
            HapticEnginePool.shared.notificationGenerator.notificationOccurred(.warning)
            HapticEnginePool.shared.notificationGenerator.prepare()
        }
    }

    /// Error feedback for failed sends or rejected credentials.
    public static func error() {
        performOnMain {
            guard isEnabled else { return }
            HapticEnginePool.shared.notificationGenerator.notificationOccurred(.error)
            HapticEnginePool.shared.notificationGenerator.prepare()
        }
    }

    /// Pre-warms Taptic Engine generators ahead of an interactive drag gesture.
    public static func prepareAll() {
        performOnMain {
            guard isEnabled else { return }
            HapticEnginePool.shared.prepareAll()
        }
    }

    // MARK: - Internal MainActor Execution & Accessibility Gating

    @MainActor
    private static var shouldPlayKineticHaptic: Bool {
        isEnabled && !UIAccessibility.isReduceMotionEnabled
    }

    private static func performOnMain(_ block: @MainActor @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                block()
            }
        } else {
            Task { @MainActor in
                block()
            }
        }
    }
}

@MainActor
private final class HapticEnginePool {
    static let shared = HapticEnginePool()

    let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    let selectionGenerator = UISelectionFeedbackGenerator()
    let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        prepareAll()
    }

    func prepareAll() {
        lightGenerator.prepare()
        softGenerator.prepare()
        rigidGenerator.prepare()
        selectionGenerator.prepare()
        notificationGenerator.prepare()
    }
}
