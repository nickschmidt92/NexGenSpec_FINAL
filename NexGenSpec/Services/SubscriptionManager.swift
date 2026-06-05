//
//  SubscriptionManager.swift
//  NexGenSpec
//
//  StoreKit 2 entitlement manager. Owns the App Store product IDs, loads
//  them, listens for transaction updates, and publishes `isPro` so the rest
//  of the app can gate features (export, unlimited inspections, etc.).
//
//  Product IDs configured in App Store Connect (NexGenSpec Pro group):
//    - com.nexgenspec.monthlyv1    ($49  / month)  — Tier 49
//    - com.nexgenspec.annualv1     ($449 / year)   — Tier 449
//
//  Pricing locked by D-0045 (2026-04-27): single plan, auto-renew, annual
//  is the upgrade tier within the `nexgenspec_pro` subscription group.
//

import Foundation
import StoreKit
import CryptoKit

@MainActor
public final class SubscriptionManager: ObservableObject {

    // MARK: - Product IDs

    public enum ProductID {
        // Current single-tier Pro products
        public static let monthly = "com.nexgenspec.monthlyv1"
        public static let annual  = "com.nexgenspec.annualv1"

        // Legacy IDs (old two-tier pricing) — kept so existing subscribers
        // retain entitlements if they purchased before the tier change.
        static let legacyMonthlyPro = "com.nexgenspec.monthlypro1"
        static let legacyAnnualPro  = "com.nexgenspec.annualpro1"
        // Pre-v1 single-tier IDs (replaced by monthlyv1/annualv1 in this build) —
        // kept so anyone who subscribed under them retains Pro.
        static let legacyMonthlyV0  = "com.nexgenspec.monthly1"
        static let legacyAnnualV0   = "com.nexgenspec.annual"

        /// Products available for purchase (shown in paywall).
        public static let current: [String] = [annual, monthly]

        /// All recognized IDs including legacy (used for entitlement checks).
        public static let all: [String] = [annual, monthly, legacyAnnualPro, legacyMonthlyPro, legacyAnnualV0, legacyMonthlyV0]
    }

    // MARK: - Free trial

    /// Number of inspections allowed before a subscription is required.
    public static let freeInspectionLimit = 3

    private enum TrialKey {
        static let inspectionsCreated = "nexgenspec.trial.inspectionsCreated"
    }

    /// Number of inspections the user has created (persisted across launches).
    @Published public private(set) var freeInspectionsUsed: Int = 0

    /// True when the Apple-DeviceCheck-backed bit for this device says
    /// the trial has already been consumed on this hardware. Refreshed
    /// asynchronously on launch and after sign-in via `refreshDeviceCheckTrial()`.
    /// Defaults to false so the UI never blocks a fresh install while
    /// the first network check is in flight.
    @Published public private(set) var deviceCheckTrialUsed: Bool = false

    /// True if the user can create a new inspection. Order of checks:
    ///   1. Pro / admin / beta unlocks always win — these users see no gate.
    ///   2. Otherwise the local UserDefaults counter must be under the limit.
    ///   3. Even if the local counter is under the limit, a flipped
    ///      DeviceCheck bit (`deviceCheckTrialUsed == true`) blocks creation.
    ///      That branch fires after Delete App + reinstall: the local
    ///      counter resets to 0, but Apple's per-device bit (set the
    ///      first time the trial was burned through) survives the
    ///      reinstall and flags the abuser.
    public var canCreateInspection: Bool {
        if isPro || isAdminAccount || Self.isBetaOrSandboxBuild { return true }
        if deviceCheckTrialUsed { return false }
        return freeInspectionsUsed < Self.freeInspectionLimit
    }

    /// True if the user should have access to premium features (LiDAR,
    /// full PDF export, photo annotations, etc.). This is a pure *entitlement*
    /// check: only a paid subscription, an admin override, or a beta/simulator
    /// build unlocks premium output.
    ///
    /// Note: the free-trial generosity lives on inspection *creation*
    /// (`canCreateInspection` / `freeInspectionsRemaining`), not here. Gating
    /// premium output on the trial counter would always evaluate true — the
    /// counter is capped at `0...freeInspectionLimit` — so free users would
    /// receive clean (unwatermarked) branded PDFs forever (B-0065).
    public var hasFeatureAccess: Bool {
        isPro || isAdminAccount || Self.isBetaOrSandboxBuild
    }

    /// Remaining free inspections. Returns nil if subscribed, admin, or beta tester.
    public var freeInspectionsRemaining: Int? {
        (isPro || isAdminAccount || Self.isBetaOrSandboxBuild) ? nil : max(0, Self.freeInspectionLimit - freeInspectionsUsed)
    }

    /// Call after a new inspection is successfully created.
    public func recordInspectionCreated() {
        // Paid subscribers, admins, and beta testers never burn down the trial counter.
        guard !isPro, !isAdminAccount, !Self.isBetaOrSandboxBuild else { return }
        freeInspectionsUsed += 1
        UserDefaults.standard.set(freeInspectionsUsed, forKey: TrialKey.inspectionsCreated)

        // Once the trial is fully consumed, flip the DeviceCheck bit so a
        // future Delete App + reinstall doesn't grant a fresh 3-pack.
        // Fire-and-forget — the local counter is the synchronous gate,
        // the device bit is the post-reinstall backstop.
        if freeInspectionsUsed >= Self.freeInspectionLimit {
            let gate = DeviceCheckTrialGate()
            Task { [gate] in
                _ = await gate.markTrialUsed()
            }
        }
    }

    // MARK: - Simulator unlock (dev/test only)

    /// True **only** on the iOS Simulator, so local development and the
    /// automated test suite aren't blocked by the paywall. Simulator builds
    /// never reach end users, so this is safe.
    ///
    /// Returns **false** on every real device build — including TestFlight,
    /// App Review, and production.
    ///
    /// History: this used to also return `true` for any `sandboxReceipt`
    /// build, to unblock beta testers while the IAP products were still being
    /// configured in App Store Connect. That is now a submission hazard: the
    /// App Store binary App Review runs carries a `sandboxReceipt`, so the old
    /// behavior auto-granted Pro to the reviewer and `PaywallView` never
    /// triggered → Guideline 2.1 "couldn't locate the in-app purchase"
    /// rejection (B-0057 / T-01225). The IAPs are configured now, so TestFlight
    /// testers and the reviewer exercise the real paywall (sandbox purchases
    /// are free in those environments); the App Review demo account gets Pro
    /// via the admin override below instead.
    ///
    /// Evaluated once at first access and cached.
    public static let isBetaOrSandboxBuild: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Admin override (App Store review, internal testing, comps)

    /// Email addresses whose Firebase accounts are treated as admin (unlimited
    /// access, bypasses paywalls and trial limits). Used for:
    ///   - App Store review — credentials go in Review Notes.
    ///   - Internal QA — lets the team test Pro features without sandbox purchases.
    ///   - Comps — press/partners granted free access without subscribing.
    ///
    /// SHA-256 hashes of admin emails (lowercased, trimmed) rather than the
    /// emails themselves so the binary doesn't leak the addresses to anyone
    /// reverse-engineering it. The actual security gate is still the strong
    /// password on each admin Firebase account — hashing just makes it harder
    /// to identify which email to target.
    ///
    /// Currently registered:
    ///   contact@nexgenspec.com   → 3b00017c…  (owner / internal QA / comps)
    ///   appreview@nexgenspec.com → e7d2c6d6…  (App Store review demo account —
    ///                                          creds in AppStore/REVIEW_NOTES.md)
    ///
    /// To add a new admin email, run on the command line:
    ///   echo -n "<email>@<domain>" | shasum -a 256
    /// and append the hex digest below. (Long-term plan: move to Firebase
    /// Cloud Functions custom claims so this list lives server-side.)
    public static let adminEmailHashes: Set<String> = [
        "3b00017c131aa4a07923190294a22c9fd157378c78aa113ef91f9862992ee97d",
        "e7d2c6d6f818813a24d282b72005c53ac3bc571496a567f50eb6dc8ec66203da"
    ]

    /// True if the currently signed-in Firebase user matches the admin whitelist.
    /// Set by `applyCurrentUser(email:)`, which the app coordinator calls when
    /// auth state changes.
    @Published public private(set) var isAdminAccount: Bool = false

    /// SHA-256 of a normalized email, hex-encoded. Used to compare against
    /// `adminEmailHashes` without ever holding the plaintext email.
    private static func adminHash(of email: String) -> String {
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Wire this to `AuthManager.currentUsername`. Pass `nil` on sign-out.
    public func applyCurrentUser(email: String?) {
        guard let email else {
            isAdminAccount = false
            return
        }
        isAdminAccount = Self.adminEmailHashes.contains(Self.adminHash(of: email))
    }

    // MARK: - Persistence keys (offline grace)

    private enum CacheKey {
        static let isPro = "nexgenspec.entitlement.isPro"
        static let activeProduct = "nexgenspec.entitlement.activeProductID"
        static let lastVerified = "nexgenspec.entitlement.lastVerifiedDate"
    }

    /// Grace period: trust cached entitlement for 7 days offline.
    private static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Published state

    /// All loaded subscription products, ordered highest tier → lowest.
    @Published public private(set) var products: [Product] = []

    /// True if the current Apple ID has any active NexGenSpec subscription.
    @Published public private(set) var isPro: Bool = false

    /// Product ID of the active entitlement, if any. Useful for UI badges.
    @Published public private(set) var activeProductID: String?

    /// Last error string from a load / purchase / restore attempt.
    @Published public private(set) var lastError: String?

    /// True while a purchase or restore is in flight.
    @Published public private(set) var isBusy: Bool = false

    // MARK: - Init

    private var updatesTask: Task<Void, Never>?

    public init() {
        // Restore free trial counter
        self.freeInspectionsUsed = UserDefaults.standard.integer(forKey: TrialKey.inspectionsCreated)

        // Seed deviceCheckTrialUsed from the on-disk DeviceCheck cache so the
        // paywall reflects the right state on launch even before the async
        // refresh completes. Stale cache (>24h) is treated as "no opinion".
        self.deviceCheckTrialUsed = DeviceCheckTrialGate.lastKnownTrialUsed

        // Restore cached entitlement immediately so UI shows Pro on launch
        // even before StoreKit async calls complete.
        let cached = UserDefaults.standard.bool(forKey: CacheKey.isPro)
        let lastVerified = UserDefaults.standard.object(forKey: CacheKey.lastVerified) as? Date ?? .distantPast
        let withinGrace = Date().timeIntervalSince(lastVerified) < Self.gracePeriod
        if cached && withinGrace {
            self.isPro = true
            self.activeProductID = UserDefaults.standard.string(forKey: CacheKey.activeProduct)
        }

        // Start listening for transaction updates immediately so renewals
        // and out-of-app purchases update entitlement state in real time.
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(transactionResult: result)
            }
        }

        Task { await refresh() }
        Task { await refreshDeviceCheckTrial() }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Public API

    /// Fetches product metadata from the App Store and refreshes entitlements.
    public func refresh() async {
        await loadProducts()
        await updateEntitlements()
    }

    /// Buys the given product. Returns true on verified success.
    @discardableResult
    public func purchase(_ product: Product) async -> Bool {
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verify(verification)
                await transaction.finish()
                await updateEntitlements()
                return isPro
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Refreshes `deviceCheckTrialUsed` from the DeviceCheck-backed
    /// backend. Safe to call from anywhere — never blocks the UI, and
    /// `.unknown(...)` outcomes (offline, server down, simulator without
    /// DeviceCheck support) leave the published value at its previous
    /// state, so a transient network failure can't lock a paying user out.
    public func refreshDeviceCheckTrial() async {
        let gate = DeviceCheckTrialGate()
        let result = await gate.isTrialUsedOnThisDevice()
        switch result {
        case .used:
            if !deviceCheckTrialUsed {
                deviceCheckTrialUsed = true
                AuditLog.log(event: "DeviceCheck reports trial consumed on this device")
            }
        case .unused:
            if deviceCheckTrialUsed {
                deviceCheckTrialUsed = false
            }
        case .unknown:
            // Fail open — keep whatever cached/last-known value we have.
            break
        }
    }

    /// Asks StoreKit to sync with the App Store and re-checks entitlements.
    /// Required by App Review guideline 3.1.1.
    public func restore() async {
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await updateEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Internals

    private func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ProductID.current)
            // Preserve our preferred display order (annual first).
            let order = ProductID.current
            self.products = fetched.sorted {
                (order.firstIndex(of: $0.id) ?? .max)
                < (order.firstIndex(of: $1.id) ?? .max)
            }
        } catch {
            self.products = []
            self.lastError = error.localizedDescription
        }
    }

    /// Walks `Transaction.currentEntitlements` and sets `isPro`.
    /// Persists result to UserDefaults for offline grace period.
    private func updateEntitlements() async {
        var foundID: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProductID.all.contains(transaction.productID) else { continue }
            // Ignore if revoked or expired.
            if let revoked = transaction.revocationDate, revoked <= Date() { continue }
            if let exp = transaction.expirationDate, exp <= Date() { continue }
            foundID = transaction.productID
            break
        }
        self.activeProductID = foundID
        self.isPro = (foundID != nil)

        // Persist for offline grace
        UserDefaults.standard.set(self.isPro, forKey: CacheKey.isPro)
        UserDefaults.standard.set(self.activeProductID, forKey: CacheKey.activeProduct)
        UserDefaults.standard.set(Date(), forKey: CacheKey.lastVerified)
    }

    private func handle(transactionResult: VerificationResult<Transaction>) async {
        do {
            let transaction = try Self.verify(transactionResult)
            await transaction.finish()
            await updateEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:      throw StoreError.failedVerification
        case .verified(let s): return s
        }
    }

    public enum StoreError: LocalizedError {
        case failedVerification
        public var errorDescription: String? {
            switch self {
            case .failedVerification: return "App Store transaction failed verification."
            }
        }
    }
}
