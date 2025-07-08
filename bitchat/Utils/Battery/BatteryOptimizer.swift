//
// BatteryOptimizer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif

// MARK: - BatteryOptimizer

/// A singleton responsible for optimizing app behavior based on the device’s power state.
/// Monitors battery level, charging status, and app foreground/background state,
/// and publishes updates via Combine publishers.
final class BatteryOptimizer: @unchecked Sendable {
    // MARK: Lifecycle

    private init() {
        setupObservers()
        updateBatteryStatus()
    }

    deinit {
        let observersCopy = queue.sync { observers }
        observersCopy.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Internal

    /// The shared instance of `BatteryOptimizer`.
    static let shared = BatteryOptimizer()

    /// Publishes the current power mode.
    let powerModePublisher = CurrentValueSubject<PowerMode, Never>(.balanced)

    /// Publishes the current battery level (0.0 to 1.0).
    let batteryLevelPublisher = CurrentValueSubject<Float, Never>(1.0)

    /// Publishes whether the device is currently charging.
    let isChargingPublisher = CurrentValueSubject<Bool, Never>(false)

    /// Publishes whether the app is currently in the background.
    let isInBackgroundPublisher = CurrentValueSubject<Bool, Never>(false)

    /// Returns the current power mode.
    var currentPowerMode: PowerMode {
        queue.sync { _currentPowerMode }
    }

    /// Returns `true` if the app is in the background.
    var isInBackground: Bool {
        queue.sync { _isInBackground }
    }

    /// Returns the current battery level.
    var batteryLevel: Float {
        queue.sync { _batteryLevel }
    }

    /// Returns `true` if the device is currently charging.
    var isCharging: Bool {
        queue.sync { _isCharging }
    }

    /// Returns the appropriate scan duration and pause interval based on current power mode.
    var scanParameters: (duration: TimeInterval, pause: TimeInterval) {
        let mode = currentPowerMode
        return (mode.scanDuration, mode.scanPauseDuration)
    }

    /// Indicates whether non-essential operations should be skipped.
    var shouldSkipNonEssential: Bool {
        currentPowerMode == .ultraLowPower
            || (currentPowerMode == .powerSaver && isInBackground)
    }

    /// Indicates whether messages should be throttled based on power mode.
    var shouldThrottleMessages: Bool {
        currentPowerMode == .powerSaver || currentPowerMode == .ultraLowPower
    }

    /// Manually overrides the current power mode.
    /// - Parameter mode: The `PowerMode` to apply.
    func setPowerMode(_ mode: PowerMode) {
        queue.async(flags: .barrier) {
            self._currentPowerMode = mode
        }

        powerModePublisher.send(mode)
    }

    // MARK: Private

    private let queue = DispatchQueue(
        label: "com.bitchat.battery-optimizer.queue",
        attributes: .concurrent
    )

    private var _currentPowerMode: PowerMode = .balanced
    private var _isInBackground: Bool = false
    private var _batteryLevel: Float = 1.0
    private var _isCharging: Bool = false

    private var observers: [NSObjectProtocol] = []
}

// MARK: - iOS Observer Setup

#if os(iOS)
    extension BatteryOptimizer {
        /// Sets up observers for iOS-specific notifications:
        /// - App background/foreground transitions
        /// - Battery level and state changes
        private func setupObservers() {
            UIDevice.current.isBatteryMonitoringEnabled = true

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setIsInBackground(true)
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setIsInBackground(false)
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIDevice.batteryLevelDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateBatteryStatus()
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIDevice.batteryStateDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateBatteryStatus()
                }
            )
        }
    }
#endif

// MARK: - macOS Battery Info

#if os(macOS)
    extension BatteryOptimizer {
        /// Retrieves current battery level and charging status for macOS.
        /// - Returns: A tuple of battery level and charging status, or `nil` if unavailable.
        private static func getMacOSBatteryInfo() -> (
            level: Float, isCharging: Bool
        )? {
            let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let sources =
                IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

            for source in sources {
                if let description = IOPSGetPowerSourceDescription(
                    snapshot,
                    source
                ).takeUnretainedValue() as? [String: Any],
                    let currentCapacity = description[kIOPSCurrentCapacityKey]
                        as? Int,
                    let maxCapacity = description[kIOPSMaxCapacityKey] as? Int
                {
                    let level = Float(currentCapacity) / Float(maxCapacity)
                    let isCharging =
                        description[kIOPSPowerSourceStateKey] as? String
                        == kIOPSACPowerValue
                    return (level, isCharging)
                }
            }
            return nil
        }
    }
#endif

// MARK: - Battery Info Logic

extension BatteryOptimizer {
    /// Updates internal battery state and notifies subscribers.
    /// - Parameters:
    ///   - level: Battery level between 0.0 and 1.0.
    ///   - charging: Indicates whether the device is charging.
    private func updateBatteryInfo(level: Float, charging: Bool) {
        queue.async(flags: .barrier) {
            self._batteryLevel = level
            self._isCharging = charging
        }

        batteryLevelPublisher.send(level)
        isChargingPublisher.send(charging)

        updatePowerMode()
    }

    /// Sets the background status and triggers power mode recalculation.
    /// - Parameter isBackground: Boolean representing app background state.
    private func setIsInBackground(_ isBackground: Bool) {
        queue.async(flags: .barrier) {
            self._isInBackground = isBackground
        }

        isInBackgroundPublisher.send(isBackground)
        updatePowerMode()
    }

    /// Refreshes battery status by reading from the platform-specific source (iOS/macOS).
    private func updateBatteryStatus() {
        #if os(iOS)
            var level = UIDevice.current.batteryLevel
            if level < 0 {
                level = 1.0
            }

            let charging =
                UIDevice.current.batteryState == .charging
                || UIDevice.current.batteryState == .full

            updateBatteryInfo(level: level, charging: charging)

        #elseif os(macOS)
            if let info = Self.getMacOSBatteryInfo() {
                updateBatteryInfo(level: info.level, charging: info.isCharging)
            }
        #endif
    }

    /// Calculates and applies the appropriate power mode based on:
    /// - Battery level
    /// - Charging status
    /// - App foreground/background state
    private func updatePowerMode() {
        let level = batteryLevel
        let charging = isCharging
        let background = isInBackground

        let newMode: PowerMode =
            if charging {
                level < 0.1 ? .balanced : .performance
            } else if background {
                level < 0.2
                    ? .ultraLowPower : level < 0.5 ? .powerSaver : .balanced
            } else {
                level < 0.1
                    ? .ultraLowPower
                    : level < 0.3
                        ? .powerSaver : level < 0.6 ? .balanced : .performance
            }

        queue.async(flags: .barrier) {
            self._currentPowerMode = newMode
        }

        powerModePublisher.send(newMode)
    }
}
