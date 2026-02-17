//
// OptimizedBloomFilter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// Optimized Bloom filter using bit-packed storage and better hash functions
struct OptimizedBloomFilter {
    private var bitArray: [UInt64]
    private let bitCount: Int
    private let hashCount: Int
    
    // Statistics
    private(set) var insertCount: Int = 0
    
    /// Creates a Bloom filter sized for the given expected item count and false-positive rate.
    ///
    /// - Parameters:
    ///   - expectedItems: Anticipated number of items to insert (default 1 000).
    ///   - falsePositiveRate: Target false-positive probability (default 1 %).
    init(expectedItems: Int = 1000, falsePositiveRate: Double = 0.01) {
        // Calculate optimal bit count and hash count
        let m = Double(expectedItems) * abs(log(falsePositiveRate)) / (log(2) * log(2))
        self.bitCount = Int(max(64, m.rounded()))
        
        let k = Double(bitCount) / Double(expectedItems) * log(2)
        self.hashCount = Int(max(1, min(10, k.rounded())))
        
        // Initialize bit array (64 bits per UInt64)
        let arraySize = (bitCount + 63) / 64
        self.bitArray = Array(repeating: 0, count: arraySize)
    }
    
    /// Inserts `item` into the filter by setting the corresponding bits.
    mutating func insert(_ item: String) {
        let hashes = generateHashes(item)
        
        for i in 0..<hashCount {
            let bitIndex = hashes[i] % bitCount
            let arrayIndex = bitIndex / 64
            let bitOffset = bitIndex % 64
            
            bitArray[arrayIndex] |= (1 << bitOffset)
        }
        
        insertCount += 1
    }
    
    /// Tests whether `item` is **possibly** in the filter.
    ///
    /// A `true` result may be a false positive; a `false` result is always correct.
    func contains(_ item: String) -> Bool {
        let hashes = generateHashes(item)
        
        for i in 0..<hashCount {
            let bitIndex = hashes[i] % bitCount
            let arrayIndex = bitIndex / 64
            let bitOffset = bitIndex % 64
            
            if (bitArray[arrayIndex] & (1 << bitOffset)) == 0 {
                return false
            }
        }
        
        return true
    }
    
    /// Clears all bits and resets the insert count to zero.
    mutating func reset() {
        for i in 0..<bitArray.count {
            bitArray[i] = 0
        }
        insertCount = 0
    }
    
    /// Derives `hashCount` independent bit positions from `item` using SHA-256 double hashing.
    private func generateHashes(_ item: String) -> [Int] {
        guard let data = item.data(using: .utf8) else {
            return Array(repeating: 0, count: hashCount)
        }
        
        // Use SHA256 for high-quality hash values
        let hash = SHA256.hash(data: data)
        let hashBytes = Array(hash)
        
        var hashes = [Int]()
        
        // Extract multiple hash values from the SHA256 output
        for i in 0..<hashCount {
            let offset = (i * 4) % (hashBytes.count - 3)
            let value = Int(hashBytes[offset]) |
                       (Int(hashBytes[offset + 1]) << 8) |
                       (Int(hashBytes[offset + 2]) << 16) |
                       (Int(hashBytes[offset + 3]) << 24)
            hashes.append(abs(value))
        }
        
        return hashes
    }
    
    /// Estimated false-positive probability given the current number of inserted items.
    var estimatedFalsePositiveRate: Double {
        guard insertCount > 0 else { return 0 }
        
        // Count set bits
        var setBits = 0
        for value in bitArray {
            setBits += value.nonzeroBitCount
        }
        
        // Calculate probability: (1 - e^(-kn/m))^k
        let ratio = Double(hashCount * insertCount) / Double(bitCount)
        return pow(1 - exp(-ratio), Double(hashCount))
    }
    
    /// Memory consumed by the underlying bit array, in bytes.
    var memorySizeBytes: Int {
        return bitArray.count * 8
    }
}

// MARK: - Adaptive Factory
extension OptimizedBloomFilter {
    /// Creates a Bloom filter with capacity and false-positive rate tuned for the estimated network size.
    ///
    /// Larger networks use higher capacity and accept a slightly higher false-positive rate
    /// to keep memory usage practical.
    static func adaptive(for networkSize: Int) -> OptimizedBloomFilter {
        // Adjust parameters based on network size
        let expectedItems: Int
        let falsePositiveRate: Double
        
        switch networkSize {
        case 0..<50:
            expectedItems = 500
            falsePositiveRate = 0.01
        case 50..<200:
            expectedItems = 2000
            falsePositiveRate = 0.02
        case 200..<500:
            expectedItems = 5000
            falsePositiveRate = 0.03
        default:
            expectedItems = 10000
            falsePositiveRate = 0.05
        }
        
        return OptimizedBloomFilter(expectedItems: expectedItems, falsePositiveRate: falsePositiveRate)
    }
}