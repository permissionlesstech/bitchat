//
// GeoPerson.swift
// bitchat
//
// Model representing a participant in a geohash channel
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Represents a person participating in a geohash-based location channel
struct GeoPerson: Identifiable, Equatable {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
    let lastSeen: Date
}
