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
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: "https://example.com/a", wanted: want, loading: false, started: true))
        XCTAssertTrue(Engine.safariLoaded(before: nil, now: "https://example.com/a/", wanted: want, loading: nil, started: true))
        // Safari stores /tmp paths under /private.
        XCTAssertTrue(Engine.safariLoaded(before: "about:blank", now: "file:///private/tmp/x.html", wanted: "file:///tmp/x.html", loading: false, started: true))
    }

    func testPathAndQueryKeepTheirCase() {
        // Still the old page: /a is not /A, and Q=x is not q=x.
        XCTAssertFalse(Engine.safariLoaded(before: "https://example.com/a", now: "https://example.com/a", wanted: "https://example.com/A", loading: false, started: true))
        XCTAssertFalse(Engine.safariLoaded(before: "https://example.com/s?q=x", now: "https://example.com/s?q=x", wanted: "https://example.com/s?Q=x", loading: false, started: true))
        // Scheme and host don't count.
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: "https://example.com/A", wanted: "HTTPS://Example.COM/A", loading: false, started: true))
        XCTAssertEqual(Engine.comparableURL("https://Example.com/"), Engine.comparableURL("https://example.com"))
        XCTAssertNotEqual(Engine.comparableURL("https://example.com/a"), Engine.comparableURL("https://example.com/A"))
        XCTAssertEqual(Engine.comparableURL("file:///private/tmp/x.html"), Engine.comparableURL("file:///tmp/x.html"))
    }

    func testEscapedSlashesStayEscaped() {
        XCTAssertNotEqual(Engine.comparableURL("https://example.com/a/b"), Engine.comparableURL("https://example.com/a%2Fb"))
        XCTAssertFalse(Engine.safariLoaded(before: "https://example.com/a/b", now: "https://example.com/a/b", wanted: "https://example.com/a%2Fb", loading: false, started: true))
    }

    func testAReloadOfTheShowingPageWaitsForTheLoadToStart() {
        let u = "https://example.com/a"
        // Same URL, nothing seen to start: still the old document.
        XCTAssertFalse(Engine.safariLoaded(before: u, now: u, wanted: u, loading: false, started: false))
        XCTAssertFalse(Engine.safariLoaded(before: u, now: u, wanted: u, loading: nil, started: false))
        // It said it was loading, or a new document replaced the old one, and it's done.
        XCTAssertTrue(Engine.safariLoaded(before: u, now: u, wanted: u, loading: false, started: true))
        // Another URL showing is a change in itself.
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: u, wanted: u, loading: false, started: false))
    }

    func testARedirectCountsAsLoaded() {
        XCTAssertTrue(Engine.safariLoaded(before: "https://old.example/", now: "https://www.example.com/", wanted: "https://example.com", loading: false, started: true))
    }

    func testNotWhileTheOldPageIsStillThereOrLoading() {
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: "https://old.example/", wanted: "https://example.com", loading: false, started: true))
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: "https://example.com/", wanted: "https://example.com", loading: true, started: true))
        XCTAssertFalse(Engine.safariLoaded(before: "https://old.example/", now: nil, wanted: "https://example.com", loading: nil, started: true))
    }
}
