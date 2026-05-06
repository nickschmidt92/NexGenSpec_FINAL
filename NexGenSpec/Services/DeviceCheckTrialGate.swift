//
//  DeviceCheckTrialGate.swift
//  NexGenSpec
//
//  Second-line defense against trial abuse via reinstall.
//
//  The first-line gate is a UserDefaults counter
//  (`nexgenspec.trial.inspectionsCreated`) maintained by
//  `SubscriptionManager`. That counter survives Delete Account but NOT
//  Delete App + reinstall — abusers could otherwise wipe the bundle
//  container and get 3 fresh free inspections each install.
//
//  Apple's DeviceCheck framework gives every app a pair of per-device,
//  per-developer bits stored on Apple's servers. Those bits survive
//  reinstall, factory reset is the only way to clear them. We use one
//  bit to record "this device has consumed its free trial", read by
//  the paywall on launch.
//
//  For security, the actual DeviceCheck API key (.p8) lives only on
//  our Cloud Functions backend — Apple requires a JWT signed with
//  that key to read/write the bits, and embedding the key in the
//  client app would let any reverse-engineer reset every user's
//  trial bit. The client therefore just generates a short-lived
//  device token (`DCDevice.current.generateToken`) and POSTs it to
//  our two Cloud Functions endpoints, which sign the JWT
//  server-side and proxy to Apple.
//
//  Hard requirement: this gate MUST fail open. If the network is
//  unreachable, our backend is down, or DeviceCheck itself is
//  unsupported on the device, the user must still be allowed to
//  use the app — the existing UserDefaults counter remains the
//  authoritative gate, and a worse-case false-positive abuser
//  slipping through is an acceptable cost compared to false-negative
//  blocking a paying customer offline.
//

import Foundation
import DeviceCheck
import FirebaseAuth

/// Result of querying our DeviceCheck-backed trial bit.
public enum TrialBitResult: Equatable {
    case used
    case unused
    case unknown(UnknownReason)

    public enum UnknownReason: String, Equatable {
        case unsupported           // DCDevice.isSupported == false (older sim, etc.)
        case tokenGenerationFailed // generateToken returned an error
        case notAuthenticated      // No Firebase user → can't get an ID token
        case authTokenFailed       // getIDToken errored
        case networkError          // URLSession failed
        case badResponse           // Non-2xx or unparseable body
    }

    /// Convenience: did the lookup actually conclude that the trial is consumed?
    /// `.unknown(...)` always answers false here so the gate fails open.
    public var trialIsConsumed: Bool {
        if case .used = self { return true }
        return false
    }
}

/// Owns the DeviceCheck round-trip plus the 24h UserDefaults TTL cache.
@MainActor
public final class DeviceCheckTrialGate {

    // MARK: - Configuration

    /// Project id + region for the Cloud Functions HTTP triggers. Hardcoded
    /// rather than read from GoogleService-Info.plist because we want to
    /// fail loudly in code review if the URL ever drifts from what the
    /// Functions agent ships.
    private static let projectId = "nexgenspec-prod"
    private static let region = "us-central1"

    private static var endpointBase: String {
        "https://\(region)-\(projectId).cloudfunctions.net"
    }

    private static var getTrialStatusURL: URL {
        URL(string: "\(endpointBase)/getTrialStatus")!
    }

    private static var markTrialUsedURL: URL {
        URL(string: "\(endpointBase)/markTrialUsed")!
    }

    /// 24-hour TTL so we don't burn a network round-trip every time the
    /// paywall is consulted. The cache is advisory — `markTrialUsed` flips
    /// the bit immediately and updates the cache, so we never serve a
    /// stale `.unused` after a `markTrialUsed` succeeds in the same session.
    /// Nonisolated so the on-disk `CachedResult` (a value type, no main-actor
    /// state) can read it without crossing actor boundaries.
    nonisolated static let cacheTTL: TimeInterval = 24 * 60 * 60

    // MARK: - UserDefaults keys

    private enum CacheKey {
        static let result = "ngs.trial.deviceCheckCachedResult"
    }

    // MARK: - Cache shape

    /// On-disk representation of a cached `getTrialStatus` outcome. Only
    /// definitive answers (`used` / `unused`) get cached — `.unknown`
    /// never persists, so a transient outage doesn't poison the cache
    /// for 24 hours.
    /// Internal so test-only helpers can pass instances around; the type
    /// is still namespaced inside `DeviceCheckTrialGate`.
    struct CachedResult: Codable, Equatable {
        let result: String       // "used" | "unused"
        let timestampUnix: Double

        var isFresh: Bool {
            (Date().timeIntervalSince1970 - timestampUnix) < cacheTTL
        }

        var asTrialBitResult: TrialBitResult? {
            switch result {
            case "used":   return .used
            case "unused": return .unused
            default:       return nil
            }
        }

        static func from(_ result: TrialBitResult) -> CachedResult? {
            switch result {
            case .used:   return CachedResult(result: "used",   timestampUnix: Date().timeIntervalSince1970)
            case .unused: return CachedResult(result: "unused", timestampUnix: Date().timeIntervalSince1970)
            case .unknown: return nil
            }
        }
    }

    // MARK: - Last known state (sync read)

    /// Synchronous read of the most recently cached `used` answer. Returns
    /// false when the cache is empty, expired, or holds `unused`. Used by
    /// `SubscriptionManager.canCreateInspection` so the paywall check
    /// stays a pure synchronous computed property — the async refresh
    /// happens out-of-band on launch and post-login.
    public static var lastKnownTrialUsed: Bool {
        guard let cached = readCache(), cached.isFresh else { return false }
        return cached.asTrialBitResult == .used
    }

    // MARK: - Public API

    /// Queries our backend for the current state of this device's trial bit.
    /// Returns immediately from cache when a fresh entry exists. Caller is
    /// responsible for treating `.unknown(...)` as fail-open.
    public func isTrialUsedOnThisDevice() async -> TrialBitResult {
        // Fast path: serve a fresh cached answer.
        if let cached = Self.readCache(), cached.isFresh, let result = cached.asTrialBitResult {
            return result
        }

        // Cold path: hit the network. Failures never poison the cache.
        let result = await fetch(url: Self.getTrialStatusURL, expectsResultBody: true)
        if let cacheable = CachedResult.from(result) {
            Self.writeCache(cacheable)
        }
        return result
    }

    /// Tells our backend to flip the device bit to "trial consumed". Returns
    /// true on a confirmed 2xx response, false otherwise. On success, the
    /// local cache is preemptively updated to `used` so the paywall
    /// reflects the state immediately without waiting for the next refresh.
    @discardableResult
    public func markTrialUsed() async -> Bool {
        let result = await fetch(url: Self.markTrialUsedURL, expectsResultBody: false)
        switch result {
        case .used, .unused:
            // Server accepted the write. Treat as `used` regardless of what
            // the server echoes — markTrialUsed is monotonic, never flips
            // back to unused.
            Self.writeCache(CachedResult(result: "used", timestampUnix: Date().timeIntervalSince1970))
            AuditLog.log(event: "DeviceCheck trial bit set on device")
            return true
        case .unknown(let reason):
            Diagnostics.logError(context: "DeviceCheckTrialGate.markTrialUsed unknown reason=\(reason.rawValue)")
            return false
        }
    }

    // MARK: - Network plumbing

    /// Builds and executes the JSON POST to one of our Cloud Functions.
    /// `expectsResultBody == true` parses `{ "trialUsed": Bool }` from the
    /// response and returns `.used` / `.unused`. When false, any 2xx is
    /// considered success and returned as `.unused` (the caller of
    /// `markTrialUsed` only cares about success vs. failure).
    private func fetch(url: URL, expectsResultBody: Bool) async -> TrialBitResult {
        // 1. DeviceCheck token
        guard DCDevice.current.isSupported else {
            return .unknown(.unsupported)
        }
        let tokenData: Data
        do {
            tokenData = try await Self.generateDeviceToken()
        } catch {
            Diagnostics.logError(context: "DeviceCheckTrialGate.generateDeviceToken", error: error)
            return .unknown(.tokenGenerationFailed)
        }
        let tokenBase64 = tokenData.base64EncodedString()

        // 2. Firebase ID token (Authorization: Bearer ...)
        guard let user = Auth.auth().currentUser else {
            return .unknown(.notAuthenticated)
        }
        let idToken: String
        do {
            idToken = try await user.getIDToken()
        } catch {
            Diagnostics.logError(context: "DeviceCheckTrialGate.getIDToken", error: error)
            return .unknown(.authTokenFailed)
        }

        // 3. Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let body: [String: String] = ["deviceToken": tokenBase64]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            Diagnostics.logError(context: "DeviceCheckTrialGate.encodeBody", error: error)
            return .unknown(.badResponse)
        }

        // 4. Round-trip
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Diagnostics.logError(context: "DeviceCheckTrialGate.\(url.lastPathComponent).network", error: error)
            return .unknown(.networkError)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Diagnostics.logError(context: "DeviceCheckTrialGate.\(url.lastPathComponent).status=\(code)")
            return .unknown(.badResponse)
        }

        if !expectsResultBody {
            return .unused // sentinel for "write succeeded"; markTrialUsed() collapses both into success
        }

        // 5. Decode { "trialUsed": Bool }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            if let dict = parsed as? [String: Any], let used = dict["trialUsed"] as? Bool {
                return used ? .used : .unused
            }
            return .unknown(.badResponse)
        } catch {
            Diagnostics.logError(context: "DeviceCheckTrialGate.decode", error: error)
            return .unknown(.badResponse)
        }
    }

    /// Wraps `DCDevice.current.generateToken`'s callback API in async/await.
    private static func generateDeviceToken() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCDevice.current.generateToken { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "DeviceCheckTrialGate",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "DeviceCheck returned neither token nor error."]
                    ))
                }
            }
        }
    }

    // MARK: - Cache I/O (testable)

    /// Reads the current cached result, or nil if missing/corrupted.
    /// Internal so tests can introspect.
    static func readCache() -> CachedResult? {
        guard let data = UserDefaults.standard.data(forKey: CacheKey.result) else { return nil }
        return try? JSONDecoder().decode(CachedResult.self, from: data)
    }

    /// Persists a definitive result. Internal so tests can seed values.
    static func writeCache(_ value: CachedResult) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: CacheKey.result)
    }

    /// Test hook: clears any cached entry. Production code never needs this —
    /// the cache naturally expires after 24h and `markTrialUsed` overwrites
    /// it with a fresh `used` value.
    static func clearCacheForTesting() {
        UserDefaults.standard.removeObject(forKey: CacheKey.result)
    }

    /// Test hook: writes a raw cache entry with a caller-supplied timestamp,
    /// so TTL behavior can be verified without sleeping for 24 hours.
    static func writeCacheForTesting(result: String, timestampUnix: Double) {
        writeCache(CachedResult(result: result, timestampUnix: timestampUnix))
    }
}
