//
// AudioSessionCoordinator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import Foundation

/// The raw audio-session calls the coordinator makes, abstracted so the
/// state machine is unit-testable with a mock (and compiles on the macOS
/// test host, where `AVAudioSession` doesn't exist).
///
/// Calls arrive on the coordinator's private serial queue — never the main
/// thread. `setCategory`/`setActive` block on IPC to the audio server
/// (observed >1 s under contention on device, tripping the system gesture
/// gate), and Apple explicitly recommends activating the session off the
/// main thread.
protocol SessionApplying: Sendable {
    func setCategory(_ category: AudioSessionCoordinator.Category) throws
    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws
}

/// Sole owner of `AVAudioSession` category/activation for voice features.
///
/// Talk-over means capture (push-to-talk) and playback (inbound bursts,
/// voice notes) can be live simultaneously; letting each engine configure
/// the shared session directly made them stomp each other's category and
/// route mid-flight (the AURemoteIO -10851 dead-input class). Instead every
/// client acquires a `Token` and the coordinator:
///
/// - reference-counts activation: `setActive(true)` only on the first
///   holder, `setActive(false, notifyOthersOnDeactivation:)` only when the
///   last one releases — no client can deactivate another's session;
/// - keeps one escalating category: playback-only holders get `.playback`,
///   any capture holder escalates to `.playAndRecord`, and the category is
///   never downgraded while anyone still holds a token (capture ending must
///   not yank the route out from under live playback);
/// - fans out `onInterrupted` on system interruptions and when the active
///   route's device disappears (no auto-resume: bursts are transient, the
///   next press or burst simply re-acquires). The escalating category change
///   fans out separately as `onCategoryEscalated` — the session stays live,
///   so holders that can rebuild their engine against the new configuration
///   keep playing (talk-over is bidirectional); holders that don't provide
///   it fall back to `onInterrupted`.
///
/// Threading: all state lives on a private serial queue, which both
/// serializes rapid acquire/release pairs and keeps the blocking session IPC
/// off the main thread (`acquire` is `async` for exactly that hop; `release`
/// is fire-and-forget onto the queue). Holder callbacks always run on the
/// main actor.
///
/// Microphone *permission* queries stay with their callers; this type owns
/// only category and activation.
///
/// `@unchecked Sendable`: every mutable property is confined to `queue`.
final class AudioSessionCoordinator: @unchecked Sendable {
    enum Use {
        case playback
        case capture
    }

    /// The session category the coordinator has applied (the `SessionApplying`
    /// adapter maps these to concrete `AVAudioSession` category/mode/options).
    enum Category {
        case playback
        case playAndRecord
    }

    /// Opaque handle for one client's hold on the session. Release exactly
    /// once when done (extra releases are ignored).
    ///
    /// `@unchecked` because the stored callbacks are `@MainActor`-isolated
    /// closures (non-Sendable as stored types). Lifecycle state is protected
    /// by `stateLock`, and callbacks are only ever invoked on the main actor.
    final class Token: @unchecked Sendable {
        fileprivate enum CallbackKind: Sendable {
            case interrupted
            case categoryEscalated
        }

        /// A callback snapshot is only valid for the lifecycle epoch in which
        /// it was captured. `release` advances the epoch synchronously before
        /// its queue work, so a callback already headed to the main actor can't
        /// reach a client that has since released this token and reacquired a
        /// different one.
        fileprivate struct CallbackTicket: Sendable {
            let token: Token
            let kind: CallbackKind
            let lifecycleEpoch: UInt64
        }

        private enum Lifecycle {
            /// Registered on the session queue, but `acquire` has not yet
            /// returned into the client's main-actor call frame.
            case acquiring
            case ready
            case released
        }

        fileprivate let onInterrupted: @MainActor () -> Void
        fileprivate let onCategoryEscalated: (@MainActor () -> Void)?
        private let stateLock = NSLock()
        private var lifecycle = Lifecycle.acquiring
        private var lifecycleEpoch: UInt64 = 0
        /// A terminal event that lands while the token is registered but not
        /// yet handed off invalidates the acquire before its caller can start.
        private var terminalEventPendingHandoff = false

        fileprivate init(
            onInterrupted: @escaping @MainActor () -> Void,
            onCategoryEscalated: (@MainActor () -> Void)?
        ) {
            self.onInterrupted = onInterrupted
            self.onCategoryEscalated = onCategoryEscalated
        }

        /// Records an event at the same linearization point at which the
        /// coordinator snapshots its holders. An acquiring token cannot safely
        /// receive a callback yet: terminal events invalidate the acquire,
        /// while category escalation needs no callback because its engine will
        /// start against the already-escalated configuration.
        fileprivate func record(_ kind: CallbackKind) -> CallbackTicket? {
            stateLock.withLock {
                switch lifecycle {
                case .acquiring:
                    switch kind {
                    case .interrupted:
                        terminalEventPendingHandoff = true
                    case .categoryEscalated:
                        break
                    }
                    return nil
                case .ready:
                    return CallbackTicket(token: self, kind: kind, lifecycleEpoch: lifecycleEpoch)
                case .released:
                    return nil
                }
            }
        }

        /// Completes the main-actor ownership handoff if no terminal event
        /// invalidated it. Because `acquire` itself is main-actor isolated, a
        /// successful handoff returns directly into the caller without another
        /// actor hop; no callback can interleave before the caller stores the
        /// returned token.
        fileprivate func completeHandoff() -> Bool {
            stateLock.withLock {
                guard lifecycle == .acquiring,
                      !terminalEventPendingHandoff
                else { return false }
                lifecycle = .ready
                return true
            }
        }

        /// Marks the token dead synchronously, before the asynchronous holder
        /// removal. Returns false for an already-released token.
        fileprivate func markReleased() -> Bool {
            stateLock.withLock {
                guard lifecycle != .released else { return false }
                lifecycle = .released
                lifecycleEpoch &+= 1
                terminalEventPendingHandoff = false
                return true
            }
        }

        /// Revalidates a queue snapshot at the main-actor delivery boundary.
        /// The lock is deliberately released before invoking client code: real
        /// callbacks commonly call `release` on this same token.
        @MainActor
        fileprivate func deliver(_ ticket: CallbackTicket) {
            let isLive = stateLock.withLock {
                lifecycle == .ready && lifecycleEpoch == ticket.lifecycleEpoch
            }
            guard isLive else { return }
            switch ticket.kind {
            case .interrupted:
                onInterrupted()
            case .categoryEscalated:
                (onCategoryEscalated ?? onInterrupted)()
            }
        }
    }

    /// Deterministic suspension points for lifecycle race tests. Production
    /// instances use the nil defaults; the hooks never move session calls off
    /// the coordinator queue or callback execution off the main actor.
    struct TestingHooks: Sendable {
        let beforeAcquireHandoff: (@Sendable () async -> Void)?
        let beforeCallbackDelivery: (@Sendable () async -> Void)?

        init(
            beforeAcquireHandoff: (@Sendable () async -> Void)? = nil,
            beforeCallbackDelivery: (@Sendable () async -> Void)? = nil
        ) {
            self.beforeAcquireHandoff = beforeAcquireHandoff
            self.beforeCallbackDelivery = beforeCallbackDelivery
        }
    }

    static let shared = AudioSessionCoordinator(session: SystemAudioSession())

    private let session: SessionApplying
    private let testingHooks: TestingHooks
    /// Confines all mutable state, serializes whole acquire/release
    /// operations (two rapid presses can't interleave their category and
    /// activation calls), and hosts the blocking session IPC off main.
    private let queue = DispatchQueue(label: "chat.bitchat.audio-session", qos: .userInitiated)

    // Queue-confined state.
    private var holders: [ObjectIdentifier: Token] = [:]
    private var currentCategory: Category?
    private var sessionActive = false
    /// Written once in init, read in deinit — never touched concurrently.
    private var observers: [NSObjectProtocol] = []

    init(session: SessionApplying, testingHooks: TestingHooks = TestingHooks()) {
        self.session = session
        self.testingHooks = testingHooks
        observeSystemNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Configures + activates the session for `use` and registers the caller
    /// as a holder. The blocking `AVAudioSession` calls run on the session
    /// queue — the caller suspends instead of stalling its thread (a PTT
    /// press used to block main >1 s in `setActive`, tripping the system
    /// gesture gate). `onInterrupted` fires (on the main actor) when the
    /// client must stop using the session: a system interruption began or
    /// its route's device went away. The client should stop its engine,
    /// finalize any artifacts, and release — resuming means acquiring again.
    ///
    /// `onCategoryEscalated` fires instead when the session category
    /// escalated underneath the holder (a capture client joined): the session
    /// stays active, so a holder that can rebuild its engine against the new
    /// configuration should restart and keep going. Holders that pass `nil`
    /// get `onInterrupted` for escalation too. Escalation is delivered before
    /// `acquire` returns, so the new holder starts its engine strictly after
    /// existing ones were told to rebuild. Main-actor isolation is also the
    /// ownership handoff boundary: if interruption or route loss lands after
    /// queue registration but before that boundary, the provisional holder is
    /// removed and `acquire` throws `CancellationError` instead of returning a
    /// token whose callback already fired.
    @MainActor
    func acquire(
        _ use: Use,
        onInterrupted: @escaping @MainActor () -> Void,
        onCategoryEscalated: (@MainActor () -> Void)? = nil
    ) async throws -> Token {
        let token = Token(onInterrupted: onInterrupted, onCategoryEscalated: onCategoryEscalated)
        let reconfigured: [Token.CallbackTicket] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.activateOnQueue(use, registering: token))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Escalating playback -> playAndRecord reconfigures the hardware
        // route; engines started against the old configuration must restart.
        if !reconfigured.isEmpty {
            SecureLogger.info("AudioSession: category escalated to playAndRecord with \(reconfigured.count) live holder(s)", category: .session)
            await deliver(reconfigured)
        }
        if let beforeAcquireHandoff = testingHooks.beforeAcquireHandoff {
            await beforeAcquireHandoff()
        }
        guard token.completeHandoff() else {
            // A call/Siri interruption or route loss landed after registration
            // but before ownership handoff. Remove the provisional holder and
            // fail instead of starting a client engine after the stop event.
            release(token)
            throw CancellationError()
        }
        return token
    }

    /// Drops one holder. Deactivates the session (notifying other apps) only
    /// when the last holder releases. Safe to call more than once, from any
    /// thread (including `deinit` paths): the work is fire-and-forget onto
    /// the session queue, so the blocking deactivation IPC never runs on the
    /// caller.
    func release(_ token: Token) {
        guard token.markReleased() else { return }
        queue.async {
            self.releaseOnQueue(token)
        }
    }

    // MARK: - Queue-confined core

    /// Returns callback tickets for pre-existing live holders whose engines
    /// must restart because this acquire escalated the category.
    private func activateOnQueue(_ use: Use, registering token: Token) throws -> [Token.CallbackTicket] {
        let target: Category = (use == .capture || currentCategory == .playAndRecord) ? .playAndRecord : .playback
        let categoryChanged = target != currentCategory
        let previousCategory = currentCategory
        if categoryChanged {
            try session.setCategory(target)
            currentCategory = target
        }
        if !sessionActive {
            do {
                try session.setActive(true, notifyOthersOnDeactivation: false)
            } catch {
                // Activation failed (e.g. a phone call owns the hardware):
                // with no holder registered, an escalated category recorded
                // here would stick and pin later playback-only acquires to
                // .playAndRecord. Existing holders keep the category the
                // hardware really has.
                if categoryChanged, holders.isEmpty {
                    currentCategory = previousCategory
                }
                throw error
            }
            sessionActive = true
        }

        let reconfigured = categoryChanged
            ? holders.values.compactMap { $0.record(.categoryEscalated) }
            : []
        holders[ObjectIdentifier(token)] = token
        return reconfigured
    }

    private func releaseOnQueue(_ token: Token) {
        guard holders.removeValue(forKey: ObjectIdentifier(token)) != nil else { return }
        guard holders.isEmpty else { return }
        currentCategory = nil
        guard sessionActive else { return }
        sessionActive = false
        do {
            try session.setActive(false, notifyOthersOnDeactivation: true)
        } catch {
            SecureLogger.error("AudioSession: deactivation failed: \(error)", category: .session)
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    @MainActor
    private func deliver(_ tickets: [Token.CallbackTicket]) async {
        guard !tickets.isEmpty else { return }
        if let beforeCallbackDelivery = testingHooks.beforeCallbackDelivery {
            await beforeCallbackDelivery()
        }
        for ticket in tickets {
            ticket.token.deliver(ticket)
        }
    }

    // MARK: - System events (internal so tests can drive them directly)

    /// A system interruption began: the session is already deactivated by the
    /// OS, so just mark it inactive and tell every ready holder (on the main
    /// actor) to stop. A provisional acquiring holder is invalidated instead.
    /// No auto-resume — the next acquire re-activates.
    func handleInterruptionBegan() async {
        let tickets = await onQueue { () -> [Token.CallbackTicket] in
            self.sessionActive = false
            return self.holders.values.compactMap { $0.record(.interrupted) }
        }
        await deliver(tickets)
    }

    /// The active route's input/output device disappeared (e.g. BT headset
    /// off): ready holders' engines are wedged against a dead route — stop
    /// them; invalidate a holder whose acquire has not returned yet.
    func handleRouteDeviceUnavailable() async {
        let tickets = await onQueue {
            self.holders.values.compactMap { $0.record(.interrupted) }
        }
        await deliver(tickets)
    }

    /// Test hook: suspends until every session operation enqueued before this
    /// call — including fire-and-forget `release`s — has completed.
    func drain() async {
        await onQueue {}
    }

    private func observeSystemNotifications() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began,
                  let self
            else { return }
            SecureLogger.info("AudioSession: interruption began", category: .session)
            Task { await self.handleInterruptionBegan() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
                  let self
            else { return }
            SecureLogger.info("AudioSession: route device became unavailable", category: .session)
            Task { await self.handleRouteDeviceUnavailable() }
        })
        #endif
    }
}

// MARK: - Production adapter

#if os(iOS)
private struct SystemAudioSession: SessionApplying {
    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        let session = AVAudioSession.sharedInstance()
        switch category {
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        case .playAndRecord:
            // allowBluetoothHFP is not available on iOS Simulator
            #if targetEnvironment(simulator)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            #else
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP, .mixWithOthers]
            )
            #endif
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(
            active,
            options: notifyOthersOnDeactivation ? [.notifyOthersOnDeactivation] : []
        )
    }
}
#else
/// macOS has no app-level audio session; the coordinator still runs its
/// bookkeeping so client code is identical across platforms.
private struct SystemAudioSession: SessionApplying {
    func setCategory(_ category: AudioSessionCoordinator.Category) throws {}
    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {}
}
#endif
