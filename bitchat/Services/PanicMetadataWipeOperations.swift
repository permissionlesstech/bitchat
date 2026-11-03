//
// PanicMetadataWipeOperations.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Metadata cleanup dependencies for the panic transaction.
struct PanicMetadataWipeOperations {
    var wipeCourier: () -> Bool
    var wipeBridge: () -> Bool
    var wipeGossip: () -> Bool
    var wipeGroups: () -> Bool
    var wipeBoard: () -> Bool
    var wipeEvents: () -> Bool
    var wipePrekeys: () -> Bool = { PrekeyBundleStore.shared.wipe() }
}
