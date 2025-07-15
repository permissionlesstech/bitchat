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
    
    // MARK: - Edge Case Tests
    
    func testExactBlockSizeData() {
        // Test data that exactly matches block sizes
        for blockSize in MessagePadding.blockSizes {
            // Account for 16 bytes encryption overhead
            let dataSize = blockSize - 16
            let data = Data(repeating: 0x42, count: dataSize)
            
            let optimalSize = MessagePadding.optimalBlockSize(for: data.count)
            XCTAssertEqual(optimalSize, blockSize)
            
            // Should fit exactly, no padding needed
            let padded = MessagePadding.pad(data, toSize: blockSize)
            XCTAssertEqual(padded.count, blockSize)
        }
    }
    
    func testOneByteOverBlockSize() {
        // Test data that's one byte over block size threshold
        let blockSizes = [256, 512, 1024]
        
        for blockSize in blockSizes {
            // Create data that's 1 byte too large for current block
            let dataSize = blockSize - 16 + 1
            let data = Data(repeating: 0x42, count: dataSize)
            
            let optimalSize = MessagePadding.optimalBlockSize(for: data.count)
            
            // Should jump to next block size
            if blockSize < 2048 {
                XCTAssertGreaterThan(optimalSize, blockSize)
            }
        }
    }
    
    func testVerySmallData() {
        // Test tiny messages
        let tinyMessages = [
            Data([0x01]),
            Data([0x01, 0x02]),
            Data("a".utf8),
            Data()
        ]
        
        for data in tinyMessages {
            let blockSize = MessagePadding.optimalBlockSize(for: data.count)
            XCTAssertEqual(blockSize, 256) // Should use minimum block size
            
            if !data.isEmpty {
                let padded = MessagePadding.pad(data, toSize: blockSize)
                XCTAssertEqual(padded.count, blockSize)
                
                let unpadded = MessagePadding.unpad(padded)
                XCTAssertEqual(unpadded, data)
            }
        }
    }
    
    func testPaddingBoundaryConditions() {
        // Test PKCS#7 padding limit (255 bytes)
        let testCases = [
            (dataSize: 1, targetSize: 256),    // Need 255 bytes padding - exactly at limit
            (dataSize: 2, targetSize: 256),    // Need 254 bytes padding - just under limit
            (dataSize: 256, targetSize: 512),  // Need 256 bytes padding - just over limit
        ]
        
        for testCase in testCases {
            let data = Data(repeating: 0x42, count: testCase.dataSize)
            let padded = MessagePadding.pad(data, toSize: testCase.targetSize)
            
            let paddingNeeded = testCase.targetSize - testCase.dataSize
            if paddingNeeded <= 255 {
                // Padding should be applied
                XCTAssertEqual(padded.count, testCase.targetSize)
                
                // Verify correct padding byte value
                let paddingByte = padded[padded.count - 1]
                XCTAssertEqual(Int(paddingByte), paddingNeeded)
                
                // Should unpad correctly
                let unpadded = MessagePadding.unpad(padded)
                XCTAssertEqual(unpadded, data)
            } else {
                // No padding applied
                XCTAssertEqual(padded, data)
            }
        }
    }
    
    func testCorruptedPadding() {
        let data = Data("Test message".utf8)
        let padded = MessagePadding.pad(data, toSize: 256)
        
        // Corrupt the padding length byte
        var corrupted = padded
        corrupted[corrupted.count - 1] = 0
        
        let result = MessagePadding.unpad(corrupted)
        XCTAssertEqual(result, corrupted) // Should return original when padding is invalid
        
        // Test with padding length > data size
        var corruptedTooLarge = padded
        corruptedTooLarge[corruptedTooLarge.count - 1] = 255
        
        let result2 = MessagePadding.unpad(corruptedTooLarge)
        XCTAssertEqual(result2, corruptedTooLarge)
    }
    
    func testDataAlreadyLargerThanTarget() {
        let data = Data(repeating: 0x42, count: 1000)
        let tooSmallTarget = 256
        
        // Should return original data when it's already larger than target
        let result = MessagePadding.pad(data, toSize: tooSmallTarget)
        XCTAssertEqual(result, data)
        XCTAssertEqual(result.count, data.count)
    }
    
    func testOptimalBlockSizeForLargeData() {
        // Test data larger than largest block size
        let hugeData = Data(repeating: 0x42, count: 5000)
        let blockSize = MessagePadding.optimalBlockSize(for: hugeData.count)
        
        // Should return data size when larger than all blocks
        XCTAssertEqual(blockSize, hugeData.count)
    }
    
    func testPaddingPerformance() {
        let data = Data(repeating: 0x42, count: 1000)
        
        measure {
            for _ in 0..<1000 {
                let blockSize = MessagePadding.optimalBlockSize(for: data.count)
                let padded = MessagePadding.pad(data, toSize: blockSize)
                _ = MessagePadding.unpad(padded)
            }
        }
    }
}