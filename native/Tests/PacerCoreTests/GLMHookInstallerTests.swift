import XCTest
@testable import PacerCore

final class GLMHookInstallerTests: XCTestCase {
    private final class Storage: ClaudeHookStorage, @unchecked Sendable {
        var files: [URL: Data] = [:]
        var directories: Set<URL> = []
        var unsafe: Set<URL> = []
        var failures: Set<URL> = []
        var permissions: [URL: UInt16] = [:]
        var replacements = 0
        func validate(_ url: URL) throws { if unsafe.contains(url) { throw ClaudeHookInstaller.Failure.unsafePath } }
        func exists(_ url: URL) -> Bool { files[url] != nil || directories.contains(url) }
        func isDirectory(_ url: URL) -> Bool { directories.contains(url) }
        func isReadable(_ url: URL) -> Bool { files[url] != nil }
        func read(_ url: URL) throws -> Data { guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }; return data }
        func createDirectory(_ url: URL, permissions: UInt16) throws { try validate(url); directories.insert(url); self.permissions[url] = permissions }
        func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
            try validate(url); if failures.contains(url) { throw CocoaError(.fileWriteUnknown) }
            files[url] = data; self.permissions[url] = permissions; replacements += 1
        }
        func remove(_ url: URL) throws { files.removeValue(forKey: url) }
    }
    private let python = "C:/Pacer/GLMRuntime/3.14.10-abc/python.exe"
    private func fixture() -> (URL, Storage, GLMHookInstaller) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-glm", isDirectory: true)
        let storage = Storage(); storage.directories.insert(home)
        return (home, storage, GLMHookInstaller(storage: storage, python: python))
    }
    private func object(_ url: URL, _ storage: Storage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: storage.read(url)) as? [String: Any])
    }
    private func events(_ home: URL, _ storage: Storage) throws -> [String: [[String: Any]]] {
        let hooks = try XCTUnwrap(object(home.appendingPathComponent("cli/config.json"), storage)["hooks"] as? [String: Any])
        return try XCTUnwrap(hooks["events"] as? [String: [[String: Any]]])
    }
    private func ownedArguments(_ home: URL) -> [String] {
        ["-S", home.appendingPathComponent("pacer/hook.py").path, "hook", home.path]
    }

    func testFreshInstallEnablesConfigurationHooksAndWritesTheAdapter() throws {
        let (home, storage, installer) = fixture()
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let configured = try object(home.appendingPathComponent("cli/config.json"), storage)
        let hooks = try XCTUnwrap(configured["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        let events = try XCTUnwrap(hooks["events"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(events.keys), ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"])
        let entries = try XCTUnwrap(events["PreToolUse"]?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["type"] as? String, "process")
        XCTAssertEqual(entries[0]["command"] as? String, python)
        XCTAssertEqual(entries[0]["args"] as? [String], ownedArguments(home))
        XCTAssertEqual(entries[0]["timeoutMs"] as? Int, 15_000)
        XCTAssertEqual(storage.permissions[home.appendingPathComponent("pacer/hook.py")], 0o700)
        XCTAssertNotNil(storage.files[home.appendingPathComponent("pacer/hook.py")])
        XCTAssertEqual(try object(home.appendingPathComponent("pacer/installation.json"), storage)["createdConfig"] as? Bool, true)
        XCTAssertEqual(installer.ensureInstalled(home: home), .current)
        let writes = storage.replacements
        XCTAssertEqual(installer.ensureInstalled(home: home), .current, "A current installation writes nothing")
        XCTAssertEqual(storage.replacements, writes)
        XCTAssertEqual(installer.ensureInstalled(home: FileManager.default.temporaryDirectory.appendingPathComponent("absent-glm", isDirectory: true)), .missingHome)
    }

    func testUserEntriesAndSettingsSurviveInstallAndUninstallRestoresThem() throws {
        let (home, storage, installer) = fixture(), config = home.appendingPathComponent("cli/config.json")
        let user: [String: Any] = ["theme": "dark",
            "hooks": ["enabled": false, "timeoutMs": 30_000,
                "events": ["Stop": [["matcher": "done", "hooks": [["type": "command", "command": "user-hook"]]]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: user)
        storage.files[config] = bytes
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let hooks = try XCTUnwrap(object(config, storage)["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true, "Configuration-file hooks run only while enabled")
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 30_000)
        let stop = try XCTUnwrap((hooks["events"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "The user's Stop group stays and Pacer's is added")
        XCTAssertEqual((try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]]))[0]["command"] as? String, "user-hook")
        XCTAssertEqual(try object(config, storage)["theme"] as? String, "dark")
        XCTAssertEqual(installer.ensureInstalled(home: home), .current)
        try installer.uninstall(home: home)
        let restored = try object(config, storage)
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: user), "Uninstall restores the exact configuration, enabled flag included")
        XCTAssertNil(storage.files[home.appendingPathComponent("pacer/installation.json")])
        XCTAssertNotNil(storage.files[home.appendingPathComponent("pacer/hook.py")], "The sanitized spool folder outlives uninstall for late accounting")
    }

    func testAnAlreadyEnabledConfigurationStaysOwnedByTheUser() throws {
        let (home, storage, installer) = fixture(), config = home.appendingPathComponent("cli/config.json")
        let user: [String: Any] = ["hooks": ["enabled": true]]
        storage.files[config] = try JSONSerialization.data(withJSONObject: user)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: try object(config, storage), options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: user, options: [.sortedKeys]),
                       "Pacer did not enable the hooks, so it does not disable them")
    }

    func testAConfigurationPacerCreatedIsTakenAwayWhenNothingRemains() throws {
        let (home, storage, installer) = fixture(), config = home.appendingPathComponent("cli/config.json")
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        XCTAssertNil(storage.files[config], "Pacer created the file and the user added nothing")
        storage.files[config] = Data(#"{"theme":"dark"}"#.utf8)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        XCTAssertEqual(try object(config, storage)["theme"] as? String, "dark", "A file the user wrote to is kept")
    }

    func testAMovedInterpreterIsMigratedInPlaceAndFailuresPreserveTheConfiguration() throws {
        let (home, storage, installer) = fixture(), config = home.appendingPathComponent("cli/config.json")
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let moved = "C:/Pacer/GLMRuntime/3.14.11-def/python.exe"
        let updated = GLMHookInstaller(storage: storage, python: moved, additionalOwnedCommand: { command, _ in command.hasPrefix("C:/Pacer/GLMRuntime/") })
        XCTAssertTrue(updated.details(home: home).updateAvailable, "An entry naming the earlier interpreter predates this version")
        XCTAssertEqual(updated.ensureInstalled(home: home), .installed)
        let group = try XCTUnwrap(events(home, storage)["PreToolUse"]?.first)
        let entry = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["command"] as? String, moved)
        XCTAssertEqual(updated.ensureInstalled(home: home), .current)
        // A failed write leaves the configuration and the manifest untouched.
        let previousManifest = storage.files[home.appendingPathComponent("pacer/installation.json")]
        storage.failures.insert(config)
        storage.files[home.appendingPathComponent("pacer/hook.py")] = Data("changed".utf8)
        XCTAssertEqual(updated.ensureInstalled(home: home), .installed, "The adapter is refreshed; the configuration update is retried on the next pass")
        XCTAssertEqual(storage.files[home.appendingPathComponent("pacer/installation.json")], previousManifest, "A failed write cannot claim ownership")
        storage.failures.remove(config)
        XCTAssertEqual(updated.ensureInstalled(home: home), .current, "The configuration was already current before the failed write")
        XCTAssertNotEqual(storage.files[home.appendingPathComponent("pacer/hook.py")], Data("changed".utf8))
    }

    func testMalformedOrForeignEntriesAreRefusedAndPreserved() throws {
        let (home, storage, installer) = fixture(), config = home.appendingPathComponent("cli/config.json")
        let malformed = Data(#"{"hooks":[]}"#.utf8)
        storage.files[config] = malformed
        XCTAssertEqual(installer.ensureInstalled(home: home), .failed)
        XCTAssertEqual(storage.files[config], malformed)
        let foreign = Data(##"{"hooks":{"enabled":true,"events":{"Stop":[{"hooks":[{"type":"process","command":"someone-else","args":["-S","#"]}]},{}]}}}"##.utf8)
        storage.files[config] = foreign
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed, "Pacer adds its group alongside entries it does not own")
        let groups = try XCTUnwrap(events(home, storage)["Stop"])
        XCTAssertEqual(groups.count, 3)
        try installer.uninstall(home: home)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: foreign) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: try object(config, storage)).isEqual(to: restored), "Only Pacer's own group is removed")
    }
}
