import Foundation
import LocalAuthentication

enum BiometryType {
    case none
    case touchID
    case faceID
}

protocol LocalAuthProviderProtocol {
    func canEvaluateOwnerAuth() -> Bool
    func evaluateOwnerAuth(reason: String, fallbackTitle: String?, completion: @escaping (Bool, Error?) -> Void)
    func biometryType() -> BiometryType
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

    func evaluateOwnerAuth(reason: String, fallbackTitle: String?, completion: @escaping (Bool, Error?) -> Void) {
        let ctx = freshContext()
        if let ft = fallbackTitle {
            ctx.localizedFallbackTitle = ft
        }
        self.context = ctx
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            completion(success, error)
        }
    }

    func biometryType() -> BiometryType {
        let ctx = freshContext()
        var err: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch ctx.biometryType {
        case .touchID: return .touchID
        case .faceID: return .faceID
        default: return .none
        }
    }

    func invalidate() {
        context?.invalidate()
        context = nil
    }
}
