//
//  UserDefaultsStorageTests.swift
//  bitchat
//
//  Created by Rubens Machion on 26/09/25.
//

import XCTest
@testable import bitchat

final class UserDefaultsStorageTests: XCTestCase {
    var sut: UserDefaultsStorage!

    override func setUp() {
        super.setUp()
        sut = UserDefaultsStorage()
    }

    override func tearDown() {
        super.tearDown()
        sut = nil
    }

    func testSetAndGetValue() {
        sut.set("Hello", key: "greeting")
        let value: String? = sut.get("greeting")
        XCTAssertEqual(value, "Hello")
    }

    func testOverwriteValue() {
        sut.set(1, key: "counter")
        sut.set(2, key: "counter")
        let value: Int? = sut.get("counter")
        XCTAssertEqual(value, 2, "The last value should overwrite the previous one")
    }

    func testRemoveValue() {
        sut.set(true, key: "flag")
        sut.remove("flag")
        let value: Bool? = sut.get("flag")
        XCTAssertNil(value, "The removed value should be nil")
    }

    func testGetNonExistentKey() {
        let value: String? = sut.get("not_exists")
        XCTAssertNil(value, "Nonexistent keys should return nil")
    }
}
