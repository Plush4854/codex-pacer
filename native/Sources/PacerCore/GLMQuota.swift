import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GLMQuotaError: Error, LocalizedError, Equatable {
    /// ZCode holds no coding plan on this computer.
    case notSignedIn
    /// The service reports no usage windows for this account.
    case noPlan
    /// ZCode sealed its plan keys with a key the OS credential store does not give up.
    case keyringUnavailable
    case denied, invalidReply, timedOut, connectionFailed

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return L10n.text("glm.quota.not_signed_in")
        case .noPlan: return L10n.text("glm.quota.no_plan")
        case .keyringUnavailable: return L10n.text("glm.quota.keyring_unavailable")
        case .denied: return L10n.text("glm.quota.denied")
        case .invalidReply: return L10n.text("glm.quota.invalid_reply")
        case .timedOut: return L10n.text("glm.quota.timed_out")
        case .connectionFailed: return L10n.text("glm.quota.connection_failed")
        }
    }
}

/// A coding plan ZCode is signed in to. The key stays in memory for one request.
public struct GLMCredential: Equatable, Sendable {
    public enum Family: String, CaseIterable, Sendable { case zai, bigmodel }
    /// The record ZCode keeps the key under, to go straight to it next time.
    public let entry: String
    public let family: Family
    public let key: String
    /// A digest of the account's identifier; the identifier itself is not kept.
    public let accountScope: String
}

public enum GLMQuotaDecoder {
    /// `GET /api/monitor/usage/quota/limit`, the request ZCode's own usage page
    /// makes: `{code, data: {level, limits: [{type, unit, number, percentage,
    /// nextResetTime}]}}`. A plan's token quotas are its five-hour and weekly
    /// windows. Earlier plans reported both as limits of 5 and of 168 hours.
    public static func snapshot(_ data: Data, accountScope: String, at date: Date = Date()) throws -> QuotaSnapshot {
        guard data.count <= 64 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool != false else { throw GLMQuotaError.invalidReply }
        guard [0, 200].contains(number(object["code"]) ?? -1) else { throw GLMQuotaError.noPlan }
        guard let payload = object["data"] as? [String: Any], let limits = payload["limits"] as? [[String: Any]],
              limits.count <= 32 else { throw GLMQuotaError.invalidReply }
        func limit(_ type: String, unit: Int? = nil, hours: Int? = nil) -> [String: Any]? {
            limits.first { value in
                guard (value["type"] as? String) == type else { return false }
                if let unit, number(value["unit"]) != unit { return false }
                if let hours, number(value["number"]) != hours { return false }
                return true
            }
        }
        let windows = [(limit("TOKENS_LIMIT", unit: 3) ?? limit("TIME_LIMIT", hours: 5), "glm/primary", 300),
                       (limit("TOKENS_LIMIT", unit: 6) ?? limit("TIME_LIMIT", hours: 168), "glm/secondary", 10080)]
            .compactMap { value, id, minutes -> QuotaWindow? in
                guard let value, let used = amount(value["percentage"]) else { return nil }
                return QuotaWindow(id: id, usedPercent: min(100, used), durationMinutes: minutes, resetsAt: moment(value["nextResetTime"]))
            }
        guard !windows.isEmpty else { throw GLMQuotaError.noPlan }
        let level = (payload["level"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(32)) }
        return QuotaSnapshot(buckets: [QuotaBucket(id: "glm", name: nil, plan: level, windows: windows, credits: nil)],
            capturedAt: date, accountScope: accountScope, resetCredits: nil)
    }

    /// A whole number, or one written as text.
    static func number(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return amount(value).flatMap { $0 == $0.rounded() ? Int($0) : nil }
    }
    /// A finite, non-negative amount of at most four digits.
    static func amount(_ value: Any?) -> Double? {
        let raw: Double?
        if let value = value as? NSNumber { raw = value.doubleValue }
        else { raw = (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        return raw.flatMap { $0.isFinite && $0 >= 0 && $0 < 10_000 ? $0 : nil }
    }
    /// A reset time in milliseconds; one outside 2001 to 2100 is damage.
    static func moment(_ value: Any?) -> Date? {
        let raw: Double?
        if let value = value as? NSNumber { raw = value.doubleValue }
        else { raw = (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        return raw.flatMap { $0.isFinite && $0 > 1e12 && $0 < 4.1024448e13 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
    }
}

public enum GLMUsageClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static func endpoint(_ family: GLMCredential.Family) -> URL {
        URL(string: family == .zai ? "https://api.z.ai/api/monitor/usage/quota/limit"
            : "https://bigmodel.cn/api/monitor/usage/quota/limit")!
    }

    /// One request, as ZCode's own usage page makes it: the plan's key in the
    /// Authorization field and nothing else. The reply is reduced to two windows.
    public static func read(_ credential: GLMCredential, transport: Transport, now: @Sendable () -> Date = { Date() }) async throws -> QuotaSnapshot {
        var request = URLRequest(url: endpoint(credential.family), cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: ProviderQuotaRefreshPolicy.replyTimeout)
        request.setValue(credential.key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(request) }
        catch { throw (error as? URLError)?.code == .timedOut ? GLMQuotaError.timedOut : GLMQuotaError.connectionFailed }
        try Task.checkCancellation()
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try GLMQuotaDecoder.snapshot(data, accountScope: credential.accountScope, at: now())
        case 401, 403: throw GLMQuotaError.denied
        default: throw GLMQuotaError.connectionFailed
        }
    }
}

/// ZCode seals each plan's API key in its data folder under a random key that
/// it keeps in the OS credential store. Only the plan records are ever opened.
public enum GLMCredentialStore {
    public static let recordsFile = "v2/credentials.json"
    private static let prefix = "enc:v2:", osSource = "os"
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Whether ZCode keeps a coding plan's key in these records.
    public static func hasPlanRecords(_ data: Data) -> Bool { !planRecords(data).isEmpty }

    /// The plan keys in ZCode's records, personal plans first. Empty when ZCode
    /// keeps none, or sealed them with a key this is not.
    public static func credentials(in data: Data, sealingKey: Data) -> [GLMCredential] {
        guard sealingKey.count == 32 else { return [] }
        return planRecords(data).compactMap { record in
            guard let key = unseal(record.sealed, key: sealingKey), let plan = plan(record.entry) else { return nil }
            return GLMCredential(entry: record.entry, family: plan.family, key: key,
                accountScope: CompletionDismissalStore.digest(["glm-account", plan.account]))
        }
    }

    private static func planRecords(_ data: Data) -> [(entry: String, sealed: String)] {
        guard data.count <= 1024 * 1024, let records = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return records.compactMap { entry, value -> (String, String)? in
            guard let sealed = value as? String, sealed.hasPrefix(prefix), plan(entry) != nil else { return nil }
            return (entry, sealed)
        }.sorted { lhs, rhs in
            let left = plan(lhs.0)!, right = plan(rhs.0)!
            return left.personal != right.personal ? left.personal : lhs.0 < rhs.0
        }
    }
    /// `account-provider:coding-plan:account:<zai|bigmodel>-<individual|team>-coding-plan:account:<uuid>:api-key`
    private static func plan(_ entry: String) -> (family: GLMCredential.Family, personal: Bool, account: String)? {
        let parts = entry.split(separator: ":").map(String.init)
        guard parts.count == 7, parts[0] == "account-provider", parts[1] == "coding-plan", parts[2] == "account",
              parts[4] == "account", parts[6] == "api-key", parts[3].hasSuffix("-coding-plan"),
              UUID(uuidString: parts[5]) != nil,
              let family = GLMCredential.Family.allCases.first(where: { parts[3].hasPrefix($0.rawValue + "-") }) else { return nil }
        return (family, parts[3].hasPrefix(family.rawValue + "-individual-"), parts[5].lowercased())
    }

    /// `enc:v2:os:<key fingerprint>:<nonce>.<tag>.<ciphertext>`, each block in base64url.
    static func unseal(_ sealed: String, key: Data) -> String? {
        guard sealed.hasPrefix(prefix), key.count == 32 else { return nil }
        let parts = sealed.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == osSource, parts[1] == String(hex(Data(SHA256.hash(data: key))).prefix(24)) else { return nil }
        let blocks = parts[2].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard blocks.count == 3, let nonce = fromBase64url(blocks[0]), let tag = fromBase64url(blocks[1]),
              let ciphertext = fromBase64url(blocks[2]), nonce.count == 12, tag.count == 16,
              (1...4096).contains(ciphertext.count),
              let opened = try? AES.GCM.open(.init(nonce: .init(data: nonce), ciphertext: ciphertext, tag: tag), using: SymmetricKey(data: key)),
              let text = String(data: opened, encoding: .utf8), validKey(text) else { return nil }
        return text
    }
    /// The same record ZCode would write, for tests.
    static func seal(_ text: String, key: Data, fingerprint: String? = nil) -> String? {
        guard key.count == 32, validKey(text),
              let box = try? AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key)) else { return nil }
        return prefix + osSource + ":" + (fingerprint ?? String(hex(Data(SHA256.hash(data: key))).prefix(24))) + ":"
            + [box.nonce.withUnsafeBytes { Data($0) }, box.tag, box.ciphertext].map(base64url).joined(separator: ".")
    }
    private static func validKey(_ text: String) -> Bool {
        (8...256).contains(text.utf8.count) && text.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
    public static func fromBase64url(_ text: String) -> Data? {
        Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4), options: [])
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func hex(_ bytes: Data) -> String {
        var text = [UInt8](); text.reserveCapacity(bytes.count * 2)
        for byte in bytes { text.append(hexDigits[Int(byte >> 4)]); text.append(hexDigits[Int(byte & 0x0f)]) }
        return String(decoding: text, as: UTF8.self)
    }
}

public struct GLMQuotaServices: Sendable {
    /// The coding plans ZCode holds in its data folder, personal plans first.
    public let credentials: @Sendable (URL) async throws -> [GLMCredential]
    public let read: @Sendable (GLMCredential) async throws -> QuotaSnapshot
    public init(credentials: @escaping @Sendable (URL) async throws -> [GLMCredential],
                read: @escaping @Sendable (GLMCredential) async throws -> QuotaSnapshot) {
        self.credentials = credentials; self.read = read
    }
}

public struct GLMQuotaState: Equatable, Sendable {
    public let context: UInt64
    public let enabled: Bool, refreshing: Bool
    public let snapshot: QuotaSnapshot?
    public let error: String?
    public let failure: GLMQuotaError?
    public let lastAttempt: Date?
    public let failureCount: Int
    public init(context: UInt64, enabled: Bool, refreshing: Bool, snapshot: QuotaSnapshot?, error: String?, failure: GLMQuotaError?,
                lastAttempt: Date?, failureCount: Int) {
        self.context = context; self.enabled = enabled; self.refreshing = refreshing; self.snapshot = snapshot
        self.error = error; self.failure = failure; self.lastAttempt = lastAttempt; self.failureCount = failureCount
    }
}

/// Reads GLM usage on Pacer's quota cadence while the GLM module is on. A plan
/// that reports no windows gives way to the next one ZCode holds; the plan that
/// answered is asked first from then on.
public actor GLMQuotaCoordinator {
    private let services: GLMQuotaServices
    private let now: @Sendable () -> Date
    private let output: @Sendable (GLMQuotaState) async -> Void
    private var home: URL?, enabled = false, context: UInt64 = 0
    private var revision: UInt64 = 0
    private var work: Task<Void, Never>?, workID: UUID?
    private var lastAttempt: Date?, failures = 0
    private var snapshot: QuotaSnapshot?, error: String?, failure: GLMQuotaError?
    private var answered: String?

    public init(services: GLMQuotaServices, seed: GLMQuotaState? = nil, now: @escaping @Sendable () -> Date = { Date() },
                output: @escaping @Sendable (GLMQuotaState) async -> Void) {
        self.services = services; self.now = now; self.output = output
        lastAttempt = seed?.lastAttempt; failures = seed?.failureCount ?? 0
    }
    public func configure(home: URL, enabled: Bool, context: UInt64) async {
        self.context = context
        guard self.home != home || self.enabled != enabled else { await emit(); return }
        self.home = home; self.enabled = enabled
        revision &+= 1
        work?.cancel(); work = nil; workID = nil
        snapshot = nil; error = nil; failure = nil; answered = nil
        lastAttempt = nil; failures = 0
        await emit()
    }
    @discardableResult
    public func refreshIfDue(expanded: Bool, force: Bool = false) async -> Bool {
        guard enabled, let home, work == nil,
              ProviderQuotaRefreshPolicy.isDue(lastAttempt: lastAttempt, expanded: expanded, failures: failures, now: now(), force: force, expansion: false) else { return false }
        lastAttempt = now()
        let id = UUID(), revision = revision
        workID = id
        work = Task { [weak self] in await self?.read(home: home, revision: revision, id: id) }
        return true
    }
    public func currentState() -> GLMQuotaState {
        .init(context: context, enabled: enabled, refreshing: work != nil, snapshot: snapshot, error: error, failure: failure,
            lastAttempt: lastAttempt, failureCount: failures)
    }
    /// Ends when a read in flight has ended.
    public func waitForRefresh() async { await work?.value }
    private func emit() async { await output(currentState()) }
    private func current(_ revision: UInt64, _ id: UUID) -> Bool { enabled && self.revision == revision && workID == id && !Task.isCancelled }
    private func read(home: URL, revision: UInt64, id: UUID) async {
        await emit(); guard current(revision, id) else { return }
        do {
            let credentials = try await services.credentials(home)
            guard current(revision, id) else { return }
            guard !credentials.isEmpty else { throw GLMQuotaError.notSignedIn }
            // The plan that answered last time goes first; the rest keep their order.
            let ordered = credentials.enumerated().sorted { lhs, rhs in
                (lhs.element.entry == answered ? 0 : 1, lhs.offset) < (rhs.element.entry == answered ? 0 : 1, rhs.offset)
            }.map(\.element)
            var reading: QuotaSnapshot?, last = GLMQuotaError.noPlan
            for credential in ordered {
                do { reading = try await services.read(credential); answered = credential.entry; break }
                catch {
                    try Task.checkCancellation()
                    last = (error as? GLMQuotaError) ?? .connectionFailed
                    // A plan without windows, or one that refuses its key, gives way to the next.
                    guard [GLMQuotaError.noPlan, .denied].contains(last) else { break }
                }
            }
            guard current(revision, id) else { return }
            if let reading {
                if snapshot?.accountScope != reading.accountScope { snapshot = nil }
                snapshot = reading; failures = 0; failure = nil; error = nil
            } else { throw last }
        } catch {
            guard current(revision, id) else { return }
            failure = (error as? GLMQuotaError) ?? .connectionFailed
            self.error = failure?.localizedDescription
            // A missing plan or key ends the reading. A missed reply keeps the last one, which goes stale on its own.
            if [GLMQuotaError.notSignedIn, .noPlan, .keyringUnavailable, .denied].contains(failure) { snapshot = nil }
            failures = min(4, failures + 1)
        }
        guard current(revision, id) else { return }
        work = nil; workID = nil; await emit()
    }
    public func stop() async {
        work?.cancel(); enabled = false; revision &+= 1
        let pending = work; work = nil; workID = nil
        await pending?.value
    }
}
