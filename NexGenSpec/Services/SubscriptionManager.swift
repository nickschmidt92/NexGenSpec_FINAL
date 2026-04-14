//
//  SubscriptionManager.swift
//  NexGenSpec
//
//  StoreKit 2 entitlement manager. Owns the App Store product IDs, loads
//  them, listens for transaction updates, and publishes `isPro` so the rest
//  of the app can gate features (export, unlimited inspections, etc.).
//
//  Product IDs configured in App Store Connect (NexGenSpec Pro group):
//    - com.nexgenspec.monthly1     ($28.99  / month)
//    - com.nexgenspec.annual       ($289.99 / year)
//

import Foundation
import StoreKit

@MainActor
public final class SubscriptionManager: ObservableObject {

    // MARK: - Product IDs

    public enum ProductID {
        // Current single-tier Pro products
        public static let monthly = "com.nexgenspec.monthly1"
        public static let annual  = "com.nexgenspec.annual"

        // Legacy IDs (old two-tier pricing) — kept so existing subscribers
        // retain entitlements if they purchased before the tier change.
        static let legacyMonthlyPro = "com.nexgenspec.monthlypro1"
        static let legacyAnnualPro  = "com.nexgenspec.annualpro1"

        /// Products available for purchase (shown in paywall).
        public static let current: [String] = [annual, monthly]

        /// All recognized IDs including legacy (used for entitlement checks).
        public static let all: [String] = [annual, monthly, legacyAnnualPro, legacyMonthlyPro]
    }

    // MARK: - Free trial

    /// Number of inspections allowed before a subscription is required.
    public static let freeInspectionLimit = 3

    private enum TrialKey {
        static let inspectionsCreated = "nexgenspec.trial.inspectionsCreated"
    }

    /// Number of inspections the user has created (persisted across launches).
    @Published public private(set) var freeInspectionsUsed: Int = 0

    /// True if the user can create a new inspection (subscribed, admin, or under free limit).
    public var canCreateInspection: Bool {
        isPro || isAdminAccount || freeInspectionsUsed < Self.freeInspectionLimit
    }

    /// True if the user should have access to premium features (voice commands,
    /// LiDAR, full PDF export, etc.). During the free trial window (first
    /// `freeInspectionLimit` inspections), everything is unlocked so prospective
    /// customers can evaluate the full app before subscribing. After the trial,
    /// a paid subscription (or admin override) is required.
    ///
    /// Uses `<=` so that while the user is working inside their Nth free
    /// inspection (N == `freeInspectionLimit`), premium features remain available.
    public var hasFeatureAccess: Bool {
        isPro || isAdminAccount || freeInspectionsUsed <= Self.freeInspectionLimit
    }

    /// Remaining free inspections. Returns nil if subscribed or admin.
    public var freeInspectionsRemaining: Int? {
        (isPro || isAdminAccount) ? nil : max(0, Self.freeInspectionLimit - freeInspectionsUsed)
    }

    /// Call after a new inspection is successfully created.
    public func recordInspectionCreated() {
        // Paid subscribers and admins never burn down the trial counter.
        guard !isPro, !isAdminAccount else { return }
        freeInspectionsUsed += 1
        UserDefaults.standard.set(freeInspectionsUsed, forKey: TrialKey.inspectionsCreated)
    }

    // MARK: - Admin override (App Store review, internal testing, comps)

    /// Email addresses whose Firebase accounts are treated as admin (unlimited
    /// access, bypasses paywalls and trial limits). Used for:
    ///   - App Store review — credentials go in Review Notes.
    ///   - Internal QA — lets the team test Pro features without sandbox purchases.
    ///   - Comps — press/partners granted free access without subscribing.
    ///
    /// The email list is visible to anyone who reverse-engineers the binary, so
    /// protect the account(s) with strong passwords. Compare case-insensitively.
    /// To add more admin emails later: edit this Set, rebuild, ship an update.
    public static let adminEmails: Set<String> = [
        "contact@nexgenspec.com"
    ]

    /// True if the currently signed-in Firebase user matches the admin whitelist.
    /// Set by `applyCurrentUser(email:)`, which the app coordinator calls when
    /// auth state changes.
    @Published public private(set) var isAdminAccount: Bool = false

    /// Wire this to `AuthManager.currentUsername`. Pass `nil` on sign-out.
    public func applyCurrentUser(email: String?) {
        let normalized = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalized, Self.adminEmails.contains(normalized) {
            isAdminAccount = true
        } else {
            isAdminAccount = false
        }
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
