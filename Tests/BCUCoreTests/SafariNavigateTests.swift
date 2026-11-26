import XCTest
@testable import BCUCore

/// `navigate` in Safari: the URL goes into the address field through
/// accessibility, with no key focus (#87).
final class SafariNavigateTests: XCTestCase {
    func testSafariIsToldByBundleID() {
        XCTAssertTrue(AppKind.isSafari(bundleID: "com.apple.Safari"))
        XCTAssertTrue(AppKind.isSafari(bundleID: "com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(AppKind.isSafari(bundleID: "com.google.Chrome"))
        XCTAssertFalse(AppKind.isSafari(bundleID: nil))
    }

    func testTheAddressFieldIsTheSmartSearchField() {
        XCTAssertTrue(Engine.isSafariAddressField(role: "AXTextField", identifier: nil, description: "smart search field"))
        XCTAssertTrue(Engine.isSafariAddressField(role: "AXTextField", identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", description: nil))
        XCTAssertTrue(Engine.isSafariAddressField(role: "AXComboBox", identifier: nil, description: "Smart Search Field"))
    }

    func testOtherFieldsAreNot() {
        XCTAssertFalse(Engine.isSafariAddressField(role: "AXTextField", identifier: nil, description: "Search"))
        XCTAssertFalse(Engine.isSafariAddressField(role: "AXTextField", identifier: nil, description: nil))
        XCTAssertFalse(Engine.isSafariAddressField(role: "AXButton", identifier: nil, description: "smart search field"))
    }

    func testLoadedOnceThePageIsTheOneAskedFor() {
        let want = "https://example.com/a"
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: "https://example.com/a", wanted: want, loading: false))
        XCTAssertTrue(Engine.safariLoaded(before: nil, now: "https://example.com/a/", wanted: want, loading: nil))
        // Safari stores /tmp paths under /private.
        XCTAssertTrue(Engine.safariLoaded(before: "about:blank", now: "file:///private/tmp/x.html", wanted: "file:///tmp/x.html", loading: false))
    }

    func testARedirectCountsAsLoaded() {
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: "https://www.example.com/", wanted: "https://example.com", loading: false))
    }

    func testNotWhileTheOldPageIsStillThereOrLoading() {
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: "https://old.example/", wanted: "https://example.com", loading: false))
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: "https://example.com/", wanted: "https://example.com", loading: true))
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: nil, wanted: "https://example.com", loading: nil))
    }
}
