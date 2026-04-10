//
// SecureMemoryCleaner.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

public protocol SecureMemoryCleaner {
    func secureClear(_ data: inout Data)
    func secureClear(_ string: inout String)
}
