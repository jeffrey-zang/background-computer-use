import XCTest
@testable import BCUCore

/// Pure rules only: nothing here plays, taps or mutes anything.
final class AgentAudioDefaultTests: XCTestCase {
    /// Setup done before it asked for System Audio Recording: asked once at
    /// launch, never again, and not when it's been answered.
    func testAskedOnceAtLaunchForAnEarlierSetup() {
        XCTAssertTrue(SetupGate.asksForAudioAtLaunch(setupDone: true, audio: .notAsked, asked: false))
        XCTAssertFalse(SetupGate.asksForAudioAtLaunch(setupDone: true, audio: .notAsked, asked: true))
        XCTAssertFalse(SetupGate.asksForAudioAtLaunch(setupDone: true, audio: .allowed, asked: false))
        XCTAssertFalse(SetupGate.asksForAudioAtLaunch(setupDone: true, audio: .denied, asked: false))
        XCTAssertFalse(SetupGate.asksForAudioAtLaunch(setupDone: true, audio: .unavailable, asked: false))
        // Setup itself has the step.
        XCTAssertFalse(SetupGate.asksForAudioAtLaunch(setupDone: false, audio: .notAsked, asked: false))
    }

    /// capture_audio doesn't put macOS's prompt up mid-task, and says so.
    func testNotAllowedAnswerAsksNothing() {
        let text = Engine.audioNotAllowed(appName: "Safari")
        XCTAssertTrue(text.contains("Nothing was asked of the user"), text)
        XCTAssertTrue(text.contains("Don't play sound in Safari"), text)
        XCTAssertFalse(text.contains("macOS is asking"), text)
    }

    func testSoundStartingInASharedAppWarns() {
        var told = Set<CGWindowID>()
        let note = Engine.soundNote(appName: "Safari", routed: false, shared: true, mutedTabs: [], unmutedWindows: 1,
                                    told: { !told.insert($0).inserted }, access: .allowed)!
        XCTAssertTrue(note.contains("sending sound to the user's speakers"), note)
        XCTAssertTrue(note.contains("the user has Safari windows of their own"), note)
        XCTAssertTrue(note.contains("Call capture_audio before you play sound"), note)
    }

    func testSoundInAnAgentOnlyAppWithoutPermissionWarns() {
        let note = Engine.soundNote(appName: "Music", routed: false, shared: false, mutedTabs: [], unmutedWindows: 1,
                                    told: { _ in false }, access: .notAsked)!
        XCTAssertTrue(note.contains("System Audio Recording isn't allowed"), note)
    }

    /// Muted by the tap already: nothing to say.
    func testRoutedAppsAreQuiet() {
        XCTAssertNil(Engine.soundNote(appName: "Safari", routed: true, shared: true, mutedTabs: [], unmutedWindows: 1,
                                      told: { _ in false }, access: .allowed))
    }

    /// Every window of it has its tab muted: said once per window.
    func testMutedTabIsMentionedOnce() {
        var told = Set<CGWindowID>()
        let first = Engine.soundNote(appName: "Safari", routed: false, shared: true, mutedTabs: [42], unmutedWindows: 0,
                                     told: { !told.insert($0).inserted }, access: .notAsked)
        XCTAssertTrue(first?.contains("window 42's tab is muted") == true, first ?? "nil")
        XCTAssertNil(Engine.soundNote(appName: "Safari", routed: false, shared: true, mutedTabs: [42], unmutedWindows: 0,
                                      told: { !told.insert($0).inserted }, access: .notAsked))
        // A window of it that isn't muted: warned as before.
        let mixed = Engine.soundNote(appName: "Safari", routed: false, shared: true, mutedTabs: [42], unmutedWindows: 1,
                                     told: { !told.insert($0).inserted }, access: .notAsked)
        XCTAssertTrue(mixed?.contains("isn't being kept off them") == true, mixed ?? "nil")
    }

    /// Safari's toolbar button says it for the selected tab while it plays;
    /// otherwise the record holds only while the window has one tab.
    func testTabMuteStateIsReadNotAssumed() {
        XCTAssertEqual(Engine.tabMuted(button: "Unmute This Tab", tabs: 3, recorded: false), true)
        XCTAssertEqual(Engine.tabMuted(button: "Mute This Tab", tabs: 1, recorded: true), false)
        XCTAssertEqual(Engine.tabMuted(button: nil, tabs: 0, recorded: true), true)
        XCTAssertEqual(Engine.tabMuted(button: nil, tabs: 1, recorded: true), true)
        // A second tab (one the agent opened) may be the selected one.
        XCTAssertNil(Engine.tabMuted(button: nil, tabs: 2, recorded: true))
        XCTAssertEqual(Engine.tabMuted(button: nil, tabs: 2, recorded: false), false)
    }

    /// Warnings stay quiet only when every tab is muted: the button read
    /// is the selected tab's.
    func testOnlyASingleMutedTabSilencesTheWarning() {
        XCTAssertTrue(Engine.windowMuted(button: "Unmute This Tab", tabs: 1, recorded: true))
        XCTAssertTrue(Engine.windowMuted(button: nil, tabs: 0, recorded: true))
        XCTAssertFalse(Engine.windowMuted(button: "Unmute This Tab", tabs: 2, recorded: true))
        XCTAssertFalse(Engine.windowMuted(button: nil, tabs: 1, recorded: false))
    }

    func testTabMenuTitles() {
        XCTAssertEqual(Engine.muteTabTitles, ["Mute This Tab"])
        XCTAssertEqual(Engine.unmuteTabTitles, ["Unmute This Tab"])
    }
}
