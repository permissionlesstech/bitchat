//
// XChaCha20Poly1305CompatTests.swift
// bitchatTests
//
// Tests for XChaCha20-Poly1305 encryption with proper error handling.
// This is free and unencumbered software released into the public domain.
//

import Testing
import struct Foundation.Data
@testable import bitchat

struct XChaCha20Poly1305CompatTests {

    @Test func sealAndOpenRoundtrip() throws {
        let plaintext = Data("Hello, XChaCha20-Poly1305!".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 24)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce)
        let decrypted = try XChaCha20Poly1305Compat.open(
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            key: key,
            nonce24: nonce
        )

        #expect(decrypted == plaintext)
    }

    @Test func sealAndOpenWithAAD() throws {
        let plaintext = Data("Secret message".utf8)
        let key = Data(repeating: 0xAB, count: 32)
        let nonce = Data(repeating: 0xCD, count: 24)
        let aad = Data("additional authenticated data".utf8)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce, aad: aad)
        let decrypted = try XChaCha20Poly1305Compat.open(
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            key: key,
            nonce24: nonce,
            aad: aad
        )

        #expect(decrypted == plaintext)
    }

    @Test func sealProducesDifferentCiphertextWithDifferentNonces() throws {
        let plaintext = Data("Same plaintext".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let nonce1 = Data(repeating: 0x01, count: 24)
        let nonce2 = Data(repeating: 0x02, count: 24)

        let sealed1 = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce1)
        let sealed2 = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce2)

        #expect(sealed1.ciphertext != sealed2.ciphertext)
    }

    @Test func sealThrowsOnShortKey() {
        let plaintext = Data("Test".utf8)
        let shortKey = Data(repeating: 0x42, count: 16)
        let nonce = Data(repeating: 0x24, count: 24)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: shortKey, nonce24: nonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func sealThrowsOnLongKey() {
        let plaintext = Data("Test".utf8)
        let longKey = Data(repeating: 0x42, count: 64)
        let nonce = Data(repeating: 0x24, count: 24)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: longKey, nonce24: nonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func sealThrowsOnEmptyKey() {
        let plaintext = Data("Test".utf8)
        let emptyKey = Data()
        let nonce = Data(repeating: 0x24, count: 24)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: emptyKey, nonce24: nonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func openThrowsOnInvalidKeyLength() {
        let ciphertext = Data(repeating: 0x00, count: 16)
        let tag = Data(repeating: 0x00, count: 16)
        let shortKey = Data(repeating: 0x42, count: 31)
        let nonce = Data(repeating: 0x24, count: 24)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.open(ciphertext: ciphertext, tag: tag, key: shortKey, nonce24: nonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func sealThrowsOnShortNonce() {
        let plaintext = Data("Test".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let shortNonce = Data(repeating: 0x24, count: 12)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: shortNonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func sealThrowsOnLongNonce() {
        let plaintext = Data("Test".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let longNonce = Data(repeating: 0x24, count: 32)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: longNonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func sealThrowsOnEmptyNonce() {
        let plaintext = Data("Test".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let emptyNonce = Data()

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: emptyNonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func openThrowsOnInvalidNonceLength() {
        let ciphertext = Data(repeating: 0x00, count: 16)
        let tag = Data(repeating: 0x00, count: 16)
        let key = Data(repeating: 0x42, count: 32)
        let shortNonce = Data(repeating: 0x24, count: 23)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.open(ciphertext: ciphertext, tag: tag, key: key, nonce24: shortNonce)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func openFailsWithWrongKey() throws {
        let plaintext = Data("Secret".utf8)
        let correctKey = Data(repeating: 0x42, count: 32)
        let wrongKey = Data(repeating: 0x43, count: 32)
        let nonce = Data(repeating: 0x24, count: 24)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: correctKey, nonce24: nonce)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.open(
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                key: wrongKey,
                nonce24: nonce
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test func openFailsWithTamperedCiphertext() throws {
        let plaintext = Data("Secret".utf8)
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 24)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce)

        // Create tampered ciphertext by changing first byte
        var tamperedBytes = [UInt8](sealed.ciphertext)
        tamperedBytes[0] = tamperedBytes[0] ^ 0xFF
        let tampered = Data(tamperedBytes)

        var didThrow = false
        do {
            _ = try XChaCha20Poly1305Compat.open(
                ciphertext: tampered,
                tag: sealed.tag,
                key: key,
                nonce24: nonce
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }
}
