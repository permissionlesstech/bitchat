//
// AppLockWindowTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import Testing
import UIKit
@testable import bitchat

/// Pins the UIKit behaviour the lock window relies on, in the host app's real
/// scene. While locked, the gate window is key (so keyboard input can't reach
/// the chat behind it) and sits above the alert level. Hiding it on unlock
/// hands key status straight back to the window that held it, so unlock needs
/// no explicit `makeKey()`.
@MainActor
struct AppLockWindowTests {
    @Test func lockTakesKeyAndUnlockHandsItBack() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let main = UIWindow(windowScene: scene)
        main.rootViewController = UIViewController()
        main.makeKeyAndVisible()
        defer { main.isHidden = true }
        try #require(main.isKeyWindow)

        let model = AppLockModel(isEnabledProvider: { true }, authenticate: { _ in })
        AppLockWindow.shared.setLocked(true, model: model, appTheme: .matrix)
        defer { AppLockWindow.shared.setLocked(false, model: model, appTheme: .matrix) }

        let lockWindow = try #require(scene.keyWindow)
        #expect(lockWindow !== main)
        #expect(lockWindow.windowLevel.rawValue > UIWindow.Level.alert.rawValue)

        AppLockWindow.shared.setLocked(false, model: model, appTheme: .matrix)
        #expect(lockWindow.isHidden)
        #expect(main.isKeyWindow)
    }
}
#endif
