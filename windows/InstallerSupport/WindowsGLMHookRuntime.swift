import Foundation
import PacerCore
import WinSDK

/// The GLM (ZCode) hook runtime follows the Claude one: the bundled Python,
/// laid down under Pacer's own folder, and the shared hook program wrapped by
/// the same Windows bootstrap that provides `fcntl.flock` and `private_open`.
/// Its runtime root and home journal stay separate, so Claude's cleanup never
/// reasons about ZCode homes and vice versa.
public struct WindowsGLMHookRuntime {
    public struct Report: Codable, Sendable {
        public let state: String
        public let hooksConfigured: Bool
        public let updateAvailable: Bool
        init(_ state: String, _ status: GLMHookInstaller.Status? = nil) {
            self.state = state; hooksConfigured = status?.hooksConfigured ?? false; updateAvailable = status?.updateAvailable ?? false
        }
    }
    let runtime: WindowsClaudeRuntimeStore
    public static let defaultRoot = WindowsClaudeRuntimeStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("GLMRuntime", isDirectory: true)
    public init(root: URL = WindowsGLMHookRuntime.defaultRoot) { runtime = .init(glmRoot: root) }
    static func script() throws -> Data {
        guard let adapter = Bundle.module.url(forResource: "windows_claude_bootstrap", withExtension: "py"),
              let shared = L10n.sharedResourceBundle.url(forResource: "glm_hook", withExtension: "py") else { throw GLMHookInstaller.Failure.invalidSettings }
        let source = try Data(contentsOf: shared).base64EncodedString()
        return Data(("SHARED_SOURCE = '" + source + "'\n").utf8) + (try Data(contentsOf: adapter))
    }
    static func installer(home: URL, root: URL, storage: any ClaudeHookStorage, script: Data? = nil) throws -> GLMHookInstaller {
        let pin = try WindowsPythonPin.load(), root = root.standardizedFileURL
        return GLMHookInstaller(storage: storage, python: root.appendingPathComponent(pin.identifier + "/python.exe").path,
            helperScript: script,
            additionalOwnedCommand: { command, home in owned(command, home: home, root: root) })
    }
    /// An entry Pacer wrote with an earlier copy of the runtime names that
    /// copy's `python.exe`. A `process` command is one executable path, spaces
    /// included; either path can already contain an 8.3 ancestor.
    static func owned(_ command: String, home: URL, root: URL) -> Bool {
        func expanded(_ url: URL) -> String? {
            let input = WindowsClaudeHookStorage.wide(url)
            let count = GetLongPathNameW(input, nil, 0)
            guard count > 0, count < 32768 else { return nil }
            var buffer = [UInt16](repeating: 0, count: Int(count))
            let written = GetLongPathNameW(input, &buffer, count)
            guard written > 0, written < count else { return nil }
            var path = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
            if path.hasPrefix("\\\\?\\") { path.removeFirst(4) }
            return path.replacingOccurrences(of: "\\", with: "/")
        }
        guard !command.isEmpty, !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let path = expanded(URL(fileURLWithPath: command)), let rootPath = expanded(root),
              let prefix = path.range(of: rootPath + "/", options: [.anchored, .caseInsensitive]) else { return false }
        let identifier = String(path[prefix.upperBound...].prefix { $0 != "/" })
        return WindowsClaudeRuntimeStore.validIdentifier(identifier) && path.hasSuffix("/python.exe")
    }
    public func inspect(home: URL) -> Report {
        do {
            let storage = WindowsClaudeHookStorage()
            try storage.validate(home)
            guard storage.isDirectory(home) else { return Report("missingHome") }
            let installer = try Self.installer(home: home, root: runtime.root, storage: storage, script: Self.script())
            let status = installer.details(home: home)
            let python = runtime.python(identifier: try WindowsPythonPin.load().identifier)
            try storage.validate(python)
            return Report(status.hooksConfigured && !status.updateAvailable && storage.isReadable(python) ? "ready" : "needsSetup", status)
        } catch { return Report("failed") }
    }
    public func ensure(home: URL, package: URL) -> Report {
        do {
            return try runtime.withLock {
                let storage = WindowsClaudeHookStorage()
                try storage.validate(home)
                guard storage.isDirectory(home) else { return Report("missingHome") }
                let script = try Self.script()
                let python = runtime.python(identifier: try WindowsPythonPin.load().identifier)
                // Validate through the same shared installer before creating a
                // runtime or changing configuration. The journal never commits.
                let plan = WindowsClaudeHookPlanStorage(base: storage)
                _ = try Self.installer(home: home, root: runtime.root, storage: plan, script: script).install(home: home)
                _ = try runtime.ensure(package: package, home: home)
                let installer = try Self.installer(home: home, root: runtime.root, storage: storage, script: script)
                let result = installer.ensureInstalled(home: home)
                guard result == .current || result == .installed else { return Report("failed") }
                // GC failure does not undo a working new adapter. The current
                // version is always kept; only unreferenced older ones go.
                try? runtime.collect(keeping: try WindowsPythonPin.load().identifier)
                return Report("ready", installer.details(home: home))
            }
        } catch { return Report("failed") }
    }
    public func uninstallHome(_ home: URL) throws {
        try runtime.withLock {
            try uninstallOne(home, storage: WindowsClaudeHookStorage())
            try? runtime.collect(keeping: try? WindowsPythonPin.load().identifier, extraHomes: [home])
        }
    }
    private func uninstallOne(_ home: URL, storage: any ClaudeHookStorage) throws {
        let manifest = home.appendingPathComponent("pacer/installation.json")
        try storage.validate(manifest)
        guard storage.exists(manifest) else { return }
        try storage.validate(home)
        try Self.installer(home: home, root: runtime.root, storage: storage).uninstall(home: home)
        guard !storage.exists(manifest) else { throw GLMHookInstaller.Failure.changedSettings }
    }
}
