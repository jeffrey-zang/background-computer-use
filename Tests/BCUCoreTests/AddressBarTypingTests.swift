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

    /// navigate's fallback for a browser it can't drive says to pass the field.
    func testNavigatesFallbackNamesTheAddressFieldAsElement() {
        XCTAssertTrue(Engine.typeURLHint.contains("with element set to the address field"))
    }
}
