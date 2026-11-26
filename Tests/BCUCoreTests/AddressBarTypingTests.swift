import XCTest
@testable import BCUCore

/// How type_text fills a single-line field when the user isn't in the app
/// (#83). Typed key by key into Safari's address bar, a URL picks up the
/// bar's inline autocomplete partway and the rest lands after the
/// suggestion, so Return loads the wrong page. The text has to go in
/// through accessibility in one go, with only Return pressed as a key.
final class AddressBarTypingTests: XCTestCase {
    let url = "file:///private/tmp/issue-83/upload.html\n"

    func testAURLAndReturnIntoAnAddressFieldGoesInThroughAccessibility() {
        XCTAssertEqual(Engine.typingRoute(role: "AXTextField", selectedTextSettable: true, text: url), .accessibilityAndKeys)
        XCTAssertEqual(Engine.typingRoute(role: "AXComboBox", selectedTextSettable: false, text: url), .accessibilityAndKeys)
        XCTAssertEqual(Engine.typingRoute(role: "AXSearchField", selectedTextSettable: true, text: "query\t"), .accessibilityAndKeys)
    }

    /// Unchanged: text with no Return or Tab, a text area (where Return is a
    /// new line), something that isn't a text field, and no element at all.
    func testOtherCasesKeepTheirRoute() {
        XCTAssertEqual(Engine.typingRoute(role: "AXTextField", selectedTextSettable: true, text: "example.com"), .accessibility)
        XCTAssertEqual(Engine.typingRoute(role: "AXTextArea", selectedTextSettable: true, text: "line one\nline two"), .keystrokes)
        XCTAssertEqual(Engine.typingRoute(role: "AXGroup", selectedTextSettable: false, text: url), .keystrokes)
        XCTAssertEqual(Engine.typingRoute(role: nil, selectedTextSettable: false, text: url), .keystrokes)
    }

    /// A Tab moves focus to the next field, but an accessibility write goes
    /// to the element it was given: text after a Tab goes as keys, which
    /// follow the focus, so "first\tsecond" doesn't put "second" back into
    /// the first field.
    func testTextAfterATabFollowsTheFocusAsKeys() {
        XCTAssertEqual(Engine.sharedParts("first\tsecond", singleLine: true), [.text("first"), .key("\t"), .keys("second")])
        XCTAssertEqual(Engine.sharedParts("first\tsecond", singleLine: false), [.text("first"), .key("\t"), .keys("second")])
        XCTAssertEqual(Engine.sharedParts("a\tb\nc", singleLine: false), [.text("a"), .key("\t"), .keys("b"), .key("\n"), .keys("c")])
    }

    /// In a single-line field Return can move focus too (a form that goes
    /// on to its next field): the text after it follows as keys.
    func testTextAfterAReturnInASingleLineFieldFollowsTheFocusAsKeys() {
        XCTAssertEqual(Engine.sharedParts("first\nsecond", singleLine: true), [.text("first"), .key("\n"), .keys("second")])
        XCTAssertTrue(Engine.isSingleLine(role: "AXTextField"))
        XCTAssertTrue(Engine.isSingleLine(role: "AXComboBox"))
        XCTAssertFalse(Engine.isSingleLine(role: "AXTextArea"))
        XCTAssertFalse(Engine.isSingleLine(role: nil))
    }

    /// In a text area Return is a new line and focus stays: every run of
    /// text goes in through accessibility. A URL and Return is unchanged.
    func testTextWithoutAFocusMoveStaysInTheField() {
        XCTAssertEqual(Engine.sharedParts(url, singleLine: true), [.text(String(url.dropLast())), .key("\n")])
        XCTAssertEqual(Engine.sharedParts("one\ntwo", singleLine: false), [.text("one"), .key("\n"), .text("two")])
        XCTAssertEqual(Engine.sharedParts("query\t", singleLine: true), [.text("query"), .key("\t")])
        XCTAssertEqual(Engine.sharedParts("\n", singleLine: true), [.key("\n")])
    }

    /// navigate's fallback for a browser it can't drive says to pass the field.
    func testNavigatesFallbackNamesTheAddressFieldAsElement() {
        XCTAssertTrue(Engine.typeURLHint.contains("with element set to the address field"))
    }
}
