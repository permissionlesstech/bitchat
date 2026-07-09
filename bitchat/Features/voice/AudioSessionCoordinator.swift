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
    /// closures (non-Sendable as stored types) that the coordinator only
    /// ever invokes on the main actor; the token is otherwise immutable,
    /// so handing it across executors (e.g. releasing from a `deinit` hop)
    /// is safe.
    final class Token: @unchecked Sendable {
        fileprivate let onInterrupted: @MainActor () -> Void
        fileprivate let onCategoryEscalated: (@MainActor () -> Void)?

        fileprivate init(
            onInterrupted: @escaping @MainActor () -> Void,
            onCategoryEscalated: (@MainActor () -> Void)?
        ) {
            self.onInterrupted = onInterrupted
            self.onCategoryEscalated = onCategoryEscalated
        }
    }

    static let shared = AudioSessionCoordinator(session: SystemAudioSession())

    private let session: SessionApplying
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

    init(session: SessionApplying) {
        self.session = session
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
    /// existing ones were told to rebuild.
    func acquire(
        _ use: Use,
        onInterrupted: @escaping @MainActor () -> Void,
        onCategoryEscalated: (@MainActor () -> Void)? = nil
    ) async throws -> Token {
        let token = Token(onInterrupted: onInterrupted, onCategoryEscalated: onCategoryEscalated)
        let reconfigured: [Token] = try await withCheckedThrowingContinuation { continuation in
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
            await MainActor.run {
                for holder in reconfigured {
                    (holder.onCategoryEscalated ?? holder.onInterrupted)()
                }
            }
        }
        return token
    }

    /// Drops one holder. Deactivates the session (notifying other apps) only
    /// when the last holder releases. Safe to call more than once, from any
    /// thread (including `deinit` paths): the work is fire-and-forget onto
    /// the session queue, so the blocking deactivation IPC never runs on the
    /// caller.
    func release(_ token: Token) {
        queue.async {
            self.releaseOnQueue(token)
        }
    }

    // MARK: - Queue-confined core

    /// Returns the pre-existing holders whose engines must restart because
    /// this acquire escalated the category (empty otherwise).
    private func activateOnQueue(_ use: Use, registering token: Token) throws -> [Token] {
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

        let existing = Array(holders.values)
        holders[ObjectIdentifier(token)] = token
        return categoryChanged ? existing : []
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

    // MARK: - System events (internal so tests can drive them directly)

    /// A system interruption began: the session is already deactivated by the
    /// OS, so just mark it inactive and tell every holder (on the main actor)
    /// to stop. No auto-resume — the next acquire re-activates.
    func handleInterruptionBegan() async {
        let holders = await onQueue { () -> [Token] in
            self.sessionActive = false
            return Array(self.holders.values)
        }
        await MainActor.run {
            for holder in holders {
                holder.onInterrupted()
            }
        }
    }

    /// The active route's input/output device disappeared (e.g. BT headset
    /// off): holders' engines are wedged against a dead route — stop them.
    func handleRouteDeviceUnavailable() async {
        let holders = await onQueue { Array(self.holders.values) }
        await MainActor.run {
            for holder in holders {
                holder.onInterrupted()
            }
        }
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
