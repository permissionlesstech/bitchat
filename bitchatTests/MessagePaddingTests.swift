//
// MessagePaddingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class MessagePaddingTests: XCTestCase {
    
    func testBasicPadding() {
        let originalData = Data("Hello".utf8)
        let targetSize = 256
        
        let padded = MessagePadding.pad(originalData, toSize: targetSize)
        XCTAssertEqual(padded.count, targetSize)
        
        let unpadded = MessagePadding.unpad(padded)
        XCTAssertEqual(unpadded, originalData)
    }
    
    func testMultipleBlockSizes() {
        let testMessages = [
            "Hi",
            "This is a longer message",
            "This is an even longer message that should require a larger block size",
            String(repeating: "A", count: 500)
        ]
        
        for message in testMessages {
            let data = Data(message.utf8)
            let blockSize = MessagePadding.optimalBlockSize(for: data.count)
            
            // Block size should be reasonable
            XCTAssertGreaterThan(blockSize, data.count)
            XCTAssertTrue(MessagePadding.blockSizes.contains(blockSize) || blockSize == data.count)
            
            let padded = MessagePadding.pad(data, toSize: blockSize)
            
            // Check if padding was applied (only if needed padding <= 255)
            let paddingNeeded = blockSize - data.count
            if paddingNeeded <= 255 {
                XCTAssertEqual(padded.count, blockSize)
                let unpadded = MessagePadding.unpad(padded)
                XCTAssertEqual(unpadded, data)
            } else {
                // No padding applied if more than 255 bytes needed
                XCTAssertEqual(padded, data)
            }
        }
    }
    
    func testPaddingWithLargeData() {
        let largeData = Data(repeating: 0xFF, count: 1500)
        let blockSize = MessagePadding.optimalBlockSize(for: largeData.count)
        
        // Should use 2048 block
        XCTAssertEqual(blockSize, 2048)
        
        let padded = MessagePadding.pad(largeData, toSize: blockSize)
        // Since padding needed (548 bytes) > 255, no padding is applied
        XCTAssertEqual(padded.count, largeData.count)
        XCTAssertEqual(padded, largeData)
        
        // Test with data that fits within PKCS#7 limits
        let smallerData = Data(repeating: 0xAA, count: 1800)
        let paddedSmaller = MessagePadding.pad(smallerData, toSize: 2048)
        // Padding needed is 248 bytes, which is < 255, so padding should work
        XCTAssertEqual(paddedSmaller.count, 2048)
        
        let unpaddedSmaller = MessagePadding.unpad(paddedSmaller)
        XCTAssertEqual(unpaddedSmaller, smallerData)
    }
    
    func testInvalidPadding() {
        // Test empty data
        let empty = Data()
        let unpaddedEmpty = MessagePadding.unpad(empty)
        XCTAssertEqual(unpaddedEmpty, empty)
        
        // Test data with invalid padding length
        var invalidPadding = Data(repeating: 0x00, count: 100)
        invalidPadding[99] = 255 // Invalid padding length
        let result = MessagePadding.unpad(invalidPadding)
        XCTAssertEqual(result, invalidPadding) // Should return original if invalid
    }
    
    func testPaddingRandomness() {
        // Ensure padding bytes are random (not predictable)
        let data = Data("Test".utf8)
        let padded1 = MessagePadding.pad(data, toSize: 256)
        let padded2 = MessagePadding.pad(data, toSize: 256)
        
        // Same size
        XCTAssertEqual(padded1.count, padded2.count)
        
        // But different padding bytes (with very high probability)
        XCTAssertNotEqual(padded1, padded2)
        
        // Both should unpad to same data
        XCTAssertEqual(MessagePadding.unpad(padded1), data)
        XCTAssertEqual(MessagePadding.unpad(padded2), data)
    }
}