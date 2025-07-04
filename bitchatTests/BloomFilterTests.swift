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
        let filter = BloomFilter(size: 1024, hashCount: 3)
        
        // Test insertion and lookup
        let testStrings = ["message1", "message2", "message3", "test123"]
        
        for str in testStrings {
            XCTAssertFalse(filter.contains(str))
            filter.insert(str)
            XCTAssertTrue(filter.contains(str))
        }
    }
    
    func testFalsePositiveRate() {
        let filter = BloomFilter(size: 4096, hashCount: 3)
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
        
        // With 4096 bits and 3 hash functions, for 100 items,
        // false positive rate should be around 0.05% (very low)
        XCTAssertLessThan(falsePositiveRate, 0.05)
    }
    
    func testReset() {
        let filter = BloomFilter(size: 1024, hashCount: 3)
        
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
        let filter = BloomFilter(size: 4096, hashCount: 3)
        
        // Insert many items and check bit distribution
        for i in 0..<500 {
            filter.insert("message-\(i)")
        }
        
        // Count set bits
        var setBits = 0
        for i in 0..<filter.bitArray.count {
            setBits += filter.bitArray[i].nonzeroBitCount
        }
        
        // Should have reasonable distribution (not all bits set)
        let totalBits = filter.bitArray.count * 64
        let utilization = Double(setBits) / Double(totalBits)
        
        // With 500 items, 3 hashes each, we expect around 1500 bits set
        // In a 4096 bit filter, that's about 37% utilization
        XCTAssertGreaterThan(utilization, 0.2)
        XCTAssertLessThan(utilization, 0.6)
    }
}