//
// BloomFilterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class BloomFilterTests: XCTestCase {
    
    func testBasicBloomFilter() {
        var filter = OptimizedBloomFilter(expectedItems: 100, falsePositiveRate: 0.01)
        
        // Test insertion and lookup
        let testStrings = ["message1", "message2", "message3", "test123"]
        
        for str in testStrings {
            XCTAssertFalse(filter.contains(str))
            filter.insert(str)
            XCTAssertTrue(filter.contains(str))
        }
    }
    
    func testFalsePositiveRate() {
        var filter = OptimizedBloomFilter(expectedItems: 100, falsePositiveRate: 0.01)
        let itemCount = 100
        
        // Insert items
        for i in 0..<itemCount {
            filter.insert("item\(i)")
        }
        
        // Check false positive rate
        var falsePositives = 0
        let testCount = 1000
        
        for i in itemCount..<(itemCount + testCount) {
            if filter.contains("item\(i)") {
                falsePositives += 1
            }
        }
        
        let falsePositiveRate = Double(falsePositives) / Double(testCount)
        
        // With optimized bloom filter targeting 1% false positive rate
        XCTAssertLessThan(falsePositiveRate, 0.02) // Allow some margin
    }
    
    func testReset() {
        var filter = OptimizedBloomFilter(expectedItems: 100, falsePositiveRate: 0.01)
        
        // Insert some items
        filter.insert("test1")
        filter.insert("test2")
        filter.insert("test3")
        
        XCTAssertTrue(filter.contains("test1"))
        XCTAssertTrue(filter.contains("test2"))
        XCTAssertTrue(filter.contains("test3"))
        
        // Reset
        filter.reset()
        
        // Should no longer contain items
        XCTAssertFalse(filter.contains("test1"))
        XCTAssertFalse(filter.contains("test2"))
        XCTAssertFalse(filter.contains("test3"))
    }
    
    func testHashDistribution() {
        var filter = OptimizedBloomFilter(expectedItems: 1000, falsePositiveRate: 0.01)
        
        // Insert many items
        for i in 0..<500 {
            filter.insert("message-\(i)")
        }
        
        // Check false positive rate
        let estimatedRate = filter.estimatedFalsePositiveRate
        
        // Should be well below target since we're at 50% capacity
        XCTAssertLessThan(estimatedRate, 0.01)
        
        // Test memory efficiency
        let memoryBytes = filter.memorySizeBytes
        XCTAssertLessThan(memoryBytes, 2048) // Should be under 2KB for this size
    }
    
    func testAdaptiveBloomFilter() {
        // Test small network
        let smallFilter = OptimizedBloomFilter.adaptive(for: 20)
        XCTAssertLessThan(smallFilter.memorySizeBytes, 1024)
        
        // Test large network
        let largeFilter = OptimizedBloomFilter.adaptive(for: 1000)
        XCTAssertGreaterThan(largeFilter.memorySizeBytes, 2048)
    }
}