import Foundation

/// GLM's ZCode keeps Claude-compatible hook envelopes in its data folder once
/// Pacer's hooks are installed, so this module tails the same bounded spool
/// the Claude adapter writes — through the shared reader and turn state
/// machine, under its own provider identity. Without the spool the module is
/// silent: nothing else of ZCode's is read.
enum GLMHarness {
    static let glm = makeDefinition()

    static func makeDefinition() -> LocalHarnessDefinition {
        LocalHarnessDefinition(
            descriptor: .init(id: .glm, name: "GLM ZCode", symbol: "sparkles",
                              brand: .init(dark: .init(0x4CC9F0), light: .init(0x0E7490), accentLift: 0.55, accentLuminance: 0.16),
                              website: URL(string: "https://z.ai/"), hasTaskProgress: true),
            platforms: [.windows, .macOS], home: ".zcode", dataFile: "cli/db/db.sqlite",
            windowsExecutables: ["Programs/ZCode/ZCode.exe"],
            macApplicationNames: ["ZCode"],
            makeMonitor: { GLMHarnessMonitor(io: $0) })
    }
}

/// Tails `<home>/pacer/events.jsonl` through the shared bounded reader and
/// publishes the sessions and attention requests the shared state machine
/// derives. File events drive the common path; a bounded maintenance tick
/// ends sessions that stopped without a final row and settles baselines.
final class GLMHarnessMonitor: LocalHarnessMonitor, @unchecked Sendable {
    private let io: LocalHarnessIO
    private var generation: UInt64 = 0
    private var home: URL?
    private var policy: ActivityRefreshPolicy = .collapsed
    private var publish: (@Sendable (HarnessActivity) async -> Void)?
    private var watcher: ActivityLogWatcher?
    private var watchURLs: [URL] = []
    private var reader: ClaudeActivityReader
    private var state = ClaudeActivityState(provider: .glm, fallbackProject: "GLM ZCode")
    private var caughtUp = false
    private var releasePending = false
    private var failureCount = 0
    private var retry: Task<Void, Never>?

    init(io: LocalHarnessIO) {
        self.io = io
        reader = ClaudeActivityReader(files: io.files, clock: { io.now() })
    }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        reset()
        self.home = home; self.policy = policy; self.publish = publish
        let current = generation
        watcher = ActivityLogWatcher(files: io.files, events: io.events, interval: policy.interval,
            maximumDirectoryWatches: 4, fileExtensions: nil) { [weak self] _ in
            Task { await self?.refresh(ifCurrent: current) }
        }
        await refresh()
    }

    func updatePolicy(_ policy: ActivityRefreshPolicy) {
        self.policy = policy
        watcher?.update(watchURLs, interval: policy.interval, flushPending: policy == .expanded)
    }

    func refresh() async {
        guard generation > 0, home != nil else { return }
        await refreshBody()
    }

    func stop() async {
        let oldWatcher = reset()
        _ = await oldWatcher?.activeWatchCount()
    }

    private func reset() -> ActivityLogWatcher? {
        generation &+= 1; home = nil; publish = nil
        retry?.cancel(); retry = nil
        let oldWatcher = watcher
        oldWatcher?.stop(); watcher = nil; watchURLs = []
        reader.reset(); state = ClaudeActivityState(provider: .glm, fallbackProject: "GLM ZCode")
        caughtUp = false; releasePending = false; failureCount = 0
        return oldWatcher
    }

    private func refresh(ifCurrent current: UInt64) async {
        guard current == generation else { return }
        await refreshBody()
    }

    private func refreshBody() async {
        guard let home, let publish else { return }
        let now = io.now()
        var observation: HarnessActivity
        if io.files.metadata(home)?.isDirectory == true {
            let result = reader.read(home: home, discover: true, now: now)
            for bytes in result.records { state.consume(bytes, now: now) }
            if !result.records.isEmpty { releasePending = true }
            if result.caughtUp, releasePending {
                state.releaseCompletedRequests(now: now); releasePending = false
            }
            if result.caughtUp { state.finalizeHistoricalBaseline(now: now); caughtUp = true }
            state.expireUnconfirmedBaseline(now: now)
            if let status = ClaudeActivityRecord.encode(["kind": "status", "connected": result.available,
                                                         "watchingLogs": !result.watchURLs.isEmpty, "scans": reader.scans]) {
                state.consume(status, now: now)
            }
            // A home without the spool is an installed-but-idle module, or one
            // whose hooks are not set up yet; it reports itself, invents nothing.
            let spoolExists = io.files.metadata(home.appendingPathComponent("pacer/events.jsonl"))?.isRegularFile == true
            observation = HarnessActivity(activities: state.activities, requests: state.attention,
                status: result.available && spoolExists ? .ready : .unavailable)
            watchURLs = result.watchURLs
            watcher?.update(watchURLs, interval: 0.1)
            failureCount = result.available ? 0 : min(4, failureCount + 1)
        } else {
            state.sourceMissing()
            observation = HarnessActivity(activities: state.activities, requests: state.attention, status: .missing)
            watchURLs = [home.deletingLastPathComponent()]
            watcher?.update(watchURLs, interval: policy.interval)
            failureCount = min(4, failureCount + 1)
        }
        scheduleRetry(ready: observation.status == .ready)
        await publish(observation)
    }

    /// The maintenance tick: unconfirmed baselines expire, sessions that
    /// stopped without a final row end, and a missing home is retried gently.
    private func scheduleRetry(ready: Bool) {
        retry?.cancel()
        let backoff = min(300, 15 << failureCount)
        let seconds: TimeInterval = ready ? 60 : TimeInterval(backoff)
        let current = generation
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            await self.refresh()
        }
    }
}
