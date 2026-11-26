import Foundation
import PacerCore
import WinSDK

enum WindowsAntigravity {
    private static let option = "--antigravity-hook"
    private static let group = "codex-pacer-antigravity"
    private static let progressTool = "mcp_pacer_progress_report_progress"
    private static let configurationLimit = 256 * 1024
    private static let payloadLimit = 2 * 1024 * 1024
    private static let markerData = Data("on\n".utf8)

    private enum Event: String, CaseIterable {
        case before = "PreInvocation"
        case after = "PostInvocation"
        case tool = "PostToolUse"
        case stop = "Stop"
    }

    /// The App and IDE share this global configuration. The receipt lets Pacer
    /// update or remove its own entry without overwriting other hooks.
    static func configure(home: URL, executable: String, enabled: Bool,
                          storage: any ClaudeHookStorage = WindowsLocalProfileStorage()) throws {
        let config = home.appendingPathComponent("hooks.json")
        let folder = home.appendingPathComponent(AntigravityTask.folder, isDirectory: true)
        let marker = folder.appendingPathComponent(AntigravityTask.enabledFile)
        let receipt = folder.appendingPathComponent("hook-registration.json")
        for path in [home, config, folder, marker, receipt] { try storage.validate(path) }
        guard storage.isDirectory(home) else {
            if enabled { throw ClaudeHookInstaller.Failure.invalidSettings }
            return
        }
        if !enabled, storage.exists(marker), try storage.read(marker) == markerData { try storage.remove(marker) }
        if !enabled, !storage.exists(receipt) { return }
        func readConfig() throws -> Data? { try storage.exists(config) ? storage.read(config) : nil }
        let original = try readConfig()
        let oldSettings = try original.map { try object($0, limit: configurationLimit) } ?? [:]
        var settings = oldSettings
        let owned = try storage.exists(receipt) ? object(storage.read(receipt), limit: configurationLimit) : nil
        func encode(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        var desired = [String: Any]()
        for event in Event.allCases {
            let command = try Self.command(executable: executable, option: option, additional: [event.rawValue], home: home)
            let actions: [[String: Any]] = [["type": "command", "command": command, "timeout": 3]]
            if event == .tool {
                desired[event.rawValue] = [["matcher": "^\(progressTool)$|^call_mcp_tool$", "hooks": actions]]
            } else {
                desired[event.rawValue] = actions
            }
        }
        let expected = try encode(desired)
        let previous = try owned.map(encode)
        if let current = settings[group] {
            guard let entry = current as? [String: Any] else { throw ClaudeHookInstaller.Failure.changedSettings }
            let actual = try encode(entry)
            guard actual == expected || actual == previous else { throw ClaudeHookInstaller.Failure.changedSettings }
        }
        if enabled {
            if !storage.isDirectory(folder) { try storage.createDirectory(folder, permissions: 0o700) }
            settings[group] = desired
        } else {
            settings.removeValue(forKey: group)
        }
        if try encode(settings) != encode(oldSettings) {
            let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
            guard updated.count <= configurationLimit, try readConfig() == original else { throw ClaudeHookInstaller.Failure.changedSettings }
            try storage.replace(config, with: updated, permissions: 0o600)
        }
        if enabled {
            if previous != expected { try storage.replace(receipt, with: expected, permissions: 0o600) }
            if !storage.exists(marker) { try storage.replace(marker, with: markerData, permissions: 0o600) }
        } else if storage.exists(receipt) {
            try storage.remove(receipt)
        }
    }

    static func command(executable: String, option: String, additional: [String], home: URL) throws -> String {
        // Antigravity can pass the command as one argument to cmd.exe.
        // Encoding the script keeps spaced installation and profile paths intact.
        var buffer = [UInt16](repeating: 0, count: 32768)
        let count = GetSystemDirectoryW(&buffer, UInt32(buffer.count))
        guard count > 0, Int(count) < buffer.count, WindowsURLHandler.localDrivePath(executable),
              WindowsURLHandler.localDrivePath(home.path) else { throw ClaudeHookInstaller.Failure.unsafePath }
        let directory = String(decoding: buffer.prefix(Int(count)), as: UTF16.self).replacingOccurrences(of: "\\", with: "/")
        guard directory.range(of: #"^[A-Za-z]:/[\p{L}\p{M}\p{N}_./~-]+\z"#, options: .regularExpression) != nil else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let arguments = ([option] + additional).joined(separator: " ")
        let script = "& \(literal(executable)) \(arguments) \(literal(home.path)); exit $LASTEXITCODE"
        guard let encoded = script.data(using: .utf16LittleEndian)?.base64EncodedString(), encoded.count < 7000 else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        return directory + "/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded
    }

    static func object(_ data: Data, limit: Int) throws -> [String: Any] {
        guard data.count <= limit, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeHookInstaller.Failure.invalidSettings
        }
        return value
    }

    static func runIfRequested(args: [String], read: () throws -> Data?) -> Bool {
        guard args.count > 1, args[1] == option else { return false }
        guard args.count == 4, let event = Event(rawValue: args[2]), WindowsURLHandler.localDrivePath(args[3]) else { return true }
        var response: [String: Any] = event == .stop ? ["decision": "allow"] : [:]
        do {
            var input = Data()
            while let chunk = try read(), !chunk.isEmpty {
                guard input.count + chunk.count <= payloadLimit else { throw ClaudeHookInstaller.Failure.invalidSettings }
                input.append(chunk)
            }
            let payload = try object(input, limit: payloadLimit)
            let home = URL(fileURLWithPath: args[3], isDirectory: true).standardizedFileURL
            if try record(event, payload: payload, home: home) {
                let guidance = "For multi-step tasks, use Pacer's pacer_progress report_progress tool to report a whole-number estimate from 0 to 100 before work, at milestones, and before long waits. Skip simple replies and continue if the tool is unavailable."
                response["injectSteps"] = [["systemMessage": ["systemMessage": guidance]]]
            }
        } catch {
            // Always return a response that lets Antigravity keep working.
        }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
        return true
    }

    private static func identity(_ payload: [String: Any]) -> (AntigravityTask.Client, Foundation.UUID)? {
        guard let raw = payload["conversationId"] as? String, let id = UUID(uuidString: raw),
              let path = payload["transcriptPath"] as? String, path.utf16.count < 32760 else { return nil }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).suffix(6).map(String.init)
        guard parts.count == 6, let client = AntigravityTask.Client(rawValue: parts[0]),
              parts[1] == "brain", UUID(uuidString: parts[2]) == id,
              Array(parts.suffix(3)) == [".system_generated", "logs", "transcript.jsonl"] else { return nil }
        return (client, id)
    }

    private static func record(_ event: Event, payload: [String: Any], home: URL) throws -> Bool {
        guard let (client, conversation) = identity(payload) else { return false }
        let storage = WindowsLocalProfileStorage()
        let folder = home.appendingPathComponent(AntigravityTask.folder, isDirectory: true)
        let marker = folder.appendingPathComponent(AntigravityTask.enabledFile)
        try storage.validate(folder)
        guard storage.isDirectory(folder), storage.exists(marker), try storage.read(marker) == markerData else { return false }
        let flag = LocalHarnessProgressSetup.flag(home)
        let progress = storage.exists(flag) && (try? storage.read(flag)) == markerData
        let now = Date()
        let filename = AntigravityTask.filename(client, conversation)
        let entry = folder.appendingPathComponent(filename)
        let mutexName = Array(("Local\\CodexPacer.Antigravity." + filename).utf16) + [0]
        guard let mutex = CreateMutexW(nil, false, mutexName) else { return false }
        defer { _ = CloseHandle(mutex) }
        let result = WaitForSingleObject(mutex, 350)
        guard result == WAIT_OBJECT_0 || result == DWORD(0x80) /* WAIT_ABANDONED_0 */ else { return false }
        defer { _ = ReleaseMutex(mutex) }
        let previous: AntigravityTask? = (try? storage.read(entry)).flatMap { data in
            data.count <= AntigravityTask.limit ? try? JSONDecoder().decode(AntigravityTask.self, from: data) : nil
        }.flatMap { $0.filename == filename ? $0 : nil }
        guard event == .before || previous?.phase == .running else { return false }
        var task = previous ?? AntigravityTask(client: client, conversation: conversation, now: now)
        var inject = false
        switch event {
        case .before:
            if task.phase != .running || now.timeIntervalSince(task.observed) >= AntigravityTask.activityTimeout {
                task = AntigravityTask(client: client, conversation: conversation, now: now)
                task.guided = previous?.guided == true
            }
            if let paths = payload["workspacePaths"] as? [String], let path = paths.first {
                task.project = label(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init))
            }
            task.model = label(payload["modelName"] as? String) ?? task.model
            if progress, !task.guided {
                task.guided = true
                inject = true
            }
        case .after:
            break
        case .tool:
            guard progress, let percent = percentage(payload) else { return false }
            task.percent = percent
        case .stop:
            if payload["fullyIdle"] as? Bool == true {
                task.phase = payload["terminationReason"] as? String == "model_stop" ? .completed : .interrupted
            }
        }
        task.observed = max(now, task.observed)
        try storage.replace(entry, with: JSONEncoder().encode(task), permissions: 0o600)
        if previous == nil { prune(folder, keeping: entry, now: now, storage: storage) }
        return inject
    }

    private static func label(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160))
    }

    private static func percentage(_ payload: [String: Any]) -> Int? {
        guard (payload["error"] as? String ?? "").isEmpty,
              let tool = payload["toolCall"] as? [String: Any], let name = tool["name"] as? String,
              let args = tool["args"] as? [String: Any] else { return nil }
        let input: [String: Any]?
        switch name {
        case progressTool: input = args
        case "call_mcp_tool":
            guard args["ServerName"] as? String == "pacer_progress", args["ToolName"] as? String == "report_progress" else { return nil }
            if let text = args["Arguments"] as? String { input = try? object(Data(text.utf8), limit: 1024) }
            else { input = args["Arguments"] as? [String: Any] }
        default: return nil
        }
        guard let input, let data = try? JSONSerialization.data(withJSONObject: input),
              let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
              (0...100).contains(estimate.percent) else { return nil }
        return estimate.percent
    }

    private struct Estimate: Decodable { let percent: Int }

    private static func prune(_ folder: URL, keeping: URL, now: Date, storage: any ClaudeHookStorage) {
        let fs = WindowsFileSystem()
        guard let entries = try? fs.entries(in: folder) else { return }
        let rows = entries.compactMap { url -> (URL, Date)? in
            guard AntigravityTask.ownsFilename(url.lastPathComponent), let info = fs.metadata(url), info.isRegularFile else { return nil }
            return (url, info.modified)
        }.sorted { $0.1 > $1.1 }
        for (index, row) in rows.enumerated() where row.0 != keeping &&
            (index >= 128 || now.timeIntervalSince(row.1) >= AntigravityTask.retention) {
            try? storage.remove(row.0)
        }
    }
}
