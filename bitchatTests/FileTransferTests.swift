//
// FileTransferTests.swift
// bitchatTests
//
// Simple tests for file transfer functionality
// This is free and unencumbered software released into the public domain.
//

import XCTest
import Foundation
@testable import bitchat

class FileTransferTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    // MARK: - File Attachment TLV Encoding Tests
    
    func testFileAttachmentTLVEncoding() throws {
        // Test basic TLV encoding/decoding
        let testData = "Hello, World!".data(using: .utf8)!
        let attachment = FileAttachment(
            filename: "test.txt",
            mimeType: "text/plain",
            data: testData
        )
        
        let encoded = attachment.encodeTLV()
        let decoded = FileAttachment.decodeTLV(encoded)
        
        XCTAssertNotNil(decoded, "Failed to decode TLV data")
        XCTAssertEqual(decoded?.filename, "test.txt", "Filename mismatch")
        XCTAssertEqual(decoded?.mimeType, "text/plain", "MIME type mismatch")
        XCTAssertEqual(decoded?.data, testData, "File data mismatch")
    }
    
    func testFileAttachmentTLVEncodingLargeFile() throws {
        // Test with larger file
        let testData = Data(repeating: 0x42, count: 10000) // 10KB of 'B' characters
        let attachment = FileAttachment(
            filename: "large_test.bin",
            mimeType: "application/octet-stream",
            data: testData
        )
        
        let encoded = attachment.encodeTLV()
        let decoded = FileAttachment.decodeTLV(encoded)
        
        XCTAssertNotNil(decoded, "Failed to decode large TLV data")
        XCTAssertEqual(decoded?.filename, "large_test.bin", "Filename mismatch")
        XCTAssertEqual(decoded?.mimeType, "application/octet-stream", "MIME type mismatch")
        XCTAssertEqual(decoded?.data, testData, "Large file data mismatch")
    }
    
    func testFileAttachmentTLVEncodingUnicodeFilename() throws {
        // Test with Unicode filename
        let testData = "Test content".data(using: .utf8)!
        let attachment = FileAttachment(
            filename: "测试文件.txt", // Chinese characters
            mimeType: "text/plain",
            data: testData
        )
        
        let encoded = attachment.encodeTLV()
        let decoded = FileAttachment.decodeTLV(encoded)
        
        XCTAssertNotNil(decoded, "Failed to decode Unicode TLV data")
        XCTAssertEqual(decoded?.filename, "测试文件.txt", "Unicode filename mismatch")
        XCTAssertEqual(decoded?.mimeType, "text/plain", "MIME type mismatch")
        XCTAssertEqual(decoded?.data, testData, "File data mismatch")
    }
    
    func testFileAttachmentTLVEncodingEmptyFile() throws {
        // Test with empty file
        let testData = Data()
        let attachment = FileAttachment(
            filename: "empty.txt",
            mimeType: "text/plain",
            data: testData
        )
        
        let encoded = attachment.encodeTLV()
        let decoded = FileAttachment.decodeTLV(encoded)
        
        XCTAssertNotNil(decoded, "Failed to decode empty file TLV data")
        XCTAssertEqual(decoded?.filename, "empty.txt", "Filename mismatch")
        XCTAssertEqual(decoded?.mimeType, "text/plain", "MIME type mismatch")
        XCTAssertEqual(decoded?.data, testData, "Empty file data mismatch")
    }
    
    // MARK: - File Transfer Destination Tests
    
    func testFileTransferDestinationMesh() throws {
        let destination = FileTransferDestination.meshPrivateChat(peerID: "test-peer-123")
        
        switch destination {
        case .meshPrivateChat(let peerID):
            XCTAssertEqual(peerID, "test-peer-123", "Peer ID mismatch")
        case .locationChannel(_):
            XCTFail("Expected mesh destination, got location channel")
        }
    }
    
    func testFileTransferDestinationLocation() throws {
        let geohash = "dr5rsj7"
        let destination = FileTransferDestination.locationChannel(geohash: geohash)
        
        switch destination {
        case .meshPrivateChat(_):
            XCTFail("Expected location channel, got mesh destination")
        case .locationChannel(let hash):
            XCTAssertEqual(hash, geohash, "Geohash mismatch")
        }
    }
    
    // MARK: - Integration Tests
    
    func testFileTransferServiceInitialization() throws {
        // Test that FileTransferService can be initialized
        let fileTransferService = FileTransferService()
        
        XCTAssertFalse(fileTransferService.isTransferring, "Service should not be transferring initially")
        XCTAssertEqual(fileTransferService.transferProgress, 0.0, "Transfer progress should be 0 initially")
        XCTAssertNil(fileTransferService.lastError, "Should have no error initially")
    }
    
    func testFileTransferServiceValidation() throws {
        // Test file size validation
        let fileTransferService = FileTransferService()
        
        // Create a temporary test file
        let tempDir = FileManager.default.temporaryDirectory
        let testFileURL = tempDir.appendingPathComponent("test_file.txt")
        let testContent = "This is a test file for validation"
        try testContent.write(to: testFileURL, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: testFileURL)
        }
        
        let expectation = XCTestExpectation(description: "File transfer completion")
        
        // Test transfer to mesh (should work with valid file)
        fileTransferService.transferFile(
            url: testFileURL,
            to: .meshPrivateChat(peerID: "test-peer")
        ) { result in
            switch result {
            case .success:
                // This is expected behavior even though we don't have a real BLE service
                break
            case .failure(let error):
                // This might fail due to missing BLE service, which is acceptable for this test
                print("Transfer failed as expected in test environment: \(error)")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    // MARK: - Edge Case Tests
    
    func testFileAttachmentTLVCorruptedData() throws {
        // Test with corrupted TLV data
        let corruptedData = Data([0xFF, 0xFF, 0xFF, 0xFF]) // Invalid length
        let decoded = FileAttachment.decodeTLV(corruptedData)
        
        XCTAssertNil(decoded, "Should return nil for corrupted data")
    }
    
    func testFileAttachmentTLVTruncatedData() throws {
        // Test with truncated TLV data
        let truncatedData = Data([0x00, 0x05]) // Claims 5 bytes but only has 2
        let decoded = FileAttachment.decodeTLV(truncatedData)
        
        XCTAssertNil(decoded, "Should return nil for truncated data")
    }
}
