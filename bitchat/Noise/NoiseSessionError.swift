//
// NoiseSessionError.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

enum NoiseSessionError: Error {
    case invalidState
    case notEstablished
    case sessionNotFound
    case handshakeFailed(Error)
    case alreadyEstablished
}
