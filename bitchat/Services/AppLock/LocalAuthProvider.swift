import Foundation
import LocalAuthentication

protocol LocalAuthProviderProtocol {
    func canEvaluateOwnerAuth() -> Bool
    func evaluateOwnerAuth(reason: String, completion: @escaping (Bool, Error?) -> Void)
    func invalidate()
}

final class LocalAuthProvider: LocalAuthProviderProtocol {
    private var context: LAContext?

    private func freshContext() -> LAContext {
        // Create a fresh LAContext per attempt, per Apple guidance
        let ctx = LAContext()
        // Optionally reduce re-prompts for brief periods
        if #available(iOS 11.0, macOS 10.13.2, *) {
            ctx.touchIDAuthenticationAllowableReuseDuration = 8 // seconds
        }
        return ctx
    }

    func canEvaluateOwnerAuth() -> Bool {
        let ctx = freshContext()
        var err: NSError?
        let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        return can
    }

    func evaluateOwnerAuth(reason: String, completion: @escaping (Bool, Error?) -> Void) {
        let ctx = freshContext()
        self.context = ctx
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            completion(success, error)
        }
    }

    func invalidate() {
        context?.invalidate()
        context = nil
    }
}

