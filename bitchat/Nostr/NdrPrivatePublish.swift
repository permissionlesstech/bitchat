import Foundation

/// One anonymous, send-only connection per relay and attempt. Never subscribes,
/// authenticates, or falls back to a shared receiving socket.
@MainActor
final class NdrPrivatePublish {
    private struct Target {
        let session: NostrRelaySessionProtocol
        let socket: NostrRelayConnectionProtocol
        var framesRemaining = 16
    }
    private var targets: [UUID: Target] = [:]
    private var completion: ((Bool) -> Void)?
    private let eventID: String

    init(eventID: String, completion: @escaping (Bool) -> Void) {
        self.eventID = eventID
        self.completion = completion
    }

    func start(
        event: NostrEvent, urls: [String],
        makeSession: () -> NostrRelaySessionProtocol
    ) {
        guard let data = try? JSONEncoder().encode(NostrRequest.event(event)) else { finish(false); return }
        let frame = String(decoding: data, as: UTF8.self)
        for raw in urls {
            guard let url = URL(string: raw), url.user == nil, url.password == nil else { continue }
            let session = makeSession()
            targets[UUID()] = Target(session: session, socket: session.webSocketTask(with: url))
        }
        guard !targets.isEmpty else { finish(false); return }
        for (id, target) in targets {
            target.socket.resume()
            receive(id)
            target.socket.send(.string(frame)) { [weak self] error in
                Task { @MainActor in
                    if error != nil { self?.settle(id, accepted: false) }
                }
            }
        }
    }

    func cancel() { finish(false) }

    private func receive(_ id: UUID) {
        guard let target = targets[id] else { return }
        target.socket.receive { [weak self] result in
            Task { @MainActor in self?.received(result, from: id) }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, from id: UUID) {
        guard var target = targets[id], completion != nil else { return }
        guard case .success(let message) = result else { settle(id, accepted: false); return }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: settle(id, accepted: false); return
        }
        guard data.count <= 64 * 1024,
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let kind = frame.first as? String
        else { settle(id, accepted: false); return }
        if kind == "AUTH" { settle(id, accepted: false); return }
        if kind == "OK", frame.count >= 3, frame[1] as? String == eventID {
            let accepted = frame[2] as? Bool == true
            let duplicate = frame.count > 3 && (frame[3] as? String)?.hasPrefix("duplicate:") == true
            settle(id, accepted: accepted || duplicate)
            return
        }
        target.framesRemaining -= 1
        guard target.framesRemaining > 0 else { settle(id, accepted: false); return }
        targets[id] = target
        receive(id)
    }

    private func settle(_ id: UUID, accepted: Bool) {
        guard let target = targets.removeValue(forKey: id) else { return }
        target.socket.cancel(with: .normalClosure, reason: nil)
        target.session.invalidate()
        if accepted || targets.isEmpty { finish(accepted) }
    }

    private func finish(_ accepted: Bool) {
        guard let callback = completion else { return }
        completion = nil
        let pending = targets.values
        targets.removeAll()
        for target in pending {
            target.socket.cancel(with: .goingAway, reason: nil)
            target.session.invalidate()
        }
        callback(accepted)
    }
}
