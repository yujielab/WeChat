import SwiftUI
import AVFoundation
import WebRTC

/// Voice and video calls: the ring / accept / decline / hang-up signalling
/// over the socket (src/call.js) and the media through RTCEngine.
@MainActor
@Observable
final class CallManager {
    enum Phase: Equatable { case idle, outgoing, incoming, connecting, live, ending }

    var phase: Phase = .idle
    var roomId: String?
    var callId: String?
    var video = false
    var isCaller = false
    var peerUser: User?
    var status = ""
    var muted = false
    var camOff = false
    var speaker = false
    var liveAt: Date?
    var remoteMic = true
    var remoteCam = true
    var expanded = true
    var shaky = false
    var remoteVideo: RTCVideoTrack?
    var localVideo: RTCVideoTrack?
    var frontCamera = true
    /// Where the call's sound goes, as the system has it.
    enum Route: Equatable { case receiver, speaker, bluetooth, headphones, car, other }
    var route: Route = .receiver
    /// Something besides the phone itself to talk through (AirPods, a car,
    /// headphones): then the route is picked from the system's list.
    var externalRoute = false

    private unowned let model: AppModel
    @ObservationIgnored private var engine: RTCEngine?
    @ObservationIgnored private var answered = false
    @ObservationIgnored private var ringTimer: Task<Void, Never>?
    @ObservationIgnored private var wanted: [String: (String, [String])] = [:]
    @ObservationIgnored private var published = false
    @ObservationIgnored private var peers = Set<String>()
    @ObservationIgnored private var pullTries = 0
    @ObservationIgnored private let sounds = CallSounds()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let ringSeconds: Double = 45

    init(model: AppModel) {
        self.model = model
        let center = NotificationCenter.default
        // Voice messages don't play over a call.
        AudioPlayback.shared.callActive = { [weak self] in self?.active ?? false }
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateRoute() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let ended = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .ended
            Task { @MainActor in if ended { self?.resumeAudio() } }
        })
    }

    var active: Bool { phase != .idle }
    var room: Room? { model.room(roomId) }
    var title: String {
        if let room, room.isGroup { return room.title }
        return peerUser?.name ?? room?.title ?? ""
    }

    // MARK: - Starting

    func start(room: Room, video: Bool) {
        if active {
            if roomId == room.id { withAnimation(Motion.morph) { expanded = true } }
            else { model.show(String(localized: "You're already on a call"), error: true) }
            return
        }
        guard model.callsEnabled else { return model.show(String(localized: "Calls aren't available right now"), error: true) }
        guard model.connected else { return model.show(String(localized: "Still connecting…"), error: true) }
        reset()
        AudioPlayback.shared.stop()
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 0..<1000))"
        roomId = room.id
        callId = id
        self.video = video
        isCaller = true
        peerUser = room.peer
        status = String(localized: "Calling…")
        withAnimation(Motion.morph) {
            phase = .outgoing
            expanded = true
        }
        send(["kind": "invite", "media": video ? "video" : "audio"])
        ringTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            guard let self, !Task.isCancelled, self.callId == id, !self.answered else { return }
            self.finish(String(localized: "No answer"), notify: true, result: "missed")
        }
        Task { await begin() }
    }

    // MARK: - Signalling

    private func send(_ extra: [String: Any]) {
        guard let roomId, let callId else { return }
        var msg: [String: Any] = ["t": "call", "room": roomId, "callId": callId]
        for (k, v) in extra { msg[k] = v }
        model.socket.send(msg)
    }

    func handle(_ e: [String: Any]) {
        guard let kind = e["kind"] as? String else { return }
        let from = e["from"] as? String
        if kind == "invite" { incoming(e); return }
        guard let id = e["callId"] as? String, id == callId else { return }
        switch kind {
        case "accept":
            if let from { peers.insert(from) }
            answered = true
            ringTimer?.cancel()
            sounds.stop()
            status = String(localized: "Connecting…")
            if phase == .outgoing { withAnimation(Motion.ui) { phase = .connecting } }
            announce()
        case "tracks":
            guard let from, from != model.me?.id, let sid = e["sessionId"] as? String, let tracks = e["tracks"] as? [String] else { return }
            peers.insert(from)
            wanted[from] = (sid, tracks)
            pullWanted()
        case "state":
            guard from != model.me?.id else { return }
            remoteMic = (e["mic"] as? Bool) ?? true
            remoteCam = (e["cam"] as? Bool) ?? true
        case "ringing":
            if phase == .outgoing { status = String(localized: "Ringing…") }
        case "notified":
            if phase == .outgoing { status = String(localized: "Notified") }
        case "unreachable":
            if phase == .outgoing { status = String(localized: "Not reachable right now") }
        case "decline":
            if room?.isGroup == true && !peers.isEmpty { return }
            finish((e["busy"] as? Bool) == true ? String(localized: "Busy") : String(localized: "Declined"), notify: false)
        case "cancel":
            finish(String(localized: "Call ended"), notify: false)
        case "hangup":
            if let from { peers.remove(from) }
            if room?.isGroup == true && (!peers.isEmpty || (e["ongoing"] as? Bool) == true) { return }
            finish((e["reason"] as? String) == "lost" ? String(localized: "Connection lost") : String(localized: "Call ended"), notify: false)
        case "unstable":
            shaky = true
        case "back":
            shaky = false
        case "alive":
            if answered { announce() }
        case "gone":
            finish(String(localized: "Call ended (connection lost)"), notify: false)
        default:
            break
        }
    }

    private func incoming(_ e: [String: Any]) {
        guard let room = e["room"] as? String, let id = e["callId"] as? String else { return }
        if callId == id {
            send(["kind": "ringing"])
            return
        }
        if active {
            model.socket.send(["t": "call", "kind": "decline", "room": room, "callId": id, "to": e["from"] as? String ?? "", "busy": true])
            return
        }
        reset()
        roomId = room
        callId = id
        video = (e["media"] as? String) == "video"
        isCaller = false
        if let from = e["from"] as? String { peers.insert(from) }
        let caller: User? = model.decode(e["caller"])
        peerUser = caller ?? model.room(room)?.peer
        if var p = peerUser, p.avatar.isEmpty, let known = model.user(p.id) { p.avatar = known.avatar; peerUser = p }
        status = video ? String(localized: "Video call") : String(localized: "Voice call")
        withAnimation(Motion.morph) {
            phase = .incoming
            expanded = true
        }
        send(["kind": "ringing"])
        AudioPlayback.shared.stop()
        sounds.ring()
        ringTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            guard let self, !Task.isCancelled, self.callId == id, !self.answered else { return }
            self.send(["kind": "decline", "missed": true])
            self.finish(String(localized: "Missed call"), notify: false)
        }
    }

    func accept() {
        guard phase == .incoming else { return }
        sounds.stop()
        ringTimer?.cancel()
        send(["kind": "accept"])
        answered = true
        status = String(localized: "Connecting…")
        withAnimation(Motion.ui) { phase = .connecting }
        Task { await begin() }
    }

    func decline() {
        guard phase == .incoming else { return }
        sounds.stop()
        send(["kind": "decline"])
        finish(String(localized: "Declined"), notify: false)
    }

    func hangUp() {
        guard active else { return }
        if answered {
            let duration = liveAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            send(["kind": "hangup", "media": video ? "video" : "audio", "duration": duration])
            finish(String(localized: "Call ended"), notify: false)
        } else if isCaller {
            finish(String(localized: "Cancelled"), notify: true, result: "cancelled")
        } else {
            decline()
        }
    }

    // MARK: - Media

    private func begin() async {
        let granted = await Self.permission(video: video)
        guard active, let me = model.me?.id else { return }
        guard granted else {
            model.show(String(localized: "Allow the microphone (and camera) in Settings to make calls"), error: true)
            hangUp()
            return
        }
        configureAudio()
        if isCaller && !answered && phase == .outgoing { sounds.ringback() }
        var ice: [[String: Any]] = [["urls": "stun:stun.cloudflare.com:3478"]]
        if let data = try? await model.api.raw("POST", "/rtc/turn", json: [:]),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let servers = obj["iceServers"] as? [[String: Any]], !servers.isEmpty {
            ice = servers
        }
        guard active else { return }
        let e = RTCEngine(api: model.api, me: me, video: video)
        engine = e
        e.onRemoteVideo = { [weak self] track in
            withAnimation(Motion.ui) { self?.remoteVideo = track }
        }
        e.onConnected = { [weak self] in self?.goLive() }
        e.onFailed = { [weak self] in self?.finish(String(localized: "Connection lost"), notify: false) }
        e.onShaky = { [weak self] on in self?.shaky = on }
        e.start(iceServers: ice)
        localVideo = e.localVideo
        e.setMicEnabled(!muted)
        do {
            _ = try await e.publish()
            published = true
            if answered { announce() }
            pullWanted()
        } catch {
            model.show(error.userMessage, error: true)
            hangUp()
        }
    }

    private func announce() {
        guard let e = engine, published, let sid = e.sessionId else { return }
        send(["kind": "tracks", "sessionId": sid, "tracks": e.localTrackNames])
        sendState()
    }

    private func sendState() {
        send(["kind": "state", "mic": !muted, "cam": video && !camOff])
    }

    private func pullWanted() {
        guard published, let e = engine else { return }
        let list = wanted
        Task {
            var missing = 0
            for (_, w) in list {
                do { missing += try await e.pull(sessionId: w.0, tracks: w.1) } catch { missing += 1 }
            }
            if missing > 0 && pullTries < 6 {
                pullTries += 1
                try? await Task.sleep(for: .milliseconds(500 * pullTries))
                pullWanted()
            } else {
                pullTries = 0
            }
        }
    }

    private func goLive() {
        guard answered, liveAt == nil, active else { return }
        liveAt = Date()
        status = ""
        sounds.stop()
        Haptics.success()
        withAnimation(Motion.ui) { phase = .live }
        updateProximity()
    }

    // MARK: - Controls

    func toggleMute() {
        muted.toggle()
        engine?.setMicEnabled(!muted)
        sendState()
        Haptics.tap()
    }

    func toggleCamera() {
        guard video else { return }
        camOff.toggle()
        engine?.setCameraEnabled(!camOff)
        sendState()
        Haptics.tap()
    }

    func flip() {
        engine?.flipCamera()
        frontCamera.toggle()
        Haptics.tap()
    }

    func toggleSpeaker() {
        speaker.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
        Haptics.tap()
        updateRoute()
    }

    // MARK: - Sound route, the screen

    /// What the system is playing through now, and whether there's more
    /// than the phone to choose from; the earpiece turns the screen off
    /// against your cheek.
    private func updateRoute() {
        let s = AVAudioSession.sharedInstance()
        let port = s.currentRoute.outputs.first?.portType
        switch port {
        case .builtInSpeaker?: route = .speaker
        case .builtInReceiver?: route = .receiver
        case .bluetoothHFP?, .bluetoothA2DP?, .bluetoothLE?: route = .bluetooth
        case .headphones?, .usbAudio?: route = .headphones
        case .carAudio?: route = .car
        case nil: route = .receiver
        default: route = .other
        }
        if active { speaker = route == .speaker }
        let inputs = s.availableInputs ?? []
        externalRoute = route == .bluetooth || route == .headphones || route == .car || route == .other
            || inputs.contains { $0.portType == .bluetoothHFP || $0.portType == .headsetMic || $0.portType == .carAudio }
        updateProximity()
    }

    /// A voice call held to the ear: the screen goes dark there, so a cheek
    /// can't press anything.
    private func updateProximity() {
        let on = active && !video && route == .receiver && phase != .incoming && phase != .ending
        if UIDevice.current.isProximityMonitoringEnabled != on { UIDevice.current.isProximityMonitoringEnabled = on }
    }

    /// After another app (or a phone call) had the sound: take it back.
    private func resumeAudio() {
        guard active, phase != .incoming else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(true)
        if speaker { try? s.overrideOutputAudioPort(.speaker) }
        updateRoute()
    }

    // MARK: - Ending

    private func finish(_ text: String, notify: Bool, result: String = "missed") {
        guard active else { return }
        if notify {
            send(["kind": "cancel", "media": video ? "video" : "audio", "missed": true, "result": result])
        }
        let heard = engine != nil
        ringTimer?.cancel()
        engine?.close()
        engine = nil
        status = text
        withAnimation(Motion.ui) { phase = .ending }
        if heard { sounds.ended() } else { sounds.stop() }
        updateProximity()
        UIApplication.shared.isIdleTimerDisabled = false
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            sounds.stop()
            if phase == .ending {
                withAnimation(Motion.morph) { reset() }
            }
            if phase == .idle {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func reset() {
        phase = .idle
        roomId = nil
        callId = nil
        answered = false
        published = false
        wanted = [:]
        peers = []
        liveAt = nil
        muted = false
        camOff = false
        speaker = false
        shaky = false
        remoteVideo = nil
        localVideo = nil
        remoteMic = true
        remoteCam = true
        pullTries = 0
        frontCamera = true
        sounds.stop()
        if UIDevice.current.isProximityMonitoringEnabled { UIDevice.current.isProximityMonitoringEnabled = false }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func configureAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try? s.setActive(true)
        updateRoute()
        // A video call is on the speaker, unless something else is connected.
        if video && !externalRoute {
            speaker = true
            try? s.overrideOutputAudioPort(.speaker)
        }
        // A video call keeps the screen on.
        UIApplication.shared.isIdleTimerDisabled = video
        updateRoute()
    }

    static func permission(video: Bool) async -> Bool {
        let mic: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard mic else { return false }
        if !video { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}
