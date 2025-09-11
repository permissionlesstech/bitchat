//
// OSLog+Categories.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import os.log

extension OSLog {
    private static let subsystem = "chat.bitchat"
    
    static let noise        = OSLog(subsystem: subsystem, category: "noise")
    static let encryption   = OSLog(subsystem: subsystem, category: "encryption")
    static let keychain     = OSLog(subsystem: subsystem, category: "keychain")
    static let session      = OSLog(subsystem: subsystem, category: "session")
    static let security     = OSLog(subsystem: subsystem, category: "security")
    static let handshake    = OSLog(subsystem: subsystem, category: "handshake")
}
