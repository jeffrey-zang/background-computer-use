import XCTest
@testable import BCUCore

/// An open or save panel runs in a macOS service process, drawn into the
/// app's sheet from a window of the service's laid exactly over it. Keys and
/// clicks for the panel go to that window.
final class PanelMatchTests: XCTestCase {
    private let sheetFrame = CGRect(x: 3168, y: 1994, width: 1184, height: 448)
    private let app: pid_t = 74912
    private let service: pid_t = 74846

    private func window(_ id: CGWindowID, _ pid: pid_t, _ bounds: CGRect, layer: Int = 0) -> WindowInfo {
        WindowInfo(id: id, pid: pid, owner: "", title: "", bounds: bounds, layer: layer, onScreen: false, alpha: 1)
    }

    /// Helium's file picker (from the incident): sheet 127992, the service's window 127993 over it.
    func testThePanelServicesWindowOverTheSheetIsTheTarget() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(117402, service, CGRect(x: 0, y: 1692, width: 53, height: 48)), window(127993, service, sheetFrame)]
        XCTAssertEqual(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }),
                       Panel.Remote(pid: service, window: 127993, frame: sheetFrame))
    }

    /// Another app's window that happens to have the same frame isn't the panel.
    func testAWindowOfAnotherProcessThatIsntAPanelServiceIsIgnored() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(500, 999, sheetFrame)]
        XCTAssertNil(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }))
    }

    /// An alert sheet is drawn by the app itself: nothing of the service's over it.
    func testASheetTheAppDrawsItselfHasNoPanel() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(127993, service, sheetFrame.offsetBy(dx: 10, dy: 0))]
        XCTAssertNil(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }))
    }

    // MARK: Standalone panels (File > Open in a document app, issue #79)

    private let agentDisplay = CGRect(x: 5000, y: 0, width: 1512, height: 982)
    private let documentFrame = CGRect(x: 5100, y: 100, width: 586, height: 488)
    private let panelFrame = CGRect(x: 5050, y: 60, width: 880, height: 448)

    /// TextEdit's File > Open: the panel is a window of the app's own, not
    /// a sheet on the document, with the service's window over it. Looked
    /// for from the document window, it's found.
    func testAStandalonePanelIsFoundFromTheDocumentWindow() {
        let doc = window(29264, app, documentFrame), panel = window(29292, app, panelFrame)
        let candidates = [panel, window(29293, service, panelFrame), doc]
        let found = Panel.standalone(window: 29264, appPid: app, appWindows: [29292, 29264], display: agentDisplay,
                                     candidates: candidates, isService: { $0 == self.service })
        XCTAssertEqual(found?.panel, 29292)
        XCTAssertEqual(found?.remote, Panel.Remote(pid: service, window: 29293, frame: panelFrame))
    }

    /// The panel window the agent caught, given as the window itself.
    func testAStandalonePanelIsFoundFromItsOwnWindow() {
        let doc = window(29264, app, documentFrame), panel = window(29292, app, panelFrame)
        let candidates = [doc, panel, window(29293, service, panelFrame)]
        let found = Panel.standalone(window: 29292, appPid: app, appWindows: [29264, 29292], display: agentDisplay,
                                     candidates: candidates, isService: { $0 == self.service })
        XCTAssertEqual(found?.panel, 29292)
        XCTAssertEqual(found?.remote.window, 29293)
    }

    /// Safari's panel opens off its window, up and to the left: still the
    /// panel, as long as it's on the agent's display.
    func testAStandalonePanelOffItsWindowIsFound() {
        let doc = window(29374, app, documentFrame), off = CGRect(x: 5000, y: 0, width: 880, height: 790)
        let candidates = [window(29380, app, off), window(29381, service, off), doc]
        let found = Panel.standalone(window: 29374, appPid: app, appWindows: [29380, 29374], display: agentDisplay,
                                     candidates: candidates, isService: { $0 == self.service })
        XCTAssertEqual(found?.panel, 29380)
    }

    /// A panel the user opened in the same app on their own display is
    /// theirs: keys for the agent's window don't go to it.
    func testAStandalonePanelOnTheUsersDisplayIsntTheAgents() {
        let userPanel = CGRect(x: 200, y: 200, width: 880, height: 448)
        let candidates = [window(400, app, userPanel), window(401, service, userPanel), window(29264, app, documentFrame)]
        XCTAssertNil(Panel.standalone(window: 29264, appPid: app, appWindows: [400, 29264], display: agentDisplay,
                                      candidates: candidates, isService: { $0 == self.service }))
    }

    /// An app window with nothing of the service's over it is no panel.
    func testNoPanelServiceWindowMeansNoStandalonePanel() {
        let candidates = [window(29264, app, documentFrame), window(29292, app, panelFrame), window(500, 999, panelFrame)]
        XCTAssertNil(Panel.standalone(window: 29264, appPid: app, appWindows: [29292, 29264], display: agentDisplay,
                                      candidates: candidates, isService: { $0 == self.service }))
    }

    /// Another document's file picker sheet, window-backed and so listed
    /// among the app's windows, with the service's window over it: it's that
    /// document's, so a call on this document doesn't find it (review of #89).
    func testAnotherDocumentsSheetIsntThisWindowsStandalonePanel() {
        let doc = window(29264, app, documentFrame), otherSheet = window(29300, app, panelFrame)
        let candidates = [otherSheet, window(29301, service, panelFrame), doc]
        XCTAssertNil(Panel.standalone(window: 29264, appPid: app, appWindows: [29300, 29264], excluded: [29300],
                                      display: agentDisplay, candidates: candidates, isService: { $0 == self.service }))
    }

    /// A panel handed off to the user stays on the agent's display until
    /// they open it; another window of the app doesn't reach it (review of #89).
    func testAHandedOffPanelIsntFoundFromAnotherWindow() {
        let doc = window(29264, app, documentFrame), panel = window(29292, app, panelFrame)
        let candidates = [panel, window(29293, service, panelFrame), doc]
        XCTAssertNil(Panel.standalone(window: 29264, appPid: app, appWindows: [29292, 29264], excluded: [29292],
                                      display: agentDisplay, candidates: candidates, isService: { $0 == self.service }))
    }

    /// With one excluded, a panel further back is still found.
    func testAPanelBehindAnExcludedOneIsStillFound() {
        let doc = window(29264, app, documentFrame), frame2 = panelFrame.offsetBy(dx: 30, dy: 30)
        let candidates = [window(29300, app, panelFrame), window(29301, service, panelFrame),
                          window(29292, app, frame2), window(29293, service, frame2), doc]
        let found = Panel.standalone(window: 29264, appPid: app, appWindows: [29300, 29292, 29264], excluded: [29300],
                                     display: agentDisplay, candidates: candidates, isService: { $0 == self.service })
        XCTAssertEqual(found?.panel, 29292)
    }

    func testPathsAreResolved() {
        XCTAssertEqual(Panel.resolve("~/Library/../Library/x.png"), NSHomeDirectory() + "/Library/x.png")
        XCTAssertEqual(Panel.resolve("/tmp/./a/b/../c"), "/tmp/a/c")
    }
}

/// What an agent is told when keys or pixel clicks can't reach its window.
final class KeyRefusalTests: XCTestCase {
    /// An agent read "the app's key window is 102001" as the user typing in
    /// the app, and waited 75 s for them. No window ids, and say what it is.
    func testASheetRefusalSaysWhatItIsWithoutWindowIDs() {
        let text = KeyScope.refusal(sheet: true)
        XCTAssertTrue(text.contains("file picker"))
        XCTAssertTrue(text.contains("choose_file"))
        XCTAssertNil(text.range(of: #"\d{4,}"#, options: .regularExpression))
    }

    func testThePlainRefusalSaysItIsntTheUser() {
        let text = KeyScope.refusal(sheet: false)
        XCTAssertTrue(text.contains("not the user"))
        XCTAssertNil(text.range(of: #"\d{4,}"#, options: .regularExpression))
    }
}

/// What choose_file reads back of the panel's selection after Go to Folder.
final class PanelSelectionTests: XCTestCase {
    final class Node {
        let role: String
        var value: String?
        var kids: [Node]
        var selected: [String: [Node]] = [:]
        init(_ role: String, value: String? = nil, _ kids: [Node] = []) { self.role = role; self.value = value; self.kids = kids }
    }

    private let reader = Panel.Reader<Node>(role: { $0.role }, children: { $0.kids }, elements: { $0.selected[$1] ?? [] }, value: { $0.value })

    /// A row of a list: a cell, or a column view's item (an icon and the name).
    private func item(_ name: String, _ role: String = "AXGroup") -> Node {
        Node(role, [Node("AXImage"), Node("AXTextField", value: name)])
    }

    private func list(_ names: [String], selected: String, role: String = "AXList", attribute: String = "AXSelectedChildren", itemRole: String = "AXGroup") -> Node {
        let items = names.map { item($0, itemRole) }
        let l = Node(role, items)
        l.selected[attribute] = items.filter { $0.kids.last?.value == selected }
        return l
    }

    /// The open panel on macOS 27.3 after Go to Folder ~/Library/Caches/x.txt
    /// (read from the panel): the sidebar has the home folder selected, and
    /// the column view one list per column, the last with x.txt selected.
    /// choose_file said "the panel selected "admin" instead of "x.txt"".
    private func columnViewPanel() -> Node {
        let sidebar = list(["Recents", "Applications", "Desktop", "admin"], selected: "admin", role: "AXOutline", attribute: "AXSelectedRows", itemRole: "AXRow")
        let columns = [list(["Desktop", "Library", "Movies"], selected: "Library"),
                       list(["Accessibility", "Caches", "Containers"], selected: "Caches"),
                       list(["askpermissiond", "x.txt", "y.txt"], selected: "x.txt")]
        let browser = Node("AXBrowser", [Node("AXScrollArea", columns.map { Node("AXScrollArea", [$0, Node("AXScrollBar")]) })])
        return Node("AXSheet", [Node("AXSplitGroup", [Node("AXScrollArea", [sidebar]), Node("AXSplitGroup", [browser]),
                                                       Node("AXButton", value: nil)])])
    }

    func testTheFileSelectedInColumnViewIsRead() {
        XCTAssertTrue(Panel.selectedNames(columnViewPanel(), reader).contains("x.txt"))
    }

    /// The folders chosen in the columns before it aren't the selection.
    func testOnlyTheLastColumnsSelectionCounts() {
        let names = Panel.selectedNames(columnViewPanel(), reader)
        XCTAssertFalse(names.contains("Library"))
        XCTAssertFalse(names.contains("Caches"))
    }

    /// List view: the file list is an outline of rows.
    func testTheFileSelectedInListViewIsRead() {
        let files = list(["a.txt", "x.txt"], selected: "x.txt", role: "AXOutline", attribute: "AXSelectedRows", itemRole: "AXRow")
        let panel = Node("AXSheet", [Node("AXScrollArea", [files])])
        XCTAssertEqual(Panel.selectedNames(panel, reader), ["x.txt"])
    }
}
