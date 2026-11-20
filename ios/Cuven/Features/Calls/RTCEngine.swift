import Foundation
import AVFoundation
import WebRTC

/// One device's media for a call on Cloudflare Realtime (the SFU), spoken
/// through the hub's /rtc proxy exactly as the web client does
/// (public/js/views/call.js): publish this side's tracks once, pull each
/// other participant's tracks by name, renegotiate when the SFU asks.
/// Every change to the session waits for the one before it.
final class RTCEngine: NSObject, RTCPeerConnectionDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let api: APIClient
    private let me: String
    private let video: Bool
    private var pc: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var usingFront = true
    private var chain: Task<Void, Never>?
    private var pulled = Set<String>()

    private(set) var sessionId: String?
    private(set) var localTrackNames: [String] = []
    private(set) var audioTrack: RTCAudioTrack?
    private(set) var localVideo: RTCVideoTrack?

    /// Called on the main queue.
    var onRemoteVideo: ((RTCVideoTrack) -> Void)?
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onShaky: ((Bool) -> Void)?

    init(api: APIClient, me: String, video: Bool) {
        self.api = api
        self.me = me
        self.video = video
        super.init()
    }

    // MARK: setup

    func start(iceServers: [[String: Any]]) {
        let config = RTCConfiguration()
        config.iceServers = iceServers.compactMap { s in
            let urls: [String] = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String)
        }
        if config.iceServers.isEmpty { config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])] }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "\(me)-audio")
        if video {
            let source = Self.factory.videoSource()
            capturer = RTCCameraVideoCapturer(delegate: source)
            localVideo = Self.factory.videoTrack(with: source, trackId: "\(me)-video")
            startCamera(front: true)
        }
    }

    private func startCamera(front: Bool) {
        guard let capturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == (front ? .front : .back) }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // The format closest to 1280×720.
        let format = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) + abs(Int(da.height) - 720) < abs(Int(db.width) - 1280) + abs(Int(db.height) - 720)
        }
        guard let format else { return }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        capturer.startCapture(with: device, format: format, fps: fps)
        usingFront = front
    }

    func flipCamera() {
        capturer?.stopCapture { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.startCamera(front: !self.usingFront) }
        }
    }

    var isFrontCamera: Bool { usingFront }

    func setMicEnabled(_ on: Bool) { audioTrack?.isEnabled = on }
    func setCameraEnabled(_ on: Bool) { localVideo?.isEnabled = on }

    // MARK: SFU session

    private func queued(_ op: @escaping () async throws -> Void) async throws {
        let previous = chain
        let task = Task<Result<Void, Error>, Never> {
            await previous?.value
            do {
                try await op()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        chain = Task { _ = await task.value }
        try await task.value.get()
    }

    /// Publishes this side's microphone (and camera): returns the track names to announce.
    func publish() async throws -> (String, [String]) {
        var result: (String, [String]) = ("", [])
        try await queued { [self] in
            guard let pc else { throw APIError(message: "No connection", status: 0) }
            let initSend = RTCRtpTransceiverInit()
            initSend.direction = .sendOnly
            var transceivers: [(RTCRtpTransceiver, String)] = []
            if let audioTrack, let t = pc.addTransceiver(with: audioTrack, init: initSend) { transceivers.append((t, "audio")) }
            if let localVideo {
                let initVideo = RTCRtpTransceiverInit()
                initVideo.direction = .sendOnly
                if let t = pc.addTransceiver(with: localVideo, init: initVideo) { transceivers.append((t, "video")) }
            }
            let offer = try await self.offer()
            try await self.setLocal(offer)
            let sessionData = try await api.raw("POST", "/rtc/sessions/new", json: [:])
            guard let session = (try? JSONSerialization.jsonObject(with: sessionData)) as? [String: Any],
                  let sid = session["sessionId"] as? String else { throw APIError(message: String(localized: "Call service is temporarily unavailable"), status: 502) }
            self.sessionId = sid
            let tracks: [[String: Any]] = transceivers.map { t, kind in
                ["location": "local", "mid": t.mid, "trackName": "\(me)-\(kind)"]
            }
            let body: [String: Any] = [
                "sessionDescription": ["type": "offer", "sdp": pc.localDescription?.sdp ?? offer.sdp],
                "tracks": tracks
            ]
            let data = try await api.raw("POST", "/rtc/sessions/\(sid)/tracks/new", json: body)
            guard let res = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let desc = res["sessionDescription"] as? [String: Any], let sdp = desc["sdp"] as? String else {
                throw APIError(message: String(localized: "Call service is temporarily unavailable"), status: 502)
            }
            if let list = res["tracks"] as? [[String: Any]], list.contains(where: { $0["errorCode"] != nil }) {
                throw APIError(message: String(localized: "Call service is temporarily unavailable"), status: 502)
            }
            try await self.setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
            let names = tracks.compactMap { $0["trackName"] as? String }
            self.localTrackNames = names
            result = (sid, names)
        }
        return result
    }

    /// Pulls another participant's published tracks. Returns how many are still missing.
    @discardableResult
    func pull(sessionId remote: String, tracks: [String]) async throws -> Int {
        var missing = 0
        try await queued { [self] in
            guard let pc, let sid = self.sessionId else { return }
            let want = tracks.filter { !pulled.contains("\(remote)/\($0)") }
            guard !want.isEmpty else { return }
            let body: [String: Any] = ["tracks": want.map { ["location": "remote", "sessionId": remote, "trackName": $0] }]
            let data = try await api.raw("POST", "/rtc/sessions/\(sid)/tracks/new", json: body)
            let res = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let results = res["tracks"] as? [[String: Any]] ?? []
            for name in want {
                let r = results.first { ($0["trackName"] as? String) == name && (($0["sessionId"] as? String) == nil || ($0["sessionId"] as? String) == remote) }
                if let r, r["errorCode"] == nil { pulled.insert("\(remote)/\(name)") } else { missing += 1 }
            }
            if (res["requiresImmediateRenegotiation"] as? Bool) == true,
               let desc = res["sessionDescription"] as? [String: Any], let sdp = desc["sdp"] as? String {
                try await self.setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                let answer = try await self.answer()
                try await self.setLocal(answer)
                let reneg: [String: Any] = ["sessionDescription": ["type": "answer", "sdp": pc.localDescription?.sdp ?? answer.sdp]]
                try await api.raw("PUT", "/rtc/sessions/\(sid)/renegotiate", json: reneg)
            }
        }
        return missing
    }

    func close() {
        capturer?.stopCapture()
        capturer = nil
        localVideo = nil
        audioTrack = nil
        pc?.close()
        pc = nil
        chain?.cancel()
    }

    // MARK: async wrappers

    private func offer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc?.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? APIError(message: "offer", status: 0)) }
            }
        }
    }

    private func answer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc?.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? APIError(message: "answer", status: 0)) }
            }
        }
    }

    private func setLocal(_ d: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc?.setLocalDescription(d) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    private func setRemote(_ d: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc?.setRemoteDescription(d) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            switch newState {
            case .connected, .completed:
                self?.onShaky?(false)
                self?.onConnected?()
            case .disconnected:
                self?.onShaky?(true)
            case .failed, .closed:
                self?.onFailed?()
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        DispatchQueue.main.async { [weak self] in
            if let v = track as? RTCVideoTrack { self?.onRemoteVideo?(v) }
            self?.onConnected?()
        }
    }
}
