import BitSecp256k1
import Foundation
import XCTest

final class BitSecp256k1Tests: XCTestCase {
    private func hexData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        return Data(bytes)
    }

    /// Official BIP-340 test vector #0.
    func test_bip340Vector0() throws {
        let seckey = hexData("0000000000000000000000000000000000000000000000000000000000000003")
        let expectedPub = hexData("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
        let aux = hexData("0000000000000000000000000000000000000000000000000000000000000000")
        let msg = [UInt8](hexData("0000000000000000000000000000000000000000000000000000000000000000"))
        let expectedSig = hexData(
            "E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215" +
            "25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"
        )

        let key = try BitSecp256k1.SchnorrPrivateKey(dataRepresentation: seckey)
        XCTAssertEqual(key.xonlyPublicKey, expectedPub)

        let sig = try key.sign(message: msg, auxiliaryRand: [UInt8](aux))
        XCTAssertEqual(sig, expectedSig)
        XCTAssertTrue(BitSecp256k1.verifySchnorr(signature: sig, message: msg, xonlyPublicKey: expectedPub))

        var tamperedMsg = msg
        tamperedMsg[0] ^= 0x01
        XCTAssertFalse(BitSecp256k1.verifySchnorr(signature: sig, message: tamperedMsg, xonlyPublicKey: expectedPub))
    }

    /// Official BIP-340 test vector #1.
    func test_bip340Vector1() throws {
        let seckey = hexData("B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF")
        let expectedPub = hexData("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659")
        let aux = hexData("0000000000000000000000000000000000000000000000000000000000000001")
        let msg = [UInt8](hexData("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"))
        let expectedSig = hexData(
            "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341" +
            "8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"
        )

        let key = try BitSecp256k1.SchnorrPrivateKey(dataRepresentation: seckey)
        XCTAssertEqual(key.xonlyPublicKey, expectedPub)
        let sig = try key.sign(message: msg, auxiliaryRand: [UInt8](aux))
        XCTAssertEqual(sig, expectedSig)
        XCTAssertTrue(BitSecp256k1.verifySchnorr(signature: sig, message: msg, xonlyPublicKey: expectedPub))
    }

    func test_ecdhCompressedSymmetryAndParity() throws {
        let alice = try BitSecp256k1.SchnorrPrivateKey()
        let bob = try BitSecp256k1.SchnorrPrivateKey()

        let aliceEven = Data([0x02]) + alice.xonlyPublicKey
        let bobEven = Data([0x02]) + bob.xonlyPublicKey

        let sharedAB = try BitSecp256k1.ecdhCompressed(
            privateKey: alice.dataRepresentation,
            compressedPublicKey: bobEven
        )
        XCTAssertEqual(sharedAB.count, 33)
        XCTAssertTrue(sharedAB[0] == 0x02 || sharedAB[0] == 0x03)

        let sharedBAEven = try BitSecp256k1.ecdhCompressed(
            privateKey: bob.dataRepresentation,
            compressedPublicKey: aliceEven
        )
        let aliceOdd = Data([0x03]) + alice.xonlyPublicKey
        let sharedBAOdd = try BitSecp256k1.ecdhCompressed(
            privateKey: bob.dataRepresentation,
            compressedPublicKey: aliceOdd
        )
        // Regardless of alice/bob original Y parity, one of even/odd x-only lifts
        // shares the exact X coordinate (or exact point) with sharedAB.
        XCTAssertTrue(
            sharedAB.dropFirst() == sharedBAEven.dropFirst() ||
            sharedAB.dropFirst() == sharedBAOdd.dropFirst()
        )
    }

    func test_invalidKeysRejected() {
        XCTAssertThrowsError(try BitSecp256k1.SchnorrPrivateKey(dataRepresentation: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try BitSecp256k1.SchnorrPrivateKey(dataRepresentation: Data(repeating: 1, count: 31)))
        XCTAssertFalse(BitSecp256k1.verifySchnorr(
            signature: Data(repeating: 0, count: 64),
            message: [UInt8](repeating: 0, count: 32),
            xonlyPublicKey: Data(repeating: 0, count: 32)
        ))
    }
}
