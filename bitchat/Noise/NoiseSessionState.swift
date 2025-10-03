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
}
