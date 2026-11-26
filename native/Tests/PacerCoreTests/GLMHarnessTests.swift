import XCTest
@testable import PacerCore

final class GLMHarnessTests: XCTestCase {
    private struct NoEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool,
                   changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { nil }
    }
    private struct RealFiles: PlatformFileSystem {
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return .init(identity: "\(device):\(inode)", size: size,
                modified: attributes[.modificationDate] as? Date ?? .distantPast,
                created: attributes[.creationDate] as? Date,
                isRegularFile: attributes[.type] as? FileAttributeType == .typeRegular,
                isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory)
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: maximumBytes) ?? Data()
        }
        func replace(_ url: URL, with data: Data) -> Bool { false }
        func entries(in directory: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
    }

    /// The module registers with its own identity, home and task capability.
    func testTheModuleRegistersThroughTheSharedFramework() throws {
        let descriptor = try XCTUnwrap(HarnessRegistry.descriptor(for: .glm))
        XCTAssertEqual(descriptor.name, "GLM ZCode")
        XCTAssertFalse(descriptor.hasTaskProgress, "GLM does not report an estimate yet, so no progress ring is offered")
        XCTAssertFalse(descriptor.hasRateDisplay)
        XCTAssertEqual(descriptor.balance, .quotaWindows)
        XCTAssertTrue(descriptor.hasQuotaWindows)
        XCTAssertTrue(HarnessRegistry.ids.contains(.glm))
        XCTAssertFalse(HarnessRegistry.legacyIDs.contains(.glm))
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .glm })
        XCTAssertEqual(definition.home, ".zcode")
        XCTAssertEqual(definition.platforms, [.windows, .macOS])
        XCTAssertEqual(definition.homeEnvironmentKey, "GLM_CONFIG_DIR")
        XCTAssertEqual(AgentProvider(rawValue: "glm"), .glm)
    }

    /// Rows the GLM hook writes drive the shared turn machine under Pacer's
    /// own identity, with attention requests for pending approvals.
    func testSpoolRowsProduceGLMSessionsAndAttention() throws {
        var state = ClaudeActivityState(provider: .glm, fallbackProject: "GLM ZCode")
        let now = Date(), identifier = "32ae56a4-7f83-4397-9bd4-155e2d0c105b"
        let payload: [[String: Any]] = [
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 40, "kind": "metadata",
             "project": "johncrm", "sessionLaunch": true],
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 39, "kind": "prompt",
             "promptId": "p1", "itemId": "attention"],
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 30, "kind": "toolStart",
             "promptId": "p1", "itemId": "t1", "attention": "none"],
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 20, "kind": "approval",
             "promptId": "p1", "itemId": "t1"],
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 10, "kind": "toolEnd",
             "promptId": "p1", "itemId": "t1"],
            ["origin": "hook", "sessionId": identifier, "at": now.timeIntervalSince1970 - 5, "kind": "stop",
             "promptId": "p1", "itemId": "attention"]
        ]
        // Records arrive as frames, as the reader delivers them.
        for record in payload {
            let frame = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            state.consume(frame, now: now)
        }
        state.finalizeHistoricalBaseline(now: now)
        let activities = state.activities
        XCTAssertEqual(activities.count, 1)
        let row = try XCTUnwrap(activities.first)
        XCTAssertEqual(row.provider, .glm)
        XCTAssertEqual(row.id, AgentProvider.glm.activityID(sessionID: row.threadID ?? "", sourceHostID: nil))
        XCTAssertTrue(row.id.hasPrefix("glm:local:"), "GLM rows never borrow Claude's identity")
        XCTAssertEqual(row.project, "johncrm")
        XCTAssertEqual(row.phase, .completed, "A final stop ends the turn")
        XCTAssertTrue(state.attention.allSatisfy { $0.provider == .glm })
    }

    /// The monitor tails the spool Pacer's GLM hook writes, and stays silent
    /// about a home that has no spool yet.
    func testMonitorPublishesSpoolSessionsAndReportsAMissingSpool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-glm-monitor", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let home = root.appendingPathComponent(".zcode", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        let clock = Date()
        let monitor = GLMHarnessMonitor(io: .init(files: RealFiles(), events: NoEvents(), now: { clock }))
        var observed: [HarnessActivity] = []
        await monitor.start(home: home, policy: .collapsed) { observed.append($0) }
        XCTAssertEqual(observed.last?.status, .unavailable, "A home without the spool is installed but idle")
        let identifier = "32ae56a4-7f83-4397-9bd4-155e2d0c105b"
        let record: [String: Any] = ["origin": "hook", "sessionId": identifier, "at": clock.timeIntervalSince1970,
                                     "kind": "metadata", "project": "johncrm", "sessionLaunch": true]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self) + "\n"
        try Data(line.utf8).write(to: home.appendingPathComponent("pacer/events.jsonl"))
        await monitor.refresh()
        let activity = try XCTUnwrap(observed.last)
        XCTAssertEqual(activity.status, .ready)
        XCTAssertEqual(activity.activities.count, 1)
        XCTAssertEqual(activity.activities.first?.provider, .glm)
        XCTAssertEqual(activity.activities.first?.project, "johncrm")
        await monitor.stop()
    }
}
