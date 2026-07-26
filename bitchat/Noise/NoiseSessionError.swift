//
// NoiseSessionError.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

enum NoiseSessionError: Error, Equatable {
    case invalidState
    case notEstablished
    case sessionNotFound
    case alreadyEstablished
    case peerIdentityMismatch
}

/// The manager owns the exact attempt's one bounded recovery. Packet handling
/// must not launch its historical second, immediate restart for this failure.
struct NoiseManagedHandshakeFailure: Error {
    let underlying: Error
}
