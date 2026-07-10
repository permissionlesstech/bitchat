import Testing
import Foundation
@testable import bitchat

struct SchnorrConcurrencyRepro {
    @Test func concurrentVerificationOfValidEventAlwaysSucceeds() async throws {
        let identity = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", "sn"]],
            content: "concurrency probe"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        #expect(signed.isValidSignature())

        let failures = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var localFailures = 0
                    for _ in 0..<250 {
                        if !signed.isValidSignature() { localFailures += 1 }
                    }
                    return localFailures
                }
            }
            var total = 0
            for await f in group { total += f }
            return total
        }
        #expect(failures == 0, "Schnorr verification returned false \(failures)/2000 times under concurrency")
    }

    @Test func verificationSurvivesConcurrentSigningAndKeyGeneration() async throws {
        let identity = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", "sn"]],
            content: "concurrency probe"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        #expect(signed.isValidSignature())

        // Signing and key generation may mutate shared library state
        // (secp256k1 context randomization); verification must stay correct
        // while they run on other tasks.
        let failures = await withTaskGroup(of: Int.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    if worker < 4 {
                        var localFailures = 0
                        for _ in 0..<250 {
                            if !signed.isValidSignature() { localFailures += 1 }
                        }
                        return localFailures
                    } else {
                        for i in 0..<100 {
                            if let id = try? NostrIdentity.generate() {
                                let e = NostrEvent(
                                    pubkey: id.publicKeyHex,
                                    createdAt: Date(),
                                    kind: .ephemeralEvent,
                                    tags: [],
                                    content: "signer \(worker)-\(i)"
                                )
                                _ = try? e.sign(with: id.schnorrSigningKey())
                            }
                        }
                        return 0
                    }
                }
            }
            var total = 0
            for await f in group { total += f }
            return total
        }
        #expect(failures == 0, "Schnorr verification returned false \(failures)/1000 times while signing ran concurrently")
    }
}
