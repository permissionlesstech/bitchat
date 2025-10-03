//
// NoiseSessionState.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

enum NoiseSessionState: Equatable {
    case uninitialized
    case handshaking
    case established
    case failed(Error)
    
    static func == (lhs: NoiseSessionState, rhs: NoiseSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized),
             (.handshaking, .handshaking),
             (.established, .established):
            return true
        case (.failed, .failed):
            return true // We don't compare the errors
        default:
            return false
        }
    }
}
