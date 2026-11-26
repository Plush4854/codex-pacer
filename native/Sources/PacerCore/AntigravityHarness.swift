import Foundation

enum AntigravityHarness {
    static let definition = LocalHarnessDefinition(
        descriptor: .init(id: .antigravity, name: "Antigravity", symbol: "sparkle",
                          brand: .init(dark: .init(0x8AB4F8), light: .init(0x315DA8), accentLift: 0.7, accentLuminance: 0.24),
                          website: URL(string: "https://antigravity.google/"), hasTaskProgress: true),
        platforms: [.windows], home: ".gemini/config", dataFile: "config.json",
        windowsExecutables: ["Programs/antigravity/Antigravity.exe", "Programs/Antigravity IDE/Antigravity IDE.exe"],
        progressConfigFile: "mcp_config.json",
        makeMonitor: { AntigravityMonitor(io: $0) })
}

/// A bounded snapshot of one conversation. The App and IDE can share the
/// same conversation UUID after a migration.
package struct AntigravityTask: Codable, Sendable {
    package enum Client: String, Codable, Sendable {
        case app = "antigravity"
        case ide = "antigravity-ide"
    }

    package static let folder = "pacer-antigravity"
    package static let enabledFile = "enabled"
    package static let limit = 4096
    package static let retention: TimeInterval = 24 * 60 * 60
    package static let activityTimeout: TimeInterval = 3 * 60 * 60

    package let client: Client
    package let conversation: UUID
    package var turn = UUID()
    package var phase = ActivityPhase.running
    package var started: Date
    package var observed: Date
    package var model: String?
    package var project: String?
    package var percent: Int?
    package var guided = false

    package init(client: Client, conversation: UUID, now: Date) {
        self.client = client
        self.conversation = conversation
        self.started = now
        self.observed = now
    }

    package var filename: String { Self.filename(client, conversation) }
    package static func filename(_ client: Client, _ conversation: UUID) -> String {
        client.rawValue + "-" + conversation.uuidString.lowercased() + ".json"
    }

    package static func ownsFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5).suffix(36))) else { return false }
        return name == filename(.app, id) || name == filename(.ide, id)
    }

    func activity(at now: Date, baseline: Date, showsProgress: Bool) -> SessionActivity? {
        let age = now.timeIntervalSince(observed)
        guard age < Self.retention, started <= observed, age >= -60 else { return nil }
        let session = client.rawValue + "-" + conversation.uuidString.lowercased()
        let state: SessionActivity.ObservedTurnState
        switch phase {
        case .running:
            state = age >= Self.activityTimeout ? .interrupted(failed: false) : .working(.working)
        case .completed: state = .finished
        case .interrupted: state = .interrupted(failed: true)
        default: return nil
        }
        let label = L10n.text(client == .app ? "antigravity.app" : "antigravity.ide")
        var activity = SessionActivity(id: AgentProvider.antigravity.activityID(sessionID: session),
                                       project: project ?? label, provider: .antigravity, sessionID: session)
        let id = turn.uuidString.lowercased()
        activity.applyObservedTurn(state, id: id, started: started, at: observed, live: observed >= baseline, model: model)
        if showsProgress, activity.phase == .running, let percent { activity.reportProgress(percent, at: observed, turnID: id) }
        return activity
    }
}

private actor AntigravityMonitor: LocalHarnessMonitor {
    private let io: LocalHarnessIO
    private var home: URL?
    private var watcher: ActivityLogWatcher?
    private var refreshTask: Task<Void, Never>?
    private var policy: ActivityRefreshPolicy = .collapsed
    private var publish: (@Sendable (HarnessActivity) async -> Void)?
    private var baseline = Date.distantPast

    init(io: LocalHarnessIO) { self.io = io }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        stop()
        self.home = home
        self.policy = policy
        self.publish = publish
        baseline = io.now()
        watcher = ActivityLogWatcher(files: io.files, events: io.events, interval: policy.interval,
                                     maximumDirectoryWatches: 2, fileExtensions: nil) { [weak self] _ in
            Task { await self?.refresh() }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await self?.refresh() }
            }
        }
        await refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        watcher?.stop()
        watcher = nil
        home = nil
        publish = nil
    }

    func updatePolicy(_ policy: ActivityRefreshPolicy) {
        self.policy = policy
        updateWatch()
    }

    private func updateWatch() {
        guard let home else { return }
        watcher?.update([home, home.appendingPathComponent(AntigravityTask.folder, isDirectory: true)],
                        interval: policy.interval, flushPending: policy == .expanded)
    }

    func refresh() async {
        guard let home, let publish else { return }
        updateWatch()
        let directory = home.appendingPathComponent(AntigravityTask.folder, isDirectory: true)
        guard io.files.metadata(home)?.isDirectory == true else {
            await publish(.init(status: .missing))
            return
        }
        guard io.files.metadata(directory.appendingPathComponent(AntigravityTask.enabledFile))?.isRegularFile == true,
              let entries = try? io.files.entries(in: directory) else {
            await publish(.init(status: .unavailable))
            return
        }
        let now = io.now()
        let candidates = entries.compactMap { url -> (URL, Date)? in
            guard AntigravityTask.ownsFilename(url.lastPathComponent),
                  let entry = io.files.metadata(url), entry.isRegularFile, entry.size <= AntigravityTask.limit,
                  now.timeIntervalSince(entry.modified) < AntigravityTask.retention else { return nil }
            return (url, entry.modified)
        }.sorted { $0.1 > $1.1 }.prefix(128)
        let showsProgress = io.files.metadata(LocalHarnessProgressSetup.flag(home))?.isRegularFile == true
        let decoder = JSONDecoder()
        let activities = candidates.compactMap { url, _ -> SessionActivity? in
            guard let data = try? io.files.read(url, offset: 0, maximumBytes: AntigravityTask.limit + 1),
                  let task = try? decoder.decode(AntigravityTask.self, from: data),
                  task.filename == url.lastPathComponent else { return nil }
            return task.activity(at: now, baseline: baseline, showsProgress: showsProgress)
        }
        await publish(.init(activities: activities, status: .ready))
    }
}
