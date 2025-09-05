//
// LocalizationHelper.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Localization Helper

/// Helper function for localized strings
/// Usage: L("key") or L("key", arguments)
func L(_ key: String, _ args: CVarArg...) -> String {
    let localizedString = NSLocalizedString(key, comment: "")
    
    if args.isEmpty {
        return localizedString
    } else {
        return String(format: localizedString, arguments: args)
    }
}

// MARK: - Localized String Extensions

extension String {
    /// Returns localized version of the string
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
    
    /// Returns localized version with format arguments
    func localized(with args: CVarArg...) -> String {
        let localizedString = NSLocalizedString(self, comment: "")
        return String(format: localizedString, arguments: args)
    }
}

// MARK: - Common Localized Strings

struct LocalizedStrings {
    
    // MARK: - App Info
    struct App {
        static let name = L("app.name")
        static let tagline = L("app.tagline")
    }
    
    // MARK: - Features
    struct Features {
        static let title = L("features.title")
        static let offlineCommunication = L("features.offline_communication")
        static let offlineCommunicationDescription = L("features.offline_communication.description")
        static let encryption = L("features.encryption")
        static let encryptionDescription = L("features.encryption.description")
        static let extendedRange = L("features.extended_range")
        static let extendedRangeDescription = L("features.extended_range.description")
        static let mentions = L("features.mentions")
        static let mentionsDescription = L("features.mentions.description")
        static let favorites = L("features.favorites")
        static let favoritesDescription = L("features.favorites.description")
        static let geohash = L("features.geohash")
        static let geohashDescription = L("features.geohash.description")
    }
    
    // MARK: - Privacy
    struct Privacy {
        static let title = L("privacy.title")
        static let noTracking = L("privacy.no_tracking")
        static let noTrackingDescription = L("privacy.no_tracking.description")
        static let ephemeral = L("privacy.ephemeral")
        static let ephemeralDescription = L("privacy.ephemeral.description")
        static let panic = L("privacy.panic")
        static let panicDescription = L("privacy.panic.description")
    }
    
    // MARK: - How to Use
    struct HowToUse {
        static let title = L("how_to_use.title")
        static let instructionNickname = L("how_to_use.instruction.nickname")
        static let instructionChannels = L("how_to_use.instruction.channels")
        static let instructionSidebar = L("how_to_use.instruction.sidebar")
        static let instructionDM = L("how_to_use.instruction.dm")
        static let instructionClear = L("how_to_use.instruction.clear")
        static let instructionCommands = L("how_to_use.instruction.commands")
    }
    
    // MARK: - Warning
    struct Warning {
        static let title = L("warning.title")
        static let message = L("warning.message")
    }
    
    // MARK: - UI Elements
    struct UI {
        static let close = L("ui.close")
        static let done = L("ui.done")
        static let cancel = L("ui.cancel")
        static let ok = L("ui.ok")
        static let settings = L("ui.settings")
    }
    
    // MARK: - Location Channels
    struct LocationChannels {
        static let title = L("location_channels.title")
        static let description = L("location_channels.description")
        static let getLocation = L("location_channels.get_location")
        static let permissionDenied = L("location_channels.permission_denied")
        static let openSettings = L("location_channels.open_settings")
        static let removeAccess = L("location_channels.remove_access")
        static let teleport = L("location_channels.teleport")
        static let bookmarked = L("location_channels.bookmarked")
        static let findingChannels = L("location_channels.finding_channels")
        static let geohashPlaceholder = L("location_channels.geohash_placeholder")
        static let invalidGeohash = L("location_channels.invalid_geohash")
    }
    
    // MARK: - Chat UI
    struct Chat {
        static let inputPlaceholder = L("chat.input_placeholder")
        static let peopleTitle = L("chat.people_title")
        static let nicknamePlaceholder = L("chat.nickname_placeholder")
    }
    
    // MARK: - Channel Types
    struct Channel {
        static let mesh = L("channel.mesh")
        static func peopleCount(_ count: Int) -> String {
            if count == 1 {
                return L("channel.people_count.singular", count)
            } else {
                return L("channel.people_count.plural", count)
            }
        }
    }
    
    // MARK: - Geohash Levels
    struct GeohashLevel {
        static let region = L("geohash.level.region")
        static let province = L("geohash.level.province")
        static let city = L("geohash.level.city")
        static let neighborhood = L("geohash.level.neighborhood")
        static let block = L("geohash.level.block")
    }
    
    // MARK: - Bluetooth
    struct Bluetooth {
        static let requiredTitle = L("bluetooth.required.title")
        static let rangeMetric = L("bluetooth.range.metric")
        static let rangeImperial = L("bluetooth.range.imperial")
    }
    
    // MARK: - Message Actions
    struct Actions {
        static let mention = L("action.mention")
        static let directMessage = L("action.direct_message")
        static let hug = L("action.hug")
        static let slap = L("action.slap")
        static let block = L("action.block")
        static let copyMessage = L("action.copy_message")
    }
    
    // MARK: - Buttons
    struct Buttons {
        static let showMore = L("button.show_more")
        static let showLess = L("button.show_less")
    }
    
    // MARK: - Payment
    struct Payment {
        static let lightning = L("payment.lightning")
        static let cashu = L("payment.cashu")
    }
    
    // MARK: - Screenshot Warning
    struct Screenshot {
        static let privacyTitle = L("screenshot.privacy.title")
        static let privacyMessage = L("screenshot.privacy.message")
    }
    
    // MARK: - Accessibility
    struct Accessibility {
        static let sendMessage = L("accessibility.send_message")
        static let sendMessageHintEmpty = L("accessibility.send_message_hint.empty")
        static let sendMessageHintReady = L("accessibility.send_message_hint.ready")
        static let locationChannels = L("accessibility.location_channels")
        static func peopleCount(_ count: Int) -> String {
            return L("accessibility.people_count", count)
        }
        static let connectedMesh = L("accessibility.connected_mesh")
        static let reachableMesh = L("accessibility.reachable_mesh")
        static let availableNostr = L("accessibility.available_nostr")
        static let backToMain = L("accessibility.back_to_main")
        static let encryptionStatusVerified = L("accessibility.encryption_status.verified")
        static let encryptionStatusSecured = L("accessibility.encryption_status.secured")
        static let encryptionStatusNotEncrypted = L("accessibility.encryption_status.not_encrypted")
        static func privateChat(_ name: String) -> String {
            return L("accessibility.private_chat", name)
        }
        static let viewFingerprint = L("accessibility.view_fingerprint")
        static let addFavorite = L("accessibility.add_favorite")
        static let removeFavorite = L("accessibility.remove_favorite")
        static let toggleFavorite = L("accessibility.toggle_favorite")
        static func bookmarkToggle(_ geohash: String) -> String {
            return L("accessibility.bookmark_toggle", geohash)
        }
        static let verificationQR = L("accessibility.verification_qr")
        static let unreadPrivateChat = L("accessibility.unread_private_chat")
    }
}
