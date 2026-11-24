import XCTest
@testable import BCUCore

/// A batch that stops on a failed step shows as a failure in History: the
/// failed step gets its own error line, and the batch's line is an error too,
/// as a standalone call that fails is.
final class BatchFailureHistoryTests: XCTestCase {
    func testAFailedBatchStepIsLoggedAndFlagged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcu-batchfail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Recordings(directory: dir)
        let engine = Engine(sessionID: "batch-failure-test", label: "Agent", focusGuard: FocusGuard())
        engine.setRecordings(store)
        engine.recorder.start()
        defer { engine.recorder.stop() }

        let result = engine.call(tool: "batch", args: [
            "actions": [["tool": "wait", "ms": 10], ["tool": "click", "element": 1]],
            "window_id": 987_654_321,
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("2. click FAILED"), result.text)

        // The popover's activity: the batch is an error.
        let batchItem = try XCTUnwrap(engine.activity.last { $0.text.hasPrefix("batch (") })
        XCTAssertTrue(batchItem.isError, batchItem.text)
        XCTAssertTrue(batchItem.text.contains("click FAILED"), batchItem.text)

        // The recording's events, which History reads.
        var events: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let runs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            events = runs.flatMap { run -> [[String: Any]] in
                let text = (try? String(contentsOf: run.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
            }
            if events.contains(where: { ($0["x"] as? String)?.hasPrefix("batch (") == true }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let step = try XCTUnwrap(events.first { ($0["x"] as? String)?.hasPrefix("click FAILED") == true },
                                 "the failed step isn't in events.jsonl: \(events)")
        XCTAssertEqual(step["e"] as? Bool, true)
        let batch = try XCTUnwrap(events.first { ($0["x"] as? String)?.hasPrefix("batch (") == true })
        XCTAssertEqual(batch["e"] as? Bool, true, "\(batch)")
    }
}
