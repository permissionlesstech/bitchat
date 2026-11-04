//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

#if os(iOS)
  @_silgen_name("composer_test_isolation_status")
  private func composerTestIsolationStatus() -> Int32
#endif

@main
struct BitchatApp: App {
  static let bundleID = Bundle.main.bundleIdentifier ?? "local.composerlayout"
  static let groupID = "group.\(bundleID)"
  init() {
    #if os(iOS)
      precondition(composerTestIsolationStatus() == 1, "Composer app-process network guard is required")
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if os(iOS)
        ComposerLayoutFixture()
      #else
        Color.black
      #endif
    }
  }
}

// Shared AppRuntime source assigns this reference, but the composer host does
// not construct that runtime or install a notification delegate.
final class NotificationDelegate {
  static let shared = NotificationDelegate()
  weak var runtime: AppRuntime?
}
