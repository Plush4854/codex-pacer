import Foundation
import PacerCore

extension GLMHookInstaller {
    /// ZCode runs `process` hooks without a shell, so the interpreter is named
    /// by absolute path: the first python3 the system itself, its tools or
    /// Homebrew provides. Entries an earlier resolution wrote stay owned.
    private static var mac: Self {
        func python() -> String {
            for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                              "/Library/Developer/CommandLineTools/usr/bin/python3"]
            where FileManager.default.fileExists(atPath: candidate) { return candidate }
            return "python3"
        }
        return Self(storage: MacClaudeHookStorage(), python: python(),
                    additionalOwnedCommand: { command, _ in command == "python3" || command.hasSuffix("/python3") })
    }
    static func status(home: URL) -> Bool { mac.status(home: home) }
    static func details(home: URL) -> Status { mac.details(home: home) }
    static func ensureInstalled(home: URL) -> EnsureResult { mac.ensureInstalled(home: home) }
    @discardableResult static func install(home: URL) throws -> Status { try mac.install(home: home) }
    @discardableResult static func migrate(home: URL) -> Bool { mac.migrate(home: home) }
    static func uninstall(home: URL) throws { try mac.uninstall(home: home) }
}
