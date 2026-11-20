import Foundation
import UIKit

/// A self-healing WebSocket to /api/ws (public/js/api.js connectSocket):
/// reconnects with backoff, at once when the app comes back to the
/// foreground, and keeps itself alive with pings.
@MainActor
final class Socket {
    private let api: APIClient
    private var task: URLSessionWebSocketTask?
    private var retry = 0
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var stopped = true
    private var generation = 0

    var onEvent: (([String: Any]) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var connected = false

    init(api: APIClient) {
        self.api = api
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }
    }

    func start() {
        stopped = false
        retry = 0
        open()
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    func wake() {
        guard !stopped else { return }
        if task == nil || !connected {
            retry = 0
            open()
        } else {
            send(["t": "ping"])
        }
    }

    func send(_ obj: [String: Any]) {
        guard let task, connected,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func open() {
        reconnectWork?.cancel()
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let gen = generation
        var comps = URLComponents(url: api.url("/api/ws", query: ["tz": String(APIClient.tzOffset)]), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        var r = URLRequest(url: comps.url!)
        api.authorize(&r)
        r.timeoutInterval = 15
        let t = api.session.webSocketTask(with: r)
        task = t
        t.resume()
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        if !self.connected {
                            self.connected = true
                            self.retry = 0
                            self.startPing()
                            self.onOpen?()
                        }
                        self.onEvent?(obj)
                    }
                    self.receive(t, gen)
                case .failure:
                    self.closed(gen)
                }
            }
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(["t": "ping"]) }
        }
    }

    private func closed(_ gen: Int) {
        guard gen == generation else { return }
        pingTimer?.invalidate()
        let was = connected
        connected = false
        task = nil
        if was { onClose?() }
        guard !stopped else { return }
        let delay = min(10.0, 0.6 * pow(2.0, Double(retry)))
        retry += 1
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.open() }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
