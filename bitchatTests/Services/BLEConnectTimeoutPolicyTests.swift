import Foundation
import Testing
@testable import bitchat

struct BLEConnectTimeoutPolicyTests {
    @Test
    func supersededAttemptTokenIgnoresTimeout() {
        let capturedToken: UInt64 = 1
        let currentToken: UInt64 = 2

        let result = BLEConnectTimeoutPolicy.shouldExecuteConnectTimeout(
            capturedAttemptToken: capturedToken,
            isConnecting: true,
            isConnected: false,
            currentAttemptToken: currentToken,
            isPeripheralConnected: false
        )

        #expect(!result)
    }

    @Test
    func matchingAttemptTokenExecutesTimeout() {
        let token: UInt64 = 5

        let result = BLEConnectTimeoutPolicy.shouldExecuteConnectTimeout(
            capturedAttemptToken: token,
            isConnecting: true,
            isConnected: false,
            currentAttemptToken: token,
            isPeripheralConnected: false
        )

        #expect(result)
    }

    @Test
    func connectedStateIgnoresTimeout() {
        let token: UInt64 = 5

        let result = BLEConnectTimeoutPolicy.shouldExecuteConnectTimeout(
            capturedAttemptToken: token,
            isConnecting: false,
            isConnected: true,
            currentAttemptToken: token,
            isPeripheralConnected: true
        )

        #expect(!result)
    }

    @Test
    func peripheralConnectedStateIgnoresTimeout() {
        let token: UInt64 = 5

        let result = BLEConnectTimeoutPolicy.shouldExecuteConnectTimeout(
            capturedAttemptToken: token,
            isConnecting: true,
            isConnected: false,
            currentAttemptToken: token,
            isPeripheralConnected: true
        )

        #expect(!result)
    }
}
