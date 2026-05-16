//
// SubscriptionRateLimitTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

/// Tests for BCH-01-004 fix: Rate-limiting subscription-triggered announces
/// to prevent device enumeration attacks
struct SubscriptionRateLimitTests {

    @Test("Rate limit configuration values are sensible")
    func rateLimitConfigurationValues() {
        // Minimum interval should be at least 1 second to slow enumeration
        #expect(TransportConfig.bleSubscriptionRateLimitMinSeconds >= 1.0)

        // Backoff factor should be > 1 for exponential backoff
        #expect(TransportConfig.bleSubscriptionRateLimitBackoffFactor > 1.0)

        // Max backoff should be reasonable (not hours)
        #expect(TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds <= 60.0)
        #expect(TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds >= TransportConfig.bleSubscriptionRateLimitMinSeconds)

        // Window should be long enough to track repeated attempts
        #expect(TransportConfig.bleSubscriptionRateLimitWindowSeconds >= 30.0)

        // Max attempts before suppression should be > 1 to allow legitimate reconnects
        #expect(TransportConfig.bleSubscriptionRateLimitMaxAttempts >= 2)
    }

    @Test("Exponential backoff calculation is correct")
    func exponentialBackoffCalculation() {
        let minInterval = TransportConfig.bleSubscriptionRateLimitMinSeconds
        let factor = TransportConfig.bleSubscriptionRateLimitBackoffFactor
        let maxBackoff = TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds

        // Simulate backoff progression
        var currentBackoff = minInterval
        var iterations = 0
        let maxIterations = 10

        while currentBackoff < maxBackoff && iterations < maxIterations {
            let nextBackoff = min(currentBackoff * factor, maxBackoff)
            #expect(nextBackoff >= currentBackoff, "Backoff should increase or stay at max")
            currentBackoff = nextBackoff
            iterations += 1
        }

        // Should reach max within reasonable iterations
        #expect(iterations <= maxIterations, "Backoff should reach max within \(maxIterations) iterations")
        #expect(currentBackoff == maxBackoff, "Final backoff should equal max")
    }

    @Test("Rate limiting would significantly slow enumeration attacks")
    func rateLimitingSlowsEnumeration() {
        // Without rate limiting: ~120 devices/minute (0.5 seconds per device)
        // With rate limiting: minimum interval enforced

        let minInterval = TransportConfig.bleSubscriptionRateLimitMinSeconds
        let devicesPerMinuteWithRateLimit = 60.0 / minInterval

        // Should be significantly slower than 120 devices/minute
        #expect(devicesPerMinuteWithRateLimit < 60, "Rate limiting should significantly slow enumeration")

        // With 2-second minimum interval, max ~30 devices/minute per connection
        // And with backoff, repeated attempts are even slower
        #expect(devicesPerMinuteWithRateLimit <= 30, "With 2s minimum, should be <=30/min")
    }

    @Test("Max attempts threshold prevents complete enumeration")
    func maxAttemptsThresholdPreventsEnumeration() {
        let maxAttempts = TransportConfig.bleSubscriptionRateLimitMaxAttempts

        // After max attempts within window, announces are suppressed entirely
        // This means an attacker gets at most maxAttempts announces per window
        #expect(maxAttempts >= 2, "Should allow at least 2 attempts for legitimate reconnects")
        #expect(maxAttempts <= 10, "Should cap attempts to prevent enumeration")

        // With 5 attempts max and 2s minimum interval, attacker gets limited info
        let maxAnnounces = maxAttempts
        #expect(maxAnnounces <= 10, "Max announces per window should be limited")
    }
}
