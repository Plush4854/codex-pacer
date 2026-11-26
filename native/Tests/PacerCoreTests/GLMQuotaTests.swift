import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PacerCore

final class GLMQuotaTests: XCTestCase {
    private let personal = "account-provider:coding-plan:account:zai-individual-coding-plan:account:11111111-2222-4333-8444-555555555555:api-key"
    private let team = "account-provider:coding-plan:account:zai-team-coding-plan:account:11111111-2222-4333-8444-555555555555:api-key"
    private let bigmodel = "account-provider:coding-plan:account:bigmodel-individual-coding-plan:account:11111111-2222-4333-8444-555555555555:api-key"
    private let fiveHourReset = 1_795_470_007_595.0, weeklyReset = 1_795_680_090_984.0
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func reset(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
    /// The reply ZCode's usage page reads, with synthetic numbers.
    private var reply: [String: Any] {
        ["code": 200, "msg": "Operation successful", "data": ["level": "pro", "limits": [
            ["nextResetTime": fiveHourReset, "number": 5, "percentage": 12, "type": "TOKENS_LIMIT", "unit": 3],
            ["nextResetTime": weeklyReset, "number": 1, "percentage": 48, "type": "TOKENS_LIMIT", "unit": 6],
            ["currentValue": 29, "nextResetTime": 1_795_760_292_998.0, "number": 1, "percentage": 2, "remaining": 971, "type": "TIME_LIMIT", "unit": 5, "usage": 1000,
             "usageDetails": [["model": "synthetic", "count": 3]]]
        ]]]
    }
    private func reading(_ used: Double, scope: String, at date: Date) -> QuotaSnapshot {
        QuotaSnapshot(buckets: [QuotaBucket(id: "glm", name: nil, plan: nil, windows: [QuotaWindow(id: "glm/primary", usedPercent: used, durationMinutes: 300, resetsAt: nil)],
            credits: nil)], capturedAt: date, accountScope: scope, resetCredits: nil)
    }
    private func failure(_ error: any Error) -> GLMQuotaError? { error as? GLMQuotaError }
    /// What the services answer, read under a lock because the coordinator calls them off the test thread.
    private final class Plans: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [GLMCredential] = []
        private var now = Date(timeIntervalSince1970: 1_795_000_000)
        private var outcome: (String, Date) throws -> QuotaSnapshot = { _, _ in throw GLMQuotaError.noPlan }
        var date: Date { get { lock.lock(); defer { lock.unlock() }; return now } }
        func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
        var reads: [String] { lock.lock(); defer { lock.unlock() }; return read }
        private var read: [String] = []
        var heldCredentials: [GLMCredential] { lock.lock(); defer { lock.unlock() }; return held }
        func set(held: [GLMCredential]? = nil, outcome: ((String, Date) throws -> QuotaSnapshot)? = nil) {
            lock.lock(); if let held { self.held = held }; if let outcome { self.outcome = outcome }; lock.unlock()
        }
        /// Answers outside the lock, so an answer may read the clock.
        func use(_ entry: String) throws -> QuotaSnapshot {
            lock.lock()
            let date = now, answer = outcome
            read.append(entry)
            lock.unlock()
            return try answer(entry, date)
        }
    }
    private func label(_ state: GLMQuotaState) -> String {
        "\(state.enabled ? "on" : "off")-\(state.refreshing ? "refreshing" : "idle")-\(state.snapshot == nil ? "none" : "reading")-\(state.failure.map { "\($0)" } ?? "ok")"
    }
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testTheFiveHourAndWeeklyTokenQuotasBecomeTheTwoWindows() throws {
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let snapshot = try GLMQuotaDecoder.snapshot(json(reply), accountScope: "scope-a", at: at)
        XCTAssertEqual(snapshot.capturedAt, at); XCTAssertEqual(snapshot.accountScope, "scope-a")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["glm"])
        let bucket = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(bucket.plan, "pro")
        XCTAssertEqual(bucket.windows.map(\.id), ["glm/primary", "glm/secondary"])
        XCTAssertEqual(bucket.windows.map(\.durationMinutes), [300, 10080])
        XCTAssertEqual(bucket.windows.map(\.usedPercent), [12, 48])
        XCTAssertEqual(bucket.windows.map(\.resetsAt), [reset(fiveHourReset), reset(weeklyReset)])
        XCTAssertEqual(snapshot.limitingWindow?.id, "glm/secondary", "The weekly window has less left")
    }

    /// A plan that reported its windows as limits of 5 and of 168 hours reads the same.
    func testEarlierHourLimitsReadTheSameWay() throws {
        let earlier: [String: Any] = ["code": 0, "data": ["limits": [
            ["type": "TOKENS_LIMIT", "unit": "TOKENS", "number": 5, "percentage": "0.00"],
            ["type": "TIME_LIMIT", "unit": "HOURS", "number": 5, "usage": 60, "currentValue": 60, "remaining": 40, "percentage": "60.5", "nextResetTime": "1795470007595"],
            ["type": "TIME_LIMIT", "unit": "HOURS", "number": 168, "percentage": 7.25, "nextResetTime": weeklyReset]
        ]]]
        let snapshot = try GLMQuotaDecoder.snapshot(json(earlier), accountScope: "scope-b")
        XCTAssertNil(snapshot.buckets.first?.plan)
        XCTAssertEqual(snapshot.buckets.first?.windows.map(\.usedPercent), [60.5, 7.25])
        XCTAssertEqual(snapshot.buckets.first?.windows.map(\.resetsAt), [reset(fiveHourReset), reset(weeklyReset)])
    }

    func testAPlanWithoutWindowsAndADamagedReplyAreToldApart() throws {
        var reply = reply
        XCTAssertNoThrow(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s"))
        reply["code"] = 401
        XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")) { XCTAssertEqual(failure($0), .noPlan) }
        reply["code"] = 200; reply["success"] = false
        XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")) { XCTAssertEqual(failure($0), .invalidReply) }
        reply["success"] = true
        // The monthly tool allowance alone is not a usage window.
        reply["data"] = ["limits": [["type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 2, "nextResetTime": weeklyReset]]]
        XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")) { XCTAssertEqual(failure($0), .noPlan) }
        reply["data"] = ["limits": []]
        XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")) { XCTAssertEqual(failure($0), .noPlan) }
        for damaged in [Data("{".utf8), Data(repeating: 0x20, count: 64 * 1024 + 1), json(["code": 200, "data": ["limits": "none"]])] {
            XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(damaged, accountScope: "s")) { XCTAssertEqual(failure($0), .invalidReply) }
        }
        // More than used up draws as used up, a reset outside 2001 to 2100 is left out, and a share that is not a number drops its window.
        reply["data"] = ["limits": [["type": "TOKENS_LIMIT", "unit": 3, "percentage": 140, "nextResetTime": weeklyReset],
                                     ["type": "TOKENS_LIMIT", "unit": 6, "percentage": 70, "nextResetTime": 5]]]
        let snapshot = try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")
        XCTAssertEqual(snapshot.buckets.first?.windows.map(\.usedPercent), [100, 70])
        XCTAssertEqual(snapshot.buckets.first?.windows.map(\.resetsAt), [reset(weeklyReset), nil])
        reply["data"] = ["limits": [["type": "TOKENS_LIMIT", "unit": 3, "percentage": -1], ["type": "TOKENS_LIMIT", "unit": 6, "percentage": "many"]]]
        XCTAssertThrowsError(try GLMQuotaDecoder.snapshot(json(reply), accountScope: "s")) { XCTAssertEqual(failure($0), .noPlan) }
    }

    /// Sealed by Node's own AES-GCM with the key `00 01 … 1f`, so the record
    /// Pacer opens is the one ZCode writes and not only the one Pacer seals.
    func testUnsealOpensARecordSealedByAnotherImplementation() {
        let key = Data((0..<32).map { UInt8($0) })
        let sealed = "enc:v2:os:630dcd2966c4336691125448:oKGio6Slpqeoqaqr.LTSKhC2zQxZiEVJruJ9ftA.lWESWS2udtYBSPe_ZhTttRXVdCCjhXFYqTgRvkY"
        XCTAssertEqual(GLMCredentialStore.unseal(sealed, key: key), "synthetic-plan-key-0123456789")
        XCTAssertNil(GLMCredentialStore.unseal(sealed, key: Data(repeating: 1, count: 32)), "Another key's fingerprint ends the read before any cipher runs")
        XCTAssertNil(GLMCredentialStore.unseal(sealed.replacingOccurrences(of: ":os:", with: ":env:"), key: key), "A key ZCode keeps in a managed secret is not read")
        XCTAssertNil(GLMCredentialStore.unseal("enc:v2:os:000102030405060708090a0b:AAAA.BBBB.CCCC", key: key))
        XCTAssertNil(GLMCredentialStore.unseal("enc:v1:legacy", key: key))
        XCTAssertEqual(GLMCredentialStore.unseal(GLMCredentialStore.seal("synthetic-plan-key-0123456789", key: key)!, key: key), "synthetic-plan-key-0123456789")
        XCTAssertNil(GLMCredentialStore.seal("has a space", key: key))
    }

    func testRecordsYieldPersonalPlanKeysFirstAndNothingWithoutTheKey() throws {
        let key = Data((0..<32).map { UInt8($0) }), other = Data(repeating: 0x5a, count: 32)
        let uuid = "11111111-2222-4333-8444-555555555555"
        let records: [String: Any] = [
            "oauth:zai:access_token": GLMCredentialStore.seal("synthetic-oauth-token-value", key: key)!,
            "zcodejwttoken": GLMCredentialStore.seal("synthetic-jwt-token-value", key: key)!,
            team: GLMCredentialStore.seal("synthetic-team-key-000001", key: key)!,
            personal: GLMCredentialStore.seal("synthetic-personal-key-0001", key: key)!,
            bigmodel: GLMCredentialStore.seal("synthetic-bigmodel-key-001", key: other)!,
            "account-provider:coding-plan:account:zai-start-plan:account:\(uuid):api-key": GLMCredentialStore.seal("synthetic-start-key", key: key)!,
            "account-provider:coding-plan:account:zai-individual-coding-plan:account:not-a-uuid:api-key": GLMCredentialStore.seal("synthetic-key", key: key)!
        ]
        let data = json(records)
        XCTAssertTrue(GLMCredentialStore.hasPlanRecords(data))
        XCTAssertFalse(GLMCredentialStore.hasPlanRecords(json(["oauth:zai:access_token": "enc:v2:os:a:b.c.d"])))
        let credentials = GLMCredentialStore.credentials(in: data, sealingKey: key)
        XCTAssertEqual(credentials.map(\.entry), [personal, team], "Personal plans first, then in record order")
        XCTAssertEqual(credentials.map(\.family), [.zai, .zai])
        XCTAssertEqual(credentials.map(\.key), ["synthetic-personal-key-0001", "synthetic-team-key-000001"])
        XCTAssertEqual(credentials.map(\.accountScope), [CompletionDismissalStore.digest(["glm-account", uuid]), CompletionDismissalStore.digest(["glm-account", uuid])])
        XCTAssertFalse(credentials.contains { $0.key.contains("oauth") || $0.key.contains("jwt") }, "Sign-in tokens are never opened")
        let otherSide = GLMCredentialStore.credentials(in: data, sealingKey: other)
        XCTAssertEqual(otherSide.map(\.entry), [bigmodel], "Each record opens with its own key only")
        XCTAssertEqual(otherSide.map(\.family), [.bigmodel])
        XCTAssertTrue(GLMCredentialStore.credentials(in: data, sealingKey: Data(repeating: 7, count: 16)).isEmpty)
        XCTAssertTrue(GLMCredentialStore.credentials(in: Data(repeating: 0, count: 1024 * 1024 + 1), sealingKey: key).isEmpty)
    }

    func testCoordinatorReadsOnCadenceAndMovesOnToTheNextPlan() async {
        let plans = Plans(), states = Log()
        let home = URL(fileURLWithPath: "/synthetic/.zcode", isDirectory: true)
        let personal = GLMCredential(entry: personal, family: .zai, key: "synthetic-personal-key-0001", accountScope: "personal")
        let team = GLMCredential(entry: team, family: .zai, key: "synthetic-team-key-000001", accountScope: "team")
        plans.set(held: [personal, team], outcome: { entry, date in
            guard entry == team.entry else { throw GLMQuotaError.noPlan }
            return self.reading(40, scope: "team", at: date)
        })
        let services = GLMQuotaServices(credentials: { _ in plans.heldCredentials }, read: { try plans.use($0.entry) })
        let coordinator = GLMQuotaCoordinator(services: services, now: { plans.date }, output: { states.append(self.label($0)) })
        await coordinator.configure(home: home, enabled: true, context: 1)
        var started = await coordinator.refreshIfDue(expanded: false)
        XCTAssertTrue(started); await coordinator.waitForRefresh()
        var state = await coordinator.currentState()
        XCTAssertEqual(state.snapshot?.buckets.first?.windows.first?.usedPercent, 40, "A plan without windows gives way to the next one")
        XCTAssertEqual(state.snapshot?.accountScope, "team"); XCTAssertNil(state.error)
        XCTAssertEqual(plans.reads, [personal.entry, team.entry])
        XCTAssertEqual(Array(states.all.prefix(3)), ["on-idle-none-ok", "on-refreshing-none-ok", "on-idle-reading-ok"])
        // The plan that answered goes first from then on, and two minutes pass between readings while the island is collapsed.
        plans.set(outcome: { entry, date in self.reading(entry == personal.entry ? 10 : 40, scope: entry == personal.entry ? "personal" : "team", at: date) })
        plans.advance(10)
        started = await coordinator.refreshIfDue(expanded: false)
        XCTAssertFalse(started, "Not due yet")
        plans.advance(120)
        started = await coordinator.refreshIfDue(expanded: false)
        XCTAssertTrue(started); await coordinator.waitForRefresh()
        XCTAssertEqual(plans.reads, [personal.entry, team.entry, team.entry])
        // A missed reply keeps the last reading beside its error.
        plans.set(outcome: { _, _ in throw GLMQuotaError.timedOut })
        plans.advance(600)
        started = await coordinator.refreshIfDue(expanded: false)
        XCTAssertTrue(started); await coordinator.waitForRefresh()
        state = await coordinator.currentState()
        XCTAssertEqual(state.snapshot?.buckets.first?.windows.first?.usedPercent, 40)
        XCTAssertEqual(state.failure, .timedOut); XCTAssertEqual(state.failureCount, 1)
        XCTAssertEqual(states.all.last, "on-idle-reading-timedOut")
        // No plan at all ends the reading.
        plans.set(held: [])
        plans.advance(600)
        started = await coordinator.refreshIfDue(expanded: false)
        XCTAssertTrue(started); await coordinator.waitForRefresh()
        state = await coordinator.currentState()
        XCTAssertNil(state.snapshot); XCTAssertEqual(state.failure, .notSignedIn)
        // A Retry does not wait, and turning the module off clears everything.
        plans.set(held: [personal], outcome: { _, date in self.reading(55, scope: "personal", at: date) })
        started = await coordinator.refreshIfDue(expanded: false, force: true)
        XCTAssertTrue(started); await coordinator.waitForRefresh()
        state = await coordinator.currentState()
        XCTAssertEqual(state.snapshot?.buckets.first?.windows.first?.usedPercent, 55); XCTAssertEqual(state.failureCount, 0)
        await coordinator.configure(home: home, enabled: false, context: 2)
        state = await coordinator.currentState()
        XCTAssertFalse(state.enabled); XCTAssertNil(state.snapshot); XCTAssertEqual(state.context, 2)
        started = await coordinator.refreshIfDue(expanded: false, force: true)
        XCTAssertFalse(started)
        XCTAssertEqual(states.all.last, "off-idle-none-ok")
        // A read cancelled by a new configuration is dropped, not shown.
        plans.set(held: [personal])
        await coordinator.configure(home: home, enabled: true, context: 3)
        let late = await coordinator.currentState()
        XCTAssertEqual(late.context, 3); XCTAssertTrue(late.enabled)
        await coordinator.stop()
        let stopped = await coordinator.currentState()
        XCTAssertFalse(stopped.enabled); XCTAssertFalse(stopped.refreshing)
    }

    func testClientSendsOnlyThePlanKeyAndMapsTheServiceAnswers() async throws {
        let credential = GLMCredential(entry: bigmodel, family: .bigmodel, key: "synthetic-personal-key-0001", accountScope: "personal")
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let requests = Log()
        func transport(_ status: Int, _ body: Data = json(reply)) -> GLMUsageClient.Transport {
            { request in
                requests.append("\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)! as URLResponse)
            }
        }
        XCTAssertEqual(GLMUsageClient.endpoint(.bigmodel).absoluteString, "https://bigmodel.cn/api/monitor/usage/quota/limit")
        XCTAssertEqual(GLMUsageClient.endpoint(.zai).absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
        let snapshot = try await GLMUsageClient.read(credential, transport: transport(200), now: { at })
        XCTAssertEqual(snapshot.buckets.first?.windows.map(\.usedPercent), [12, 48]); XCTAssertEqual(snapshot.capturedAt, at)
        XCTAssertEqual(requests.all, ["GET https://bigmodel.cn/api/monitor/usage/quota/limit"])
        for (status, expected) in [(401, GLMQuotaError.denied), (403, .denied), (500, .connectionFailed), (302, .connectionFailed)] {
            do { _ = try await GLMUsageClient.read(credential, transport: transport(status)); XCTFail("HTTP \(status) must not read as usage") }
            catch { XCTAssertEqual(failure(error), expected) }
        }
        for (code, expected) in [(URLError.timedOut, GLMQuotaError.timedOut), (.notConnectedToInternet, .connectionFailed)] {
            do { _ = try await GLMUsageClient.read(credential, transport: { _ in throw URLError(code) }); XCTFail("\(code) must not read as usage") }
            catch { XCTAssertEqual(failure(error), expected) }
        }
    }
}
