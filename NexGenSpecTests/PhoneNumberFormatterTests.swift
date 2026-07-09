//
//  PhoneNumberFormatterTests.swift
//  NexGenSpecTests
//
//  Covers formatPhoneNumber: forward-typing format, idempotency, and the
//  backspace-progress guarantee. The formatter must never emit a trailing
//  separator: the PhoneNumberFormatter onChange reformats on every keystroke,
//  so a trailing separator reformats to the identical string and re-inserts
//  the character the user just deleted — the field hard-locks (found in the
//  build-29 iPad smoke, 2026-07-09).
//

import XCTest
@testable import NexGenSpec

final class PhoneNumberFormatterTests: XCTestCase {

    func testFormatsFullNumber() {
        XCTAssertEqual(formatPhoneNumber("5551234567"), "(555) 123-4567")
    }

    func testFormatsPartialNumbers() {
        XCTAssertEqual(formatPhoneNumber(""), "")
        XCTAssertEqual(formatPhoneNumber("5"), "(5")
        XCTAssertEqual(formatPhoneNumber("555"), "(555")
        XCTAssertEqual(formatPhoneNumber("5551"), "(555) 1")
        XCTAssertEqual(formatPhoneNumber("555123"), "(555) 123")
        XCTAssertEqual(formatPhoneNumber("5551234"), "(555) 123-4")
    }

    func testStripsNonDigitsAndCapsAtTenDigits() {
        XCTAssertEqual(formatPhoneNumber("(555) 123-4567 ext 89"), "(555) 123-4567")
        XCTAssertEqual(formatPhoneNumber("555-123-4567"), "(555) 123-4567")
        XCTAssertEqual(formatPhoneNumber("abc"), "")
    }

    func testIsIdempotent() {
        for count in 0...10 {
            let digits = String("5551234567".prefix(count))
            let once = formatPhoneNumber(digits)
            XCTAssertEqual(formatPhoneNumber(once), once, "not idempotent at \(count) digits")
        }
    }

    func testNeverEmitsTrailingSeparator() {
        for count in 0...10 {
            let formatted = formatPhoneNumber(String("5551234567".prefix(count)))
            if let last = formatted.last {
                XCTAssertTrue(last.isWholeNumber,
                              "trailing separator at \(count) digits: \"\(formatted)\"")
            }
        }
    }

    /// Simulates holding backspace: drop the last character, reformat (what the
    /// onChange rewrite does), repeat. Must strictly shrink to empty — the old
    /// trailing-separator format hard-locked at "(555) 123-" and "(555) ".
    func testBackspaceAlwaysReachesEmpty() {
        var text = formatPhoneNumber("5551234567")
        var steps = 0
        while !text.isEmpty {
            let reformatted = formatPhoneNumber(String(text.dropLast()))
            XCTAssertLessThan(reformatted.count, text.count, "backspace stalled at \"\(text)\"")
            text = reformatted
            steps += 1
            if steps > 30 {
                XCTFail("backspace never reached empty")
                return
            }
        }
    }
}
