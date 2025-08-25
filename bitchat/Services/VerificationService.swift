import Foundation
import CryptoKit

/// QR verification scaffolding: schema, signing, and basic challenge/response helpers.
final class VerificationService {
    static let shared = VerificationService()

    // Injected Noise service from the running transport (do NOT create new BLEService)
    private var noise: NoiseEncryptionService?
    func configure(with noise: NoiseEncryptionService) { self.noise = noise }

    /// Encapsulates the data encoded into a verification QR
    struct VerificationQR: Codable {
        let v: Int
        let noiseKeyHex: String
        let signKeyHex: String
        let npub: String?
        let nickname: String
        let ts: Int64
        let nonceB64: String
        var sigHex: String

        static let context = "bitchat-verify-v1"

        /// Canonical bytes used for signature (deterministic ordering)
        func canonicalBytes() -> Data {
            var out = Data()
            func appendField(_ s: String) {
                let d = s.data(using: .utf8) ?? Data()
                out.append(UInt8(min(d.count, 255)))
                out.append(d.prefix(255))
            }
            appendField(Self.context)
            appendField(String(v))
            appendField(noiseKeyHex.lowercased())
            appendField(signKeyHex.lowercased())
            appendField(npub ?? "")
            appendField(nickname)
            appendField(String(ts))
            appendField(nonceB64)
            return out
        }

        func toURLString() -> String {
            var comps = URLComponents()
            comps.scheme = "bitchat"
            comps.host = "verify"
            comps.queryItems = [
                URLQueryItem(name: "v", value: String(v)),
                URLQueryItem(name: "noise", value: noiseKeyHex),
                URLQueryItem(name: "sign", value: signKeyHex),
                URLQueryItem(name: "nick", value: nickname),
                URLQueryItem(name: "ts", value: String(ts)),
                URLQueryItem(name: "nonce", value: nonceB64),
                URLQueryItem(name: "sig", value: sigHex)
            ] + (npub != nil ? [URLQueryItem(name: "npub", value: npub)] : [])
            return comps.string ?? ""
        }

        static func fromURL(_ url: URL) -> VerificationQR? {
            guard url.scheme == "bitchat", url.host == "verify",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func val(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            guard let vStr = val("v"), let v = Int(vStr),
                  let noise = val("noise"), let sign = val("sign"),
                  let nick = val("nick"), let tsStr = val("ts"), let ts = Int64(tsStr),
                  let nonce = val("nonce"), let sig = val("sig") else { return nil }
            return VerificationQR(v: v, noiseKeyHex: noise, signKeyHex: sign, npub: val("npub"), nickname: nick, ts: ts, nonceB64: nonce, sigHex: sig)
        }
    }

    // MARK: - Public API

    /// Build a signed QR string for the current identity
    func buildMyQRString(nickname: String, npub: String?) -> String? {
        // Simple short-lived cache to speed up sheet opening
        struct Cache { static var last: (nick: String, npub: String?, builtAt: Date, value: String)? }
        if let c = Cache.last, c.nick == nickname, c.npub == npub, Date().timeIntervalSince(c.builtAt) < 60 {
            return c.value
        }
        guard let noise = noise else { return nil }
        let noiseKey = noise.getStaticPublicKeyData().hexEncodedString()
        let signKey = noise.getSigningPublicKeyData().hexEncodedString()
        let ts = Int64(Date().timeIntervalSince1970)
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let nonceB64 = nonce.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload = VerificationQR(v: 1, noiseKeyHex: noiseKey, signKeyHex: signKey, npub: npub, nickname: nickname, ts: ts, nonceB64: nonceB64, sigHex: "")
        let msg = payload.canonicalBytes()
        guard let sig = noise.signData(msg) else { return nil }
        let signed = VerificationQR(v: payload.v,
                                    noiseKeyHex: payload.noiseKeyHex,
                                    signKeyHex: payload.signKeyHex,
                                    npub: payload.npub,
                                    nickname: payload.nickname,
                                    ts: payload.ts,
                                    nonceB64: payload.nonceB64,
                                    sigHex: sig.map { String(format: "%02x", $0) }.joined())
        let out = signed.toURLString()
        Cache.last = (nickname, npub, Date(), out)
        return out
    }

    /// Verify a scanned QR and return the parsed payload if valid (signature + freshness checks)
    func verifyScannedQR(_ urlString: String, maxAge: TimeInterval = TransportConfig.verificationQRMaxAgeSeconds) -> VerificationQR? {
        guard let url = URL(string: urlString), let qr = VerificationQR.fromURL(url) else { return nil }
        // Freshness
        let now = Date().timeIntervalSince1970
        if now - Double(qr.ts) > maxAge { return nil }
        // Verify signature using embedded ed25519 signKey
        guard let sig = Data(hexString: qr.sigHex), let signKey = Data(hexString: qr.signKeyHex) else { return nil }
        guard let noise = noise else { return nil }
        let ok = noise.verifySignature(sig, for: qr.canonicalBytes(), publicKey: signKey)
        return ok ? qr : nil
    }

    // MARK: - Noise payloads (scaffold only)

    func buildVerifyChallenge(noiseKeyHex: String, nonceA: Data) -> Data {
        // TLV: [0x01 len noiseKeyHex ascii] [0x02 len nonceA]
        var tlv = Data()
        let n0: [UInt8] = [0x01, UInt8(min(noiseKeyHex.count, 255))]
        tlv.append(contentsOf: n0)
        tlv.append(noiseKeyHex.data(using: .utf8)!.prefix(255))
        tlv.append(0x02)
        tlv.append(UInt8(min(nonceA.count, 255)))
        tlv.append(nonceA.prefix(255))
        return NoisePayload(type: .verifyChallenge, data: tlv).encode()
    }

    func buildVerifyResponse(noiseKeyHex: String, nonceA: Data) -> Data? {
        // Sign context: verify-response | noiseKeyHex | nonceA
        var msg = Data("bitchat-verify-resp-v1".utf8)
        let nk = noiseKeyHex.data(using: .utf8) ?? Data()
        msg.append(UInt8(min(nk.count, 255))); msg.append(nk.prefix(255))
        msg.append(nonceA)
        guard let noise = noise, let sig = noise.signData(msg) else { return nil }
        var tlv = Data()
        tlv.append(0x01); tlv.append(UInt8(min(nk.count, 255))); tlv.append(nk.prefix(255))
        tlv.append(0x02); tlv.append(UInt8(min(nonceA.count, 255))); tlv.append(nonceA.prefix(255))
        tlv.append(0x03); tlv.append(UInt8(min(sig.count, 255))); tlv.append(sig.prefix(255))
        return NoisePayload(type: .verifyResponse, data: tlv).encode()
    }

    func parseVerifyChallenge(_ data: Data) -> (noiseKeyHex: String, nonceA: Data)? {
        var idx = 0
        func take(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            let d = data[idx..<(idx+n)]
            idx += n
            return Data(d)
        }
        // Expect type already stripped; we receive only TLV here
        // TLV 0x01 noiseKeyHex
        guard let t1 = take(1), t1[0] == 0x01, let l1 = take(1), let s1 = take(Int(l1[0])),
              let noiseStr = String(data: s1, encoding: .utf8) else { return nil }
        // TLV 0x02 nonceA
        guard let t2 = take(1), t2[0] == 0x02, let l2 = take(1), let nA = take(Int(l2[0])) else { return nil }
        return (noiseStr, nA)
    }

    func parseVerifyResponse(_ data: Data) -> (noiseKeyHex: String, nonceA: Data, signature: Data)? {
        var idx = 0
        func take(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            let d = data[idx..<(idx+n)]
            idx += n
            return Data(d)
        }
        guard let t1 = take(1), t1[0] == 0x01, let l1 = take(1), let s1 = take(Int(l1[0])),
              let noiseStr = String(data: s1, encoding: .utf8) else { return nil }
        guard let t2 = take(1), t2[0] == 0x02, let l2 = take(1), let nA = take(Int(l2[0])) else { return nil }
        guard let t3 = take(1), t3[0] == 0x03, let l3 = take(1), let sig = take(Int(l3[0])) else { return nil }
        return (noiseStr, nA, sig)
    }

    func verifyResponseSignature(noiseKeyHex: String, nonceA: Data, signature: Data, signerPublicKeyHex: String) -> Bool {
        var msg = Data("bitchat-verify-resp-v1".utf8)
        let nk = noiseKeyHex.data(using: .utf8) ?? Data()
        msg.append(UInt8(min(nk.count, 255))); msg.append(nk.prefix(255))
        msg.append(nonceA)
        guard let noise = noise, let pub = Data(hexString: signerPublicKeyHex) else { return false }
        return noise.verifySignature(signature, for: msg, publicKey: pub)
    }
}
