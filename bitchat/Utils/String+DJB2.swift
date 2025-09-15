//
// String+DJB2.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    func djb2() -> UInt64 {
        var hash: UInt64 = 5381
        for b in utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return hash
    }
}
