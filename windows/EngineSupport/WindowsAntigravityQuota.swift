import Foundation
import PacerCore

/// Receives the documented Antigravity CLI status line locally. The payload's
/// account name and conversation fields are never written to disk or projected.
enum WindowsAntigravityQuota {
    private static let option = "--antigravity-quota"
    private static let limit = 256 * 1024
    private static let maxWindows = 16
    private static let freshness: TimeInterval = 600
    private static let refreshInterval: TimeInterval = 300
    private static let backgroundRefreshKey = "PACER_ANTIGRAVITY_QUOTA_REFRESH"

    struct Window: Codable, Equatable {
        let id: String
        let percent: Double?
        let amount: Double?
        let resetsAt: TimeInterval?
        var stale = false
    }

    /// The CLI's model catalog command initializes its quota feed without
    /// starting a conversation. The CLI retains responsibility for sign-in.
    static func refreshIfDue(home: URL, now: Date) async {
        let files = paths(home: home), storage = WindowsLocalProfileStorage()
        let timestamp = now.timeIntervalSince1970
        if let sample = readSample(files.sample, storage: storage),
           !sample.windows.isEmpty, (0..<refreshInterval).contains(timestamp - sample.receivedAt),
           !sample.windows.contains(where: { $0.resetsAt.map { $0 > 0 && $0 <= timestamp } ?? false }) { return }
        // Launch only while the standard profile still uses our callback.
        guard let receipt = try? storage.read(files.receipt), receipt.count <= limit,
              let settings = try? WindowsAntigravity.object(storage.read(files.settings), limit: limit),
              let line = settings["statusLine"] as? [String: Any],
              let current = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]),
              current == receipt,
              let local = WindowsEnvironment.value("LOCALAPPDATA", in: ProcessInfo.processInfo.environment),
              WindowsURLHandler.localDrivePath(local) else { return }
        let cli = URL(fileURLWithPath: local, isDirectory: true).appendingPathComponent("agy/bin/agy.exe")
        guard (try? storage.validate(cli)) != nil, WindowsFileSystem().metadata(cli)?.isRegularFile == true,
              !Task.isCancelled else { return }
        var environment = ProcessInfo.processInfo.environment
        environment[backgroundRefreshKey] = "1"
        _ = await WindowsSubprocess.capture(executable: cli, arguments: ["models"], timeout: 12, limit: 64 * 1024,
                                            workingDirectory: home, environment: environment)
        // The provider dispatches status line invocations asynchronously.
        try? await Task.sleep(for: .seconds(2))
    }

    private struct Sample: Codable {
        let receivedAt: TimeInterval
        let windows: [Window]
    }

    struct Presentation: Codable, Equatable {
        let windows: [Window]
        let configured: Bool
    }

    private static func paths(home: URL) -> (settings: URL, receipt: URL, sample: URL) {
        let directory = home.appendingPathComponent(AntigravityTask.folder, isDirectory: true)
        let cli = home.deletingLastPathComponent().appendingPathComponent("antigravity-cli", isDirectory: true)
        return (cli.appendingPathComponent("settings.json"), directory.appendingPathComponent("quota-registration.json"),
                directory.appendingPathComponent("quota.json"))
    }

    /// Antigravity has one status line slot. Keep an existing user script and
    /// its options intact. A receipt lets us update or remove our own entry.
    static func configure(home: URL, executable: String, enabled: Bool,
                          storage: any ClaudeHookStorage = WindowsLocalProfileStorage()) throws {
        let files = paths(home: home)
        try storage.validate(files.settings)
        try storage.validate(files.receipt)
        guard storage.isDirectory(home), storage.isDirectory(files.settings.deletingLastPathComponent()) else { return }
        let oldReceipt = try storage.exists(files.receipt) ? storage.read(files.receipt) : nil
        if !enabled, oldReceipt == nil { return }
        func settingsData() throws -> Data? { try storage.exists(files.settings) ? storage.read(files.settings) : nil }
        let original = try settingsData()
        var settings = try original.map { try WindowsAntigravity.object($0, limit: limit) } ?? [:]
        func encode(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let command = try WindowsAntigravity.command(executable: executable, option: option, additional: [], home: home)
        let line: [String: Any] = ["type": "command", "command": command, "stack_with_default": true]
        let desired = try encode(line)
        let current = try (settings["statusLine"] as? [String: Any]).map(encode)
        if settings["statusLine"] != nil, current == nil || (current != desired && current != oldReceipt) { return }
        if enabled && current != desired {
            settings["statusLine"] = line
        } else if !enabled && current != nil {
            settings.removeValue(forKey: "statusLine")
        }
        if enabled ? current != desired : current != nil {
            let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            guard updated.count <= limit, try settingsData() == original else { throw ClaudeHookInstaller.Failure.changedSettings }
            try storage.replace(files.settings, with: updated + Data([10]), permissions: 0o600)
        }
        if enabled, oldReceipt != desired {
            try storage.replace(files.receipt, with: desired, permissions: 0o600)
        } else if !enabled {
            if storage.exists(files.receipt) { try storage.remove(files.receipt) }
            if storage.exists(files.sample) { try storage.remove(files.sample) }
        }
    }

    static func runIfRequested(args: [String], read: () throws -> Data?) -> Bool {
        guard args.count > 1, args[1] == option else { return false }
        guard args.count == 3, WindowsURLHandler.localDrivePath(args[2]) else { return true }
        let home = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        do {
            var payload = Data()
            while let bytes = try read(), !bytes.isEmpty {
                guard payload.count + bytes.count <= limit else { return true }
                payload.append(bytes)
            }
            let object = try WindowsAntigravity.object(payload, limit: limit)
            try capture(object, home: home, now: Date())
        } catch {
            // Quota collection leaves the built-in CLI status line usable.
        }
        return true
    }

    private static func capture(_ object: [String: Any], home: URL, now: Date) throws {
        let files = paths(home: home), storage = WindowsLocalProfileStorage()
        try storage.validate(files.receipt)
        guard storage.exists(files.receipt), object["product"] as? String == "antigravity" else { return }
        let quota = object["quota"] as? [String: [String: Any]] ?? [:]
        let receivedAt = now.timeIntervalSince1970
        let windows = quota.keys.sorted().compactMap { id -> Window? in
            guard allowed(id), let bucket = quota[id], bucket["disabled"] as? Bool != true else { return nil }
            let percent = number(bucket["remaining_fraction"], max: 1).map { 100 * $0 }
            let amount = percent == nil ? number(bucket["remaining_amount"], max: 1e12) : nil
            guard percent != nil || amount != nil else { return nil }
            let absolute = (bucket["reset_time"] as? String).flatMap { value -> Date? in
                guard value.utf8.count <= 48 else { return nil }
                return try? Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")).parse(value)
            }?.timeIntervalSince1970
            let offset = number(bucket["reset_in_seconds"], max: 2_678_400).flatMap { $0 > 0 ? receivedAt + $0 : nil }
            return Window(id: id, percent: percent, amount: amount, resetsAt: absolute ?? offset)
        }
        if windows.isEmpty {
            guard object["agent_state"] as? String == "authenticating",
                  ProcessInfo.processInfo.environment[backgroundRefreshKey] != "1" else { return }
        }
        let sample = Sample(receivedAt: receivedAt, windows: Array(windows.prefix(maxWindows)))
        try storage.replace(files.sample, with: JSONEncoder().encode(sample), permissions: 0o600)
    }

    static func presentation(home: URL, now: Date) -> Presentation {
        let files = paths(home: home), storage = WindowsLocalProfileStorage()
        let configured = storage.exists(files.receipt)
        guard configured, let sample = readSample(files.sample, storage: storage) else {
            return Presentation(windows: [], configured: configured)
        }
        let timestamp = now.timeIntervalSince1970
        let windows = sample.windows.prefix(maxWindows).filter {
            allowed($0.id) && ($0.percent.map { (0...100).contains($0) } ?? $0.amount.map { (0...1e12).contains($0) } ?? false)
        }.map { window in
            var value = window
            value.stale = timestamp - sample.receivedAt >= freshness || sample.receivedAt > timestamp + 60 ||
                (window.resetsAt.map { $0 > 0 && timestamp >= $0 } ?? false)
            return value
        }
        return Presentation(windows: windows, configured: true)
    }

    private static func readSample(_ url: URL, storage: WindowsLocalProfileStorage) -> Sample? {
        guard let metadata = WindowsFileSystem().metadata(url), metadata.isRegularFile, metadata.size <= 8192,
              let data = try? storage.read(url), data.count <= 8192 else { return nil }
        return try? JSONDecoder().decode(Sample.self, from: data)
    }

    private static func allowed(_ id: String) -> Bool {
        id.utf8.count <= 64 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    private static func number(_ value: Any?, max: Double) -> Double? {
        guard let value, !(value is String), let bytes = try? JSONSerialization.data(withJSONObject: [value]),
              let amount = try? JSONDecoder().decode([Double].self, from: bytes).first,
              amount.isFinite, (0...max).contains(amount) else { return nil }
        return amount
    }
}
