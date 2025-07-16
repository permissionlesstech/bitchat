// PingTests.swift
import XCTest
@testable import bitchat

class PingTests: XCTestCase {

    func testPingRequestInitialization() {
        let senderID = "testSender"
        let senderNickname = "Sender"
        let targetID = "testTarget"
        let targetNickname = "Target"
        
        let ping = PingRequest(senderID: senderID, senderNickname: senderNickname, targetID: targetID, targetNickname: targetNickname)
        
        XCTAssertNotNil(ping.pingID)
        XCTAssertEqual(ping.senderID, senderID)
        XCTAssertEqual(ping.senderNickname, senderNickname)
        XCTAssertEqual(ping.targetID, targetID)
        XCTAssertEqual(ping.targetNickname, targetNickname)
        XCTAssertNotNil(ping.timestamp)
    }
    
    func testPingRequestEncodingDecoding() {
        let senderID = "testSender"
        let senderNickname = "Sender"
        let targetID = "testTarget"
        let targetNickname = "Target"
        
        let ping = PingRequest(senderID: senderID, senderNickname: senderNickname, targetID: targetID, targetNickname: targetNickname)
        
        guard let encoded = ping.encode() else {
            XCTFail("Failed to encode PingRequest")
            return
        }
        
        let decoded = PingRequest.decode(from: encoded)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.pingID, ping.pingID)
        XCTAssertEqual(decoded?.senderID, ping.senderID)
        XCTAssertEqual(decoded?.senderNickname, ping.senderNickname)
        XCTAssertEqual(decoded?.targetID, ping.targetID)
        XCTAssertEqual(decoded?.targetNickname, ping.targetNickname)
        XCTAssertEqual(decoded?.timestamp.timeIntervalSince1970, ping.timestamp.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testPongResponseInitialization() {
        let senderID = "testSender"
        let senderNickname = "Sender"
        let targetID = "testTarget"
        let targetNickname = "Target"
        
        let ping = PingRequest(senderID: senderID, senderNickname: senderNickname, targetID: targetID, targetNickname: targetNickname)
        
        let responderID = "testResponder"
        let responderNickname = "Responder"
        
        let pong = PongResponse(originalPing: ping, responderID: responderID, responderNickname: responderNickname)
        
        XCTAssertEqual(pong.originalPingID, ping.pingID)
        XCTAssertNotNil(pong.pongID)
        XCTAssertEqual(pong.responderID, responderID)
        XCTAssertEqual(pong.responderNickname, responderNickname)
        XCTAssertEqual(pong.originalTimestamp.timeIntervalSince1970, ping.timestamp.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertNotNil(pong.responseTimestamp)
    }
    
    func testPongResponseEncodingDecoding() {
        let senderID = "testSender"
        let senderNickname = "Sender"
        let targetID = "testTarget"
        let targetNickname = "Target"
        
        let ping = PingRequest(senderID: senderID, senderNickname: senderNickname, targetID: targetID, targetNickname: targetNickname)
        
        let responderID = "testResponder"
        let responderNickname = "Responder"
        
        let pong = PongResponse(originalPing: ping, responderID: responderID, responderNickname: responderNickname)
        
        guard let encoded = pong.encode() else {
            XCTFail("Failed to encode PongResponse")
            return
        }
        
        let decoded = PongResponse.decode(from: encoded)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.originalPingID, pong.originalPingID)
        XCTAssertEqual(decoded?.pongID, pong.pongID)
        XCTAssertEqual(decoded?.responderID, pong.responderID)
        XCTAssertEqual(decoded?.responderNickname, pong.responderNickname)
        XCTAssertEqual(decoded?.originalTimestamp.timeIntervalSince1970, pong.originalTimestamp.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(decoded?.responseTimestamp.timeIntervalSince1970, pong.responseTimestamp.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testLatencyCalculation() {
        let senderID = "testSender"
        let senderNickname = "Sender"
        let targetID = "testTarget"
        let targetNickname = "Target"
        
        let ping = PingRequest(senderID: senderID, senderNickname: senderNickname, targetID: targetID, targetNickname: targetNickname)
        
        // Simulate delay
        Thread.sleep(forTimeInterval: 0.5)
        
        let responderID = "testResponder"
        let responderNickname = "Responder"
        
        let pong = PongResponse(originalPing: ping, responderID: responderID, responderNickname: responderNickname)
        
        let latency = pong.responseTimestamp.timeIntervalSince(ping.timestamp)
        XCTAssertGreaterThanOrEqual(latency, 0.5)
        XCTAssertLessThan(latency, 0.6)
    }
} 