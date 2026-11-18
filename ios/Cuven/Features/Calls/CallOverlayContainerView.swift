import SwiftUI
import CuvenCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Apple HIG & PROJECT.md § 5.4 Canonical Entry Point
// - Canonical View Signature: `CallOverlayContainerView(store: AppStore, metrics: DuoLayoutMetrics)`
// - Coordinates:
//   1. `IncomingCallOverlayView` (`call.incomingOverlay` — `Accept` / `Decline` over Liquid Glass)
//   2. `ActiveCallView` (`call.activeOverlay` — full posture-adaptive Audio/Video call + `duoHalfLaptop` tabletop split)
//   3. `FloatingCallPiPTile` (`call.pipTile` — 4-corner momentum snap + `28pt` `"Show call"` edge-stash peek handle)
//   4. `CloudflareSFUWebRTCEngine` (100% pure native `/rtc/*` REST + `NWConnection` UDP STUN/ICE + `AVAudioSession`, zero hybrid web views)
//   5. `CallKitManager` (deterministic UUID mapping + Simulator-safe CXProvider / CXCallController)
//   6. `CallSynthesizedTones` (`AVAudioEngine` 450Hz ringback, E5->G5->B5 bell triad, E5->A4 end chime)

/// Root call overlay container mounted above Cuven's 4-column shell and sheets (`PROJECT.md § 5.4`).
public struct CallOverlayContainerView: View {
    @Bindable private var store: AppStore
    private let metrics: DuoLayoutMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cuvenKeyboardHeight) private var keyboardHeight

    @Namespace private var callMorphNamespace
    @State private var rtcEngine = CloudflareSFUWebRTCEngine()
    @State private var lastObservedSessionID: String?
    @State private var lastObservedPhase: CallPhase?

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    private var activeVisibleCall: CallSession? {
        guard let call = store.activeCall,
              call.phase != .idle,
              call.phase != .ended
        else {
            return nil
        }
        return call
    }

    public var body: some View {
        ZStack {
            if let call = activeVisibleCall {
                if call.phase == .incomingRinging {
                    IncomingCallOverlayView(
                        session: call,
                        metrics: metrics,
                        backdropPreset: store.prefs.callBackdrop,
                        glassMode: store.prefs.glassMode,
                        morphNamespace: callMorphNamespace,
                        onAccept: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                                store.acceptIncomingCall()
                            }
                        },
                        onDecline: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                store.endOrDeclineCall()
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1.0 : 1.03)))
                } else if call.isMinimizedPiP {
                    FloatingCallPiPTile(
                        session: call,
                        metrics: metrics,
                        glassMode: store.prefs.glassMode,
                        currentUserName: store.currentUser?.display ?? "You",
                        currentUserAvatarURL: store.currentUser?.avatarURL,
                        morphNamespace: callMorphNamespace,
                        onExpand: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
                                store.setCallMinimizedPiP(false)
                            }
                        },
                        onToggleMute: {
                            store.toggleCallMute()
                        },
                        onToggleCamera: {
                            store.toggleCallCamera()
                        },
                        onToggleSpeaker: {
                            store.toggleCallSpeaker()
                        },
                        onEndCall: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                store.endOrDeclineCall()
                            }
                        }
                    )
                    .transition(.opacity)
                } else {
                    ActiveCallView(
                        session: call,
                        metrics: metrics,
                        backdropPreset: store.prefs.callBackdrop,
                        glassMode: store.prefs.glassMode,
                        currentUserName: store.currentUser?.display ?? "You",
                        currentUserAvatarURL: store.currentUser?.avatarURL,
                        recentMessages: store.messagesByRoom[call.roomID] ?? [],
                        typingPreview: store.typingPreviewByRoom[call.roomID],
                        engine: rtcEngine,
                        morphNamespace: callMorphNamespace,
                        onToggleMute: {
                            store.toggleCallMute()
                        },
                        onToggleCamera: {
                            store.toggleCallCamera()
                        },
                        onToggleSpeaker: {
                            store.toggleCallSpeaker()
                        },
                        onMinimize: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
                                store.setCallMinimizedPiP(true)
                            }
                        },
                        onEndCall: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                store.endOrDeclineCall()
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1.0 : 0.98)))
                }
            }
        }
        .animation(
            CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion),
            value: activeVisibleCall?.id
        )
        .animation(
            CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion),
            value: activeVisibleCall?.phase
        )
        .animation(
            CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion),
            value: activeVisibleCall?.isMinimizedPiP
        )
        .onAppear {
            bindCallKitSystemCallbacks()
            synchronizeCallSubsystems(with: store.activeCall)
        }
        .onChange(of: store.activeCall) { _, updatedCall in
            synchronizeCallSubsystems(with: updatedCall)
        }
        .onDisappear {
            updateIdleTimerWakeLock(for: nil)
        }
    }

    // MARK: - Deterministic Subsystem Synchronization

    private func bindCallKitSystemCallbacks() {
        CallKitManager.shared.onSystemAcceptCall = { [weak store] in
            store?.acceptIncomingCall()
        }
        CallKitManager.shared.onSystemEndCall = { [weak store] in
            store?.endOrDeclineCall()
        }
        CallKitManager.shared.onSystemToggleMute = { [weak store] shouldMute in
            guard let store, let current = store.activeCall else { return }
            if current.isMuted != shouldMute {
                store.toggleCallMute()
            }
        }
    }

    private func synchronizeCallSubsystems(with session: CallSession?) {
        // 1. Native Cloudflare Realtime SFU + UDP STUN/ICE + AVAudioSession
        rtcEngine.sync(
            call: session,
            serverBaseURL: store.serverBaseURL,
            currentUserID: store.currentUser?.id ?? "me"
        )

        // 2. Native CallKit (Simulator-guarded CXProvider / CXCallController)
        CallKitManager.shared.sync(with: session)

        // 3. Screen wake-lock for active video calls (`views/call.js:480-487`)
        updateIdleTimerWakeLock(for: session)

        // 4. Synthesized AVAudioEngine call tones (`tones.js` parity)
        synchronizeCallTones(with: session)
    }

    private func synchronizeCallTones(with session: CallSession?) {
        guard let session, session.phase != .idle, session.phase != .ended else {
            if lastObservedSessionID != nil,
               let priorPhase = lastObservedPhase,
               priorPhase != .idle,
               priorPhase != .ended {
                CallSynthesizedTones.shared.playEndTone()
            } else {
                CallSynthesizedTones.shared.stopLoopingTones()
            }
            lastObservedSessionID = nil
            lastObservedPhase = session?.phase
            return
        }

        let isSameSession = (lastObservedSessionID == session.id)
        let priorPhase = isSameSession ? lastObservedPhase : nil

        switch session.phase {
        case .outgoingRinging:
            CallSynthesizedTones.shared.prime()
            CallSynthesizedTones.shared.startRingback()
        case .incomingRinging:
            CallSynthesizedTones.shared.prime()
            CallSynthesizedTones.shared.startIncomingRingtone()
        case .connecting:
            CallSynthesizedTones.shared.stopLoopingTones()
        case .connected:
            if priorPhase != .connected {
                CallSynthesizedTones.shared.playConnectTriad()
            } else {
                CallSynthesizedTones.shared.stopLoopingTones()
            }
        case .unstable:
            CallSynthesizedTones.shared.stopLoopingTones()
        case .idle, .ended:
            CallSynthesizedTones.shared.stopLoopingTones()
        }

        lastObservedSessionID = session.id
        lastObservedPhase = session.phase
    }

    private func updateIdleTimerWakeLock(for session: CallSession?) {
        #if canImport(UIKit)
        let keepScreenAwake = (session != nil && session?.mediaKind == .video && session?.phase != .ended && session?.phase != .idle)
        if UIApplication.shared.isIdleTimerDisabled != keepScreenAwake {
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
        #endif
    }
}
