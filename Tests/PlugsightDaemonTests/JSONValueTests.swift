// JSONValueTests.swift
//
// Unit coverage for JSONValue.intValue. The double->Int path must never trap on
// untrusted input: out-of-range and non-finite doubles return nil (which callers
// turn into invalid_params) while legitimate in-range doubles keep truncating.

import Foundation
import XCTest
@testable import PlugsightDaemon

final class JSONValueIntValueTests: XCTestCase {
    // Out-of-Int64-range doubles must return nil, not trap.
    func testOverflowDoubleReturnsNil() {
        XCTAssertNil(JSONValue.double(1e19).intValue)
        XCTAssertNil(JSONValue.double(-1e19).intValue)
    }

    // Non-finite doubles must return nil, not trap.
    func testNonFiniteDoubleReturnsNil() {
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertNil(JSONValue.double(-.infinity).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
    }

    // In-range doubles keep the existing truncating behavior.
    func testInRangeDoubleTruncates() {
        XCTAssertEqual(JSONValue.double(5.9).intValue, 5)
        XCTAssertEqual(JSONValue.double(-3.0).intValue, -3)
        XCTAssertEqual(JSONValue.double(0.0).intValue, 0)
    }

    // Native int case is unchanged.
    func testIntCasePassesThrough() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
    }
}
