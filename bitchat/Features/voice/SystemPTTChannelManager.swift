//
// SystemPTTChannelManager.swift
// bitchat
//
// Bridges bitchat's live push-to-talk channels to Apple's iOS 16+ PushToTalk
// framework (`PTChannelManager`) for Lock Screen, Dynamic Island, and headset
// button walkie-talkie control. Degrades cleanly when running on macOS, on the
// Simulator, or when the Push-to-Talk capability has not yet been provisioned.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import AVFoundation
import BitLogger
import CryptoKit
import UIKit
#if canImport(PushToTalk)
import PushToTalk
#endif
#endif

#if os(iOS)
/// Describes a bitchat walkie-talkie channel pinned to iOS system Push-to-Talk.
struct SystemPTTChannelInfo: Equatable, Sendable {
    let channelKey: String
    let displayName: String
    let target: VoiceNoteTarget?

    var channelUUID: UUID {
        Self.deterministicUUID(for: channelKey)
    }

    static func deterministicUUID(for channelKey: String) -> UUID {
        let digest = SHA256.hash(data: Data("chat.bitchat.ptt.channel.\(channelKey)".utf8))
        var bytes = Array(digest.prefix(16))
        // Mark as RFC 4122 variant / v5-shaped deterministic UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
#endif

@MainActor
final class SystemPTTChannelManager: ObservableObject {
    static let shared = SystemPTTChannelManager()

    #if os(iOS)
    enum Status: Equatable {
        case idle
        case connecting
        case active(channelName: String)
        case unavailable(reason: String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var activeChannel: SystemPTTChannelInfo?
    @Published private(set) var isSystemTransmitting = false

    /// Callbacks wired by the app root (`ContentView`) so Lock Screen / Dynamic
    /// Island / headset PTT presses drive the exact same capture pipeline.
    var onSystemTransmitBegan: (@MainActor (VoiceNoteTarget?) -> Void)?
    var onSystemTransmitEnded: (@MainActor () -> Void)?

    /// Thread-safe cache of last joined channel metadata for synchronous
    /// `PTChannelRestorationDelegate` queries.
    private final class ChannelNameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var namesByUUID: [UUID: String] = [:]

        func set(_ name: String, for uuid: UUID) {
            lock.withLock { namesByUUID[uuid] = name }
        }

        func name(for uuid: UUID) -> String {
            lock.withLock { namesByUUID[uuid] ?? "bitchat" }
        }
    }

    private let channelNameCache = ChannelNameCache()
    #endif

    #if os(iOS) && canImport(PushToTalk)
    private var channelManager: PTChannelManager?
    private var delegateProxy: SystemPTTDelegateProxy?
    #endif

    private init() {}

    #if os(iOS)
    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    /// Joins or switches the iOS system Push-to-Talk channel (Lock Screen /
    /// Dynamic Island Talk button).
    func joinChannel(_ info: SystemPTTChannelInfo) {
        guard !TestEnvironment.isRunningTests else {
            activeChannel = info
            status = .active(channelName: info.displayName)
            return
        }

        #if canImport(PushToTalk)
        cacheChannelName(info.displayName, for: info.channelUUID)
        status = .connecting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manager = try await self.ensureChannelManager()
                if let current = self.activeChannel, current.channelUUID != info.channelUUID {
                    manager.leaveChannel(channelUUID: current.channelUUID)
                }
                let descriptor = PTChannelDescriptor(
                    name: info.displayName,
                    image: Self.channelAvatarImage()
                )
                self.activeChannel = info
                manager.requestJoinChannel(channelUUID: info.channelUUID, descriptor: descriptor)
            } catch {
                SecureLogger.warning("PTT: system PushToTalk unavailable: \(error.localizedDescription)", category: .session)
                self.activeChannel = nil
                self.status = .unavailable(
                    reason: String(
                        localized: "walkie.system_ptt.capability_required",
                        defaultValue: "Lock-Screen PTT requires the Push to Talk capability on a physical iPhone.",
                        comment: "Status shown when iOS PushToTalk framework cannot activate due to simulator or missing entitlement"
                    )
                )
            }
        }
        #else
        status = .unavailable(
            reason: String(
                localized: "walkie.system_ptt.ios_only",
                defaultValue: "Lock-Screen PTT is available on iPhone.",
                comment: "Status shown on platforms without iOS PushToTalk framework"
            )
        )
        #endif
    }
    #endif

    /// Leaves the active iOS system Push-to-Talk channel (also called on panic wipe).
    func leaveCurrentChannel() {
        #if os(iOS) && canImport(PushToTalk)
        let previousUUID = activeChannel?.channelUUID
        activeChannel = nil
        isSystemTransmitting = false
        status = .idle
        if let manager = channelManager, let uuid = previousUUID {
            manager.leaveChannel(channelUUID: uuid)
        }
        #elseif os(iOS)
        activeChannel = nil
        isSystemTransmitting = false
        status = .idle
        #endif
    }

    /// Updates the Dynamic Island / Lock Screen active remote speaker banner.
    func reportRemoteSpeaker(_ nickname: String?) {
        #if os(iOS) && canImport(PushToTalk)
        guard !TestEnvironment.isRunningTests,
              let manager = channelManager,
              let uuid = activeChannel?.channelUUID else { return }
        let participant: PTParticipant? = nickname.map {
            PTParticipant(name: $0, image: Self.speakerAvatarImage())
        }
        Task {
            do {
                try await manager.setActiveRemoteParticipant(participant, channelUUID: uuid)
            } catch {
                SecureLogger.debug("PTT: failed updating remote speaker on system banner: \(error.localizedDescription)", category: .session)
            }
        }
        #else
        _ = nickname
        #endif
    }

    #if os(iOS)
    nonisolated func cachedChannelName(for uuid: UUID) -> String {
        channelNameCache.name(for: uuid)
    }

    private func cacheChannelName(_ name: String, for uuid: UUID) {
        channelNameCache.set(name, for: uuid)
    }
    #endif

    #if os(iOS) && canImport(PushToTalk)
    private func ensureChannelManager() async throws -> PTChannelManager {
        if let existing = channelManager {
            return existing
        }
        let proxy = SystemPTTDelegateProxy(owner: self)
        let manager = try await PTChannelManager.channelManager(
            delegate: proxy,
            restorationDelegate: proxy
        )
        self.delegateProxy = proxy
        self.channelManager = manager
        return manager
    }

    fileprivate func handleDidJoin(channelUUID: UUID) {
        let name = activeChannel?.displayName ?? cachedChannelName(for: channelUUID)
        status = .active(channelName: name)
        SecureLogger.info("PTT: joined iOS system PushToTalk channel '\(name)'", category: .session)
    }

    fileprivate func handleDidLeave(channelUUID: UUID) {
        if activeChannel?.channelUUID == channelUUID {
            activeChannel = nil
            isSystemTransmitting = false
            status = .idle
        }
    }

    fileprivate func handleTransmitBegan(channelUUID: UUID) {
        guard activeChannel?.channelUUID == channelUUID else { return }
        isSystemTransmitting = true
        onSystemTransmitBegan?(activeChannel?.target)
    }

    fileprivate func handleTransmitEnded(channelUUID: UUID) {
        guard activeChannel?.channelUUID == channelUUID else { return }
        isSystemTransmitting = false
        onSystemTransmitEnded?()
    }

    private static func channelAvatarImage() -> UIImage? {
        UIImage(systemName: "radio.fill")
    }

    private static func speakerAvatarImage() -> UIImage? {
        UIImage(systemName: "waveform.circle.fill")
    }
    #endif
}

#if os(iOS) && canImport(PushToTalk)
private final class SystemPTTDelegateProxy: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate, @unchecked Sendable {
    private weak var owner: SystemPTTChannelManager?

    init(owner: SystemPTTChannelManager) {
        self.owner = owner
        super.init()
    }

    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor [weak owner] in
            owner?.handleDidJoin(channelUUID: channelUUID)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor [weak owner] in
            owner?.handleDidLeave(channelUUID: channelUUID)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [weak owner] in
            owner?.handleTransmitBegan(channelUUID: channelUUID)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [weak owner] in
            owner?.handleTransmitEnded(channelUUID: channelUUID)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        // Mesh-first walkie-talkie streams over local BLE mesh rather than APNs.
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        SecureLogger.debug("PTT: system PushToTalk audio session activated", category: .session)
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        SecureLogger.debug("PTT: system PushToTalk audio session deactivated", category: .session)
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
        .leaveChannel
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        let name = owner?.cachedChannelName(for: channelUUID) ?? "bitchat"
        return PTChannelDescriptor(name: name, image: UIImage(systemName: "radio.fill"))
    }
}
#endif
