import XCTest
@testable import BCUCore

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class SystemDragTests: XCTestCase {
    /// Finder on 15.8 and 26.7: the drag pasteboard went 0 to 3 and 3 to 6,
    /// the file stayed where it was, and `drag` said "Dragged".
    func testADragAndDropBefore27DropsNothing() {
        XCTAssertTrue(SystemDrag.dropLost(before: 0, after: 3, osMajor: 26))
        XCTAssertTrue(SystemDrag.dropLost(before: 3, after: 6, osMajor: 15))
        XCTAssertTrue(SystemDrag.dropLost(before: 7, after: 8, osMajor: 14))
    }

    /// 27.0 and 27.3: the same drag went 0 to 1 and moved the file.
    func testADragAndDropOn27Drops() {
        XCTAssertFalse(SystemDrag.dropLost(before: 0, after: 1, osMajor: 27))
        XCTAssertFalse(SystemDrag.dropLost(before: 1, after: 2, osMajor: 28))
    }

    /// A slider or a text selection never touches the drag pasteboard.
    func testAnOrdinaryDragIsFine() {
        XCTAssertFalse(SystemDrag.dropLost(before: 3, after: 3, osMajor: 26))
        XCTAssertFalse(SystemDrag.dropLost(before: 0, after: 0, osMajor: 15))
    }
}
