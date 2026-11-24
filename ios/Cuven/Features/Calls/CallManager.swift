import SwiftUI
import ActivityKit
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
    /// Asking for the microphone before ringing: a second tap meanwhile waits.
    @ObservationIgnored private var dialing = false
    /// The call in the Dynamic Island and on the Lock Screen.
    @ObservationIgnored private var activity: Activity<CallActivityAttributes>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let ringSeconds: Double = 45

    init(model: AppModel) {
        self.model = model
        let center = NotificationCenter.default
        // Voice messages don't play over a call.
        AudioPlayback.shared.callActive = { [weak self] in self?.active ?? false }
        // The Live Activity's buttons.
        CallControl.hangUp = { [weak self] in self?.hangUp() }
        CallControl.toggleMute = { [weak self] in self?.toggleMute() }
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
        guard !dialing else { return }
        guard model.callsEnabled else { return model.show(String(localized: "Calls aren't available right now"), error: true) }
        guard model.connected else { return model.show(String(localized: "Still connecting…"), error: true) }
        // The microphone (and camera) first: nobody is rung for a call that
        // can't happen, and no record says it was cancelled.
        dialing = true
        Task {
            let granted = await Self.permission(video: video)
            dialing = false
            guard granted else {
                model.show(String(localized: "Allow the microphone (and camera) in Settings to make calls"), error: true)
                return
            }
            guard !active else { return }
            dial(room: room, video: video)
        }
    }

    private func dial(room: Room, video: Bool) {
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
        startActivity()
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
            // The caller's side writes the call's one record, as the web does.
            let busy = (e["busy"] as? Bool) == true
            let missed = (e["missed"] as? Bool) == true
            finish(busy ? String(localized: "Busy") : (missed ? String(localized: "No answer") : String(localized: "Declined")),
                   notify: isCaller && !answered, result: busy ? "busy" : (missed ? "missed" : "declined"))
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
        syncActivity()
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
        startActivity()
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
        syncActivity()
        Task { await begin() }
    }

    func decline() {
        guard phase == .incoming else { return }
        sounds.stop()
        send(["kind": "decline"])
        finish(String(localized: "Declined"), notify: false)
    }

    func hangUp() {
        // Once: a second tap (or the Lock Screen's button) while it's ending does nothing.
        guard active, phase != .ending else { return }
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
        // Tied to this call: if it ended while this waited (and the next one
        // was dialled meanwhile), nothing is built for it.
        let id = callId
        let granted = await Self.permission(video: video)
        guard active, phase != .ending, callId == id, engine == nil, let me = model.me?.id else { return }
        guard granted else {
            model.show(String(localized: "Allow the microphone (and camera) in Settings to make calls"), error: true)
            fail()
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
        guard active, phase != .ending, callId == id, engine == nil else { return }
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
            guard callId == id, engine === e else { e.close(); return }
            published = true
            if answered { announce() }
            pullWanted()
        } catch {
            // A call that has already ended (or been replaced) isn't failed again.
            guard callId == id, engine === e else { e.close(); return }
            model.show(error.userMessage, error: true)
            fail()
        }
    }

    /// It couldn't get going: an unanswered call's record says the
    /// connection failed (not that you cancelled it); otherwise it's a hang-up.
    private func fail() {
        if isCaller && !answered { finish(String(localized: "Connection failed"), notify: true, result: "failed") }
        else { hangUp() }
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
        syncActivity()
    }

    // MARK: - Controls

    func toggleMute() {
        muted.toggle()
        engine?.setMicEnabled(!muted)
        sendState()
        Haptics.tap()
        syncActivity()
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

    // MARK: - Live Activity

    /// The call in the Dynamic Island (on iPhone Duo it grows out of the
    /// outer camera's region) and on the Lock Screen, with Mute and End.
    private func startActivity() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let name = title.isEmpty ? String(localized: "Call") : title
        let initials = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        let attributes = CallActivityAttributes(name: name, initials: initials.isEmpty ? "·" : initials, video: video)
        activity = try? Activity.request(attributes: attributes, content: .init(state: activityState, staleDate: nil))
    }

    private var activityState: CallActivityAttributes.ContentState {
        .init(status: phase == .live ? "" : status, liveSince: liveAt, muted: muted)
    }

    private func syncActivity() {
        guard let activity else { return }
        let state = activityState
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        let state = CallActivityAttributes.ContentState(status: status, liveSince: nil, muted: muted)
        Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 2)) }
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
        // Ended once: whatever else arrives while it closes adds nothing.
        guard active, phase != .ending else { return }
        if notify {
            send(["kind": "cancel", "media": video ? "video" : "audio", "missed": true, "result": result])
        }
        let heard = engine != nil
        ringTimer?.cancel()
        engine?.close()
        engine = nil
        status = text
        withAnimation(Motion.ui) { phase = .ending }
        endActivity()
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
