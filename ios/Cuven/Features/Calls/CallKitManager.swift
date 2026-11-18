import Foundation
import CuvenCore
#if canImport(CallKit)
import CallKit
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif

// MARK: - Apple HIG & Developer Documentation Grounding
// - Apple Developer Documentation: CallKit (CXProvider, CXCallController, CXCallUpdate)
// - Apple HIG: System Experiences -> Live Activities & System Call Integration
// - Simulator Safety: iOS Simulator does not support CXCallController call transactions
//   (returns CXErrorCodeRequestTransactionError); CallKitManager guards Simulator cleanly
//   while tracking full deterministic call UUID state.

/// Native `CallKit` (`CXProvider` / `CXCallController`) integration for Cuven audio/video calls.
@MainActor
public final class CallKitManager: NSObject {
    public static let shared = CallKitManager()

    /// Callbacks invoked on `@MainActor` when system CallKit UI (Lock Screen / Dynamic Island / Headset) acts.
    public var onSystemAcceptCall: (() -> Void)?
    public var onSystemEndCall: (() -> Void)?
    public var onSystemToggleMute: ((Bool) -> Void)?

    /// Deterministic mapping between Cuven `CallSession.id` and `CallKit` `UUID`.
    public private(set) var trackedCallUUIDBySessionID: [String: UUID] = [:]
    public private(set) var activeSessionID: String?

    /// True only on physical iOS hardware where `callservicesd` supports CallKit transactions.
    public var isSystemCallKitTransactionSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(CallKit)
        return true
        #else
        return false
        #endif
    }

    #if canImport(CallKit)
    private var provider: CXProvider?
    private let callController = CXCallController()
    #endif

    public override init() {
        super.init()
        #if canImport(CallKit) && !targetEnvironment(simulator)
        let config = CXProviderConfiguration()
        config.localizedName = "Cuven"
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true

        let cxProvider = CXProvider(configuration: config)
        cxProvider.setDelegate(self, queue: nil)
        self.provider = cxProvider
        #endif
    }

    /// Deterministically derives a stable RFC-4122 `UUID` for any backend `CallSession.id`
    /// (including millisecond numeric IDs such as `"1763405000123"` from `views/call.js:62`).
    public static func deterministicUUID(for sessionID: String) -> UUID {
        if let parsed = UUID(uuidString: sessionID) {
            return parsed
        }
        // FNV-1a 128-bit deterministic hash over namespace + sessionID so identical sessionIDs always map to the same UUID.
        let bytes = Array(("us.cuven.callkit." + sessionID).utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            h1 ^= UInt64(byte)
            h1 &*= 0x00000100000001b3
            h2 ^= UInt64(byte ^ 0x5a)
            h2 &*= 0x00000100000001b3
        }
        var uuidBytes: uuid_t = (
            UInt8((h1 >> 56) & 0xff), UInt8((h1 >> 48) & 0xff),
            UInt8((h1 >> 40) & 0xff), UInt8((h1 >> 32) & 0xff),
            UInt8((h1 >> 24) & 0xff), UInt8((h1 >> 16) & 0xff),
            UInt8(((h1 >> 8) & 0x0f) | 0x50), // version 5
            UInt8(h1 & 0xff),
            UInt8(((h2 >> 56) & 0x3f) | 0x80), // RFC-4122 variant
            UInt8((h2 >> 48) & 0xff),
            UInt8((h2 >> 40) & 0xff), UInt8((h2 >> 32) & 0xff),
            UInt8((h2 >> 24) & 0xff), UInt8((h2 >> 16) & 0xff),
            UInt8((h2 >> 8) & 0xff), UInt8(h2 & 0xff)
        )
        return withUnsafePointer(to: &uuidBytes) { ptr in
            ptr.withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) }
        }
    }

    /// Synchronizes `AppStore.activeCall` transitions with native CallKit cleanly.
    public func sync(with session: CallSession?) {
        guard let session else {
            if let currentID = activeSessionID {
                reportCallEnded(sessionID: currentID)
            }
            return
        }

        let uuid = trackedCallUUIDBySessionID[session.id] ?? Self.deterministicUUID(for: session.id)
        trackedCallUUIDBySessionID[session.id] = uuid

        if activeSessionID != session.id {
            if let oldID = activeSessionID {
                reportCallEnded(sessionID: oldID)
            }
            activeSessionID = session.id

            switch session.phase {
            case .incomingRinging:
                reportIncomingCall(session: session, uuid: uuid)
            case .outgoingRinging, .connecting, .connected, .unstable:
                startOutgoingCall(session: session, uuid: uuid)
                if session.phase == .connected {
                    reportOutgoingCallConnected(uuid: uuid)
                }
            case .idle, .ended:
                reportCallEnded(sessionID: session.id)
            }
        } else {
            switch session.phase {
            case .connected:
                reportOutgoingCallConnected(uuid: uuid)
                syncMuteState(isMuted: session.isMuted, uuid: uuid)
            case .ended:
                reportCallEnded(sessionID: session.id)
            case .outgoingRinging, .incomingRinging, .connecting, .unstable:
                syncMuteState(isMuted: session.isMuted, uuid: uuid)
            case .idle:
                break
            }
        }
    }

    public func reportIncomingCall(session: CallSession, uuid: UUID) {
        guard isSystemCallKitTransactionSupported else { return }
        #if canImport(CallKit) && !targetEnvironment(simulator)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: session.peerDisplay)
        update.localizedCallerName = session.peerDisplay
        update.hasVideo = (session.mediaKind == .video)
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        provider?.reportNewIncomingCall(with: uuid, update: update) { _ in }
        #endif
    }

    public func startOutgoingCall(session: CallSession, uuid: UUID) {
        guard isSystemCallKitTransactionSupported else { return }
        #if canImport(CallKit) && !targetEnvironment(simulator)
        let handle = CXHandle(type: .generic, value: session.peerDisplay)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = (session.mediaKind == .video)
        startAction.contactIdentifier = session.peerDisplay
        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                self?.provider?.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
        }
        #endif
    }

    public func reportOutgoingCallConnected(uuid: UUID) {
        guard isSystemCallKitTransactionSupported else { return }
        #if canImport(CallKit) && !targetEnvironment(simulator)
        provider?.reportOutgoingCall(with: uuid, connectedAt: Date())
        #endif
    }

    public func syncMuteState(isMuted: Bool, uuid: UUID) {
        guard isSystemCallKitTransactionSupported else { return }
        #if canImport(CallKit) && !targetEnvironment(simulator)
        let muteAction = CXSetMutedCallAction(call: uuid, muted: isMuted)
        let transaction = CXTransaction(action: muteAction)
        callController.request(transaction) { _ in }
        #endif
    }

    public func reportCallEnded(sessionID: String) {
        let uuid = trackedCallUUIDBySessionID.removeValue(forKey: sessionID)
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        guard isSystemCallKitTransactionSupported, let uuid else { return }
        #if canImport(CallKit) && !targetEnvironment(simulator)
        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                }
            }
        }
        #endif
    }
}

#if canImport(CallKit)
extension CallKitManager: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.trackedCallUUIDBySessionID.removeAll()
            self?.activeSessionID = nil
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureVoiceChatAudioSession()
        action.fulfill()
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureVoiceChatAudioSession()
        action.fulfill()
        Task { @MainActor [weak self] in
            self?.onSystemAcceptCall?()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            self?.activeSessionID = nil
            self?.onSystemEndCall?()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        action.fulfill()
        Task { @MainActor [weak self] in
            self?.onSystemToggleMute?(muted)
        }
    }

    nonisolated public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        configureVoiceChatAudioSession(session: audioSession)
    }

    nonisolated public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated private func configureVoiceChatAudioSession(session: AVAudioSession = .sharedInstance()) {
        try? session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
    }
}
#endif
