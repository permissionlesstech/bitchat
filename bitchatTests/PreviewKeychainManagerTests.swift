import Foundation
import Testing
@testable import bitchat

@Suite("PreviewKeychainManager Tests")
struct PreviewKeychainManagerTests {

    @Test("Preview keychain manager stores identity and service-scoped data in memory")
    func previewKeychainManagerRoundTripsData() {
        let manager = PreviewKeychainManager()
        let identityKey = Data([1, 2, 3, 4])
        let serviceKey = "preview-service"
        let scopedData = Data([9, 8, 7, 6])

        #expect(!manager.verifyIdentityKeyExists())
        #expect(manager.saveIdentityKey(identityKey, forKey: "noiseStaticKey"))
        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == identityKey)
        #expect(manager.saveIdentityKey(identityKey, forKey: "identity_noiseStaticKey"))
        #expect(manager.verifyIdentityKeyExists())

        if case .success(let stored) = manager.getIdentityKeyWithResult(forKey: "noiseStaticKey") {
            #expect(stored == identityKey)
        } else {
            Issue.record("Expected stored preview identity key")
        }

        if case .success = manager.saveIdentityKeyWithResult(Data([5, 6, 7]), forKey: "ed25519SigningKey") {
        } else {
            Issue.record("Expected preview keychain save to succeed")
        }

        manager.save(key: "blob", data: scopedData, service: serviceKey, accessible: nil)
        #expect(manager.load(key: "blob", service: serviceKey) == scopedData)
        manager.delete(key: "blob", service: serviceKey)
        #expect(manager.load(key: "blob", service: serviceKey) == nil)

        var secretData = Data([4, 3, 2, 1])
        var secretString = "secret"
        manager.secureClear(&secretData)
        manager.secureClear(&secretString)
        #expect(secretData == Data([4, 3, 2, 1]))
        #expect(secretString == "secret")

        #expect(manager.deleteIdentityKey(forKey: "noiseStaticKey"))
        #expect(manager.deleteIdentityKey(forKey: "identity_noiseStaticKey"))
        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == nil)
        #expect(manager.deleteAllKeychainData())

        if case .itemNotFound = manager.getIdentityKeyWithResult(forKey: "ed25519SigningKey") {
        } else {
            Issue.record("Expected preview keychain to be empty after deleteAllKeychainData")
        }
    }
}
