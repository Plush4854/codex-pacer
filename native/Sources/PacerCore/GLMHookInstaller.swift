import Foundation

/// Pacer keeps its hooks current while the GLM module is on. ZCode runs the
/// same event envelopes Claude hooks use, registered as argument vectors
/// without a shell, and runs configuration-file hooks only while
/// `hooks.enabled` is true — an entry Pacer adds first and withdraws last,
/// with everything it touched recorded in its own manifest.
public struct GLMHookInstaller {
    public enum EnsureResult: Equatable, Sendable { case current, installed, missingHome, failed }
    public struct Status: Equatable, Sendable {
        public let hooksConfigured: Bool
        /// Owned entries or the installed adapter predate this version.
        public var updateAvailable = false
        public init(hooksConfigured: Bool, updateAvailable: Bool = false) {
            self.hooksConfigured = hooksConfigured; self.updateAvailable = updateAvailable
        }
    }
    public enum Failure: Error, LocalizedError {
        case invalidSettings, unsafePath, changedSettings
        public var errorDescription: String? {
            switch self {
            case .invalidSettings: return "ZCode configuration must contain a valid JSON object; the existing configuration was preserved."
            case .unsafePath: return "GLM monitoring cannot use a symlink or a directory owned by another user."
            case .changedSettings: return "ZCode configuration changed during setup; retry after the other edit finishes."
            }
        }
    }
    private let storage: any ClaudeHookStorage
    private let python: String
    private let helperScript: Data?
    private let additionalOwnedCommand: @Sendable (String, URL) -> Bool

    public init(storage: any ClaudeHookStorage, python: String, helperScript: Data? = nil,
                additionalOwnedCommand: @escaping @Sendable (String, URL) -> Bool = { _, _ in false }) {
        self.storage = storage; self.python = python; self.helperScript = helperScript
        self.additionalOwnedCommand = additionalOwnedCommand
    }

    /// ZCode fires exactly these seven events; any other name is unsupported.
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"]
    private static let timeoutMilliseconds = 15_000
    /// ZCode reads its hooks from `cli/config.json` inside the data folder.
    private static let configFile = "cli/config.json"

    public func status(home: URL) -> Bool { details(home: home).hooksConfigured }
    /// Never creates a ZCode home and writes nothing when already current.
    public func ensureInstalled(home: URL) -> EnsureResult {
        guard storage.isDirectory(home) else { return .missingHome }
        let status = details(home: home)
        if status.hooksConfigured && !status.updateAvailable { return .current }
        if status.hooksConfigured, migrate(home: home), !details(home: home).updateAvailable { return .installed }
        return (try? install(home: home)) != nil ? .installed : .failed
    }
    public func details(home: URL) -> Status {
        let value = (try? config(home: home).value) ?? [:]
        let hooks = value["hooks"] as? [String: Any] ?? [:]
        let events = hooks["events"] as? [String: Any] ?? [:]
        let script = home.appendingPathComponent("pacer/hook.py")
        let scriptAvailable = (try? safe(script)) != nil && storage.isReadable(script)
        let configured = scriptAvailable && hooks["enabled"] as? Bool == true &&
            Self.events.allSatisfy { event in (events[event] as? [[String: Any]])?.contains { containsOwned($0, home: home) } == true }
        var status = Status(hooksConfigured: configured)
        var needsUpdate = false
        if configured {
            do { needsUpdate = try migrated(value, home: home) != nil }
            catch { needsUpdate = true }
        }
        status.updateAvailable = needsUpdate || configured && installedScriptOutdated(home: home)
        return status
    }
    @discardableResult public func install(home: URL) throws -> Status {
        try safe(home)
        let existing = try config(home: home)
        let directory = home.appendingPathComponent("pacer"), manifestURL = directory.appendingPathComponent("installation.json")
        try safe(directory); try safe(manifestURL)
        var value = existing.value
        var hooks = try validatedHooks(value)
        var events = hooks["events"] as? [String: Any] ?? [:]
        var manifest = (try? readObject(manifestURL)) ?? [:]
        for event in Self.events { events[event] = ensureOwned(events[event] as? [[String: Any]] ?? [], home: home) }
        // ZCode runs configuration-file hooks only while this is true. The
        // previous value, or its absence, is restored on uninstall.
        if hooks["enabled"] as? Bool != true, manifest["enabledPrevious"] == nil {
            manifest["enabledPrevious"] = hooks["enabled"] ?? NSNull()
        }
        hooks["enabled"] = true
        hooks["events"] = events
        value["hooks"] = hooks
        manifest["version"] = 1
        if existing.bytes == nil { manifest["createdConfig"] = true }
        try storage.createDirectory(directory, permissions: 0o700)
        try storage.createDirectory(home.appendingPathComponent("cli"), permissions: 0o755)
        try safe(directory); try safe(home.appendingPathComponent(Self.configFile)); try safe(manifestURL)
        try writeScript(home: home)
        try writeInstallation(value, manifest: manifest, home: home, expected: existing.bytes)
        return details(home: home)
    }
    /// Upgrade an existing installation in place: refresh Pacer's adapter and
    /// rewrite only Pacer-owned entries. Nothing the user removed is re-added.
    @discardableResult public func migrate(home: URL) -> Bool {
        let manifestURL = home.appendingPathComponent("pacer/installation.json")
        guard (try? safe(home)) != nil, (try? safe(manifestURL)) != nil, storage.exists(manifestURL),
              let existing = try? config(home: home) else { return false }
        var changed = false
        if installedScriptOutdated(home: home), (try? writeScript(home: home)) != nil { changed = true }
        guard let updated = try? migrated(existing.value, home: home),
              (try? writeInstallation(updated.value, manifest: updated.manifest, home: home, expected: existing.bytes)) != nil else { return changed }
        return true
    }
    public func uninstall(home: URL) throws {
        try safe(home)
        let existing = try config(home: home), manifestURL = home.appendingPathComponent("pacer/installation.json")
        guard var manifest = try? readObject(manifestURL) else { return }
        let createdConfig = manifest["createdConfig"] as? Bool == true
        manifest.removeValue(forKey: "createdConfig")
        var value = existing.value, hooks = try validatedHooks(value)
        var events = hooks["events"] as? [String: Any] ?? [:]
        for event in Self.events {
            guard let groups = events[event] as? [[String: Any]] else { continue }
            let remaining = removingOwned(groups, home: home)
            if remaining.isEmpty { events.removeValue(forKey: event) } else { events[event] = remaining }
        }
        if events.isEmpty { hooks.removeValue(forKey: "events") } else { hooks["events"] = events }
        if let previous = manifest.removeValue(forKey: "enabledPrevious") {
            if previous is NSNull { hooks.removeValue(forKey: "enabled") }
            else if hooks["enabled"] as? Bool == true { hooks["enabled"] = previous }
        }
        if hooks.isEmpty { value.removeValue(forKey: "hooks") } else { value["hooks"] = hooks }
        guard try config(home: home).bytes == existing.bytes else { throw Failure.changedSettings }
        // A configuration file Pacer created that holds nothing of the user's
        // is taken away; the user's own file, or one Pacer only added to, is kept.
        if value.isEmpty && createdConfig {
            try storage.remove(home.appendingPathComponent(Self.configFile))
        } else {
            try write(value, to: home.appendingPathComponent(Self.configFile))
        }
        // Keep the sanitized spool/metadata for late accounting, as the Claude
        // uninstaller does; only entries Pacer owns are removed.
        try? storage.remove(manifestURL)
    }
    /// The configuration with only Pacer-owned entries brought current, or nil
    /// when nothing differs. Canonical JSON bytes decide: rebuilt Swift values
    /// and the file's parsed JSON then compare by content, not by class.
    private func migrated(_ value: [String: Any], home: URL) throws -> (value: [String: Any], manifest: [String: Any])? {
        guard var hooks = try? validatedHooks(value) else { return nil }
        var events = hooks["events"] as? [String: Any] ?? [:]
        for event in Self.events {
            guard let groups = events[event] as? [[String: Any]], groups.contains(where: { containsOwned($0, home: home) }) else { continue }
            events[event] = ensureOwned(groups, home: home)
        }
        hooks["events"] = events
        let previousManifest = (try? readObject(home.appendingPathComponent("pacer/installation.json"))) ?? [:]
        var manifest = previousManifest
        if hooks["enabled"] as? Bool != true {
            if manifest["enabledPrevious"] == nil { manifest["enabledPrevious"] = hooks["enabled"] ?? NSNull() }
            hooks["enabled"] = true
        }
        manifest["version"] = 1
        var result = value
        result["hooks"] = hooks
        func canonical(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        return canonical(result) == canonical(value) && canonical(manifest) == canonical(previousManifest)
            ? nil : (result, manifest)
    }
    private func writeInstallation(_ value: [String: Any], manifest: [String: Any], home: URL, expected: Data?) throws {
        guard try config(home: home).bytes == expected else { throw Failure.changedSettings }
        let url = home.appendingPathComponent("pacer/installation.json"), previous = try? storage.read(url)
        try write(manifest, to: url)
        do { try write(value, to: home.appendingPathComponent(Self.configFile)) }
        catch {
            if let previous { try? storage.replace(url, with: previous, permissions: 0o600) }
            else { try? storage.remove(url) }
            throw error
        }
    }
    /// A `process` entry: ZCode runs the argument vector without a shell, so
    /// no command string is serialized or quoted on any platform.
    private func ownedEntry(home: URL) -> [String: Any] {
        ["type": "process", "command": python, "args": ownedArguments(home: home), "timeoutMs": Self.timeoutMilliseconds]
    }
    private func ownedArguments(home: URL) -> [String] {
        ["-S", home.appendingPathComponent("pacer/hook.py").path, "hook", home.path]
    }
    private func owned(_ entry: [String: Any], home: URL) -> Bool {
        guard entry["type"] as? String == "process", let command = entry["command"] as? String,
              let arguments = entry["args"] as? [String] else { return false }
        guard command == python || additionalOwnedCommand(command, home) else { return false }
        let suffix = Array(ownedArguments(home: home).dropFirst())
        let values = arguments.map { $0.replacingOccurrences(of: "\\", with: "/") }
        let trail = values.count >= suffix.count ? Array(values.suffix(suffix.count)) : []
        return trail == suffix && (values.count == suffix.count || values[values.count - suffix.count - 1] == "-S")
    }
    private func containsOwned(_ group: [String: Any], home: URL) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { owned($0, home: home) } == true
    }
    /// Exactly one current owned group, appended where none was installed.
    private func ensureOwned(_ groups: [[String: Any]], home: URL) -> [[String: Any]] {
        guard groups.contains(where: { containsOwned($0, home: home) }) else { return groups + [["hooks": [ownedEntry(home: home)]]] }
        return groups.map { group in
            guard let entries = group["hooks"] as? [[String: Any]], entries.contains(where: { owned($0, home: home) }) else { return group }
            var group = group
            group["hooks"] = entries.map { owned($0, home: home) ? ownedEntry(home: home) : $0 }
            return group
        }
    }
    private func removingOwned(_ groups: [[String: Any]], home: URL) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            var group = group; let kept = entries.filter { !owned($0, home: home) }
            if kept.isEmpty { return nil }; group["hooks"] = kept; return group
        }
    }
    private func writeScript(home: URL) throws {
        let script = home.appendingPathComponent("pacer/hook.py"); try safe(script)
        if let helperScript { try storage.replace(script, with: helperScript, permissions: 0o700); return }
        guard let resource = Bundle.module.url(forResource: "glm_hook", withExtension: "py") else { throw Failure.invalidSettings }
        try storage.replace(script, with: try Data(contentsOf: resource), permissions: 0o700)
    }
    private func installedScriptOutdated(home: URL) -> Bool {
        let script = home.appendingPathComponent("pacer/hook.py")
        if let helperScript {
            guard (try? safe(script)) != nil, let installed = try? storage.read(script) else { return false }
            return helperScript != installed
        }
        guard let resource = Bundle.module.url(forResource: "glm_hook", withExtension: "py"),
              (try? safe(script)) != nil, let installed = try? storage.read(script) else { return false }
        return (try? Data(contentsOf: resource)) != installed
    }
    private func validatedHooks(_ value: [String: Any]) throws -> [String: Any] {
        guard value["hooks"] == nil || value["hooks"] is [String: Any] else { throw Failure.invalidSettings }
        let hooks = value["hooks"] as? [String: Any] ?? [:]
        guard hooks["events"] == nil || hooks["events"] is [String: Any] else { throw Failure.invalidSettings }
        guard hooks["enabled"] == nil || hooks["enabled"] is Bool else { throw Failure.invalidSettings }
        if let events = hooks["events"] as? [String: Any] {
            for event in Self.events where events[event] != nil {
                guard events[event] is [[String: Any]] else { throw Failure.invalidSettings }
            }
        }
        return hooks
    }
    private func config(home: URL) throws -> (value: [String: Any], bytes: Data?) {
        let file = home.appendingPathComponent(Self.configFile); try safe(file)
        guard storage.exists(file) else { return ([:], nil) }
        let bytes = try storage.read(file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }
        return (value, bytes)
    }
    private func readObject(_ file: URL) throws -> [String: Any] {
        try safe(file); let bytes = try storage.read(file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }; return value
    }
    private func safe(_ file: URL) throws {
        guard !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsafePath }
        try storage.validate(file)
    }
    private func write(_ value: [String: Any], to file: URL) throws {
        try safe(file); let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try storage.replace(file, with: data, permissions: 0o600)
    }
}
