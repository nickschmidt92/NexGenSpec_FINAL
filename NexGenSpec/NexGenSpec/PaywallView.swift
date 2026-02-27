import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = Store()
    @State private var purchaseInProgress = false
    @State private var purchaseError: Error?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    LogoLockup()
                        .accessibilityHidden(true)
                        .padding(.top, 40)

                    Text("Upgrade to Pro")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text("Get the most out of the app by unlocking premium features. Enjoy unlimited inspections, advanced tools like LiDAR scanning, PDF export, voice input, and the annotation pack. Upgrade anytime to remove limits and support development.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityLabel("Description of free vs pro tiers and premium features.")

                    premiumFeaturesList

                    if !store.subscriptionProducts.isEmpty || !store.addOnProducts.isEmpty {
                        subscriptionOptions
                    } else {
                        ProgressView("Loading purchase options...")
                            .padding()
                    }

                    legalText

                    Spacer(minLength: 20)

                    buttons
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                }
                .foregroundColor(.primary)
                .accentColor(.accentColor)
                .padding(.horizontal)
            }
            .navigationTitle("Premium Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Maybe Later") {
                        dismiss()
                    }
                    .accessibilityLabel("Dismiss paywall")
                    .font(.headline)
                    .padding(8)
                }
            }
            .alert(isPresented: Binding<Bool>(
                get: { purchaseError != nil },
                set: { newValue in if !newValue { purchaseError = nil } }
            )) {
                Alert(
                    title: Text("Purchase Failed"),
                    message: Text(purchaseError?.localizedDescription ?? "An unknown error occurred."),
                    dismissButton: .default(Text("OK"))
                )
            }
            .environment(\.colorScheme, .light)
        }
        .onAppear {
            store.fetchProducts()
        }
    }

    private var premiumFeaturesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(title: "Unlimited Inspections", requiresUpgrade: true)
            featureRow(title: "LiDAR Scanning", requiresUpgrade: true)
            featureRow(title: "PDF Export", requiresUpgrade: true)
            featureRow(title: "Voice Input", requiresUpgrade: true)
            featureRow(title: "Annotation Pack", requiresUpgrade: true)
            featureRow(title: "Basic Inspection Reports", requiresUpgrade: false)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    private func featureRow(title: String, requiresUpgrade: Bool) -> some View {
        HStack {
            Image(systemName: requiresUpgrade ? "lock.fill" : "checkmark.circle.fill")
                .foregroundColor(requiresUpgrade ? .accentColor : .green)
                .accessibilityHidden(true)
                .font(.title3)
                .frame(width: 28)
            Text(title)
                .font(.headline)
                .accessibilityLabel("\(title), \(requiresUpgrade ? "requires upgrade" : "included")")
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var subscriptionOptions: some View {
        VStack(spacing: 12) {
            if !store.subscriptionProducts.isEmpty {
                Text("Subscription Options")
                    .font(.headline)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                ForEach(store.subscriptionProducts, id: \.id) { product in
                    purchaseButton(for: product)
                }
            }

            if !store.addOnProducts.isEmpty {
                Text("Additional Purchases")
                    .font(.headline)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                ForEach(store.addOnProducts, id: \.id) { product in
                    purchaseButton(for: product)
                }
            }

            Button(action: restorePurchases) {
                Text("Restore Purchases")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(12)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Restore previous purchases")
            .padding(.top, 20)
        }
    }

    private func purchaseButton(for product: Product) -> some View {
        Button(action: {
            purchase(product: product)
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    if let description = product.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.headline)
            }
            .padding()
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(product.displayName), \(product.displayPrice), tap to purchase")
        }
        .disabled(purchaseInProgress)
        .contentShape(Rectangle())
    }

    private var legalText: some View {
        VStack(spacing: 8) {
            Text("""
            • Prices shown are in your local currency and include applicable taxes.
            • Subscriptions auto-renew monthly or yearly until cancelled.
            • Cancel anytime through your App Store account settings.
            • Manage and restore purchases easily.
            """)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)

            HStack(spacing: 24) {
                Link("Terms of Service", destination: URL(string: "https://example.com/terms")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)
                    .underline()
                    .accessibilityLabel("Terms of Service")

                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)
                    .underline()
                    .accessibilityLabel("Privacy Policy")
            }
        }
        .padding(.top, 12)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button(action: {
                dismiss()
            }) {
                Text("Maybe Later")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Dismiss paywall without upgrading")

            Button(action: upgradeToPro) {
                Text("Upgrade to Pro")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Start purchase process to upgrade to Pro")
            .disabled(purchaseInProgress)
        }
    }

    private func upgradeToPro() {
        guard let bestSub = store.subscriptionProducts.first else { return }
        purchase(product: bestSub)
    }

    private func purchase(product: Product) {
        purchaseInProgress = true
        Task {
            do {
                let result = try await store.purchase(product)
                if result == .success {
                    dismiss()
                }
            } catch {
                purchaseError = error
            }
            purchaseInProgress = false
        }
    }

    private func restorePurchases() {
        purchaseInProgress = true
        Task {
            do {
                try await store.restorePurchases()
                dismiss()
            } catch {
                purchaseError = error
            }
            purchaseInProgress = false
        }
    }
}

// MARK: - StoreKit 2 support and product management

@MainActor
final class Store: ObservableObject {
    @Published var subscriptionProducts: [Product] = []
    @Published var addOnProducts: [Product] = []

    func fetchProducts() {
        Task {
            // Using NexGenSpec.storekit namespace for testing as requested
            do {
                let products = try await Product.products(for: [
                    "com.example.app.pro_monthly",
                    "com.example.app.pro_yearly",
                    "com.example.app.lidar_addon",
                    "com.example.app.voice_addon",
                    "com.example.app.annotation_pack"
                ])

                // Filter by type for UI grouping
                subscriptionProducts = products.filter { $0.type == .autoRenewable }
                addOnProducts = products.filter { $0.type == .nonConsumable || $0.type == .consumable }
            } catch {
                // Fail silently, empty lists
                subscriptionProducts = []
                addOnProducts = []
            }
        }
    }

    func purchase(_ product: Product) async throws -> Product.PurchaseResult {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            return .success
        case .userCancelled, .pending:
            return .userCancelled
        @unknown default:
            return .userCancelled
        }
    }

    func restorePurchases() async throws {
        for await transaction in Transaction.currentEntitlements {
            // Finish any pending transactions if needed
            await transaction.finish()
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum StoreError: LocalizedError {
        case failedVerification
        var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "Transaction failed verification."
            }
        }
    }
}

struct LogoLockup: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("NexGenSpec")
                .font(.title2.bold())
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
        }
        .padding()
    }
}

extension Product {
    /// User-friendly display price string.
    var displayPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = priceLocale
        return formatter.string(from: price) ?? "\(price)"
    }
}
