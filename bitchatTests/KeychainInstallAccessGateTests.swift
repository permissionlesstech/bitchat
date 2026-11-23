//
// KeychainInstallAccessGateTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import bitchat

struct KeychainInstallAccessGateTests {
    @Test func unblockedGateAllowsAccessWithoutReconciling() {
        let gate = KeychainInstallAccessGate()
        var reconcileCount = 0

        let allowed = gate.allowsAccess {
            reconcileCount += 1
            return true
        }

        #expect(allowed)
        #expect(reconcileCount == 0)
    }

    @Test func blockedGateReconcilesOnceAndStaysOpenOnSuccess() {
        let gate = KeychainInstallAccessGate()
        gate.block()
        var reconcileCount = 0

        let first = gate.allowsAccess {
            reconcileCount += 1
            return true
        }
        let second = gate.allowsAccess {
            reconcileCount += 1
            return true
        }

        #expect(first)
        #expect(second)
        #expect(reconcileCount == 1)
    }

    @Test func concurrentCallerFailsClosedWhileReconciliationIsInProgress() async {
        let gate = KeychainInstallAccessGate()
        gate.block()

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let firstTask = Task.detached {
            gate.allowsAccess {
                entered.signal()
                release.wait()
                return true
            }
        }

        entered.wait()
        let concurrentAllowed = gate.allowsAccess { true }
        #expect(!concurrentAllowed)

        release.signal()
        let firstAllowed = await firstTask.value
        #expect(firstAllowed)
        #expect(gate.allowsAccess { false })
    }
}
