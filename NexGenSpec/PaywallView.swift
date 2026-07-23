//
//  PaywallView.swift
//  NexGenSpec
//
//  Real StoreKit 2 paywall. Loads products via SubscriptionManager, handles
//  purchase + restore, dismisses on successful upgrade.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscriptions: SubscriptionManager

    @State private var purchaseInProgress = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            AppScreenBackground {
                ScrollView {
                    VStack(spacing: 24) {
                        LogoLockup()
                            .accessibilityHidden(true)
                            .padding(.top, 40)

                        Text("Upgrade to Pro")
                            .font(AppFont.title)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        if let remaining = subscriptions.freeInspectionsRemaining, remaining <= 0 {
                            Text("You've used all \(SubscriptionManager.freeInspectionLimit) free inspections. Subscribe for unlimited inspections and clean, unwatermarked PDF reports.")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else if let remaining = subscriptions.freeInspectionsRemaining {
                            Text("You have \(remaining) free inspection\(remaining == 1 ? "" : "s") remaining. Subscribe for unlimited inspections and clean, unwatermarked PDF reports.")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else {
                            Text("Unlock unlimited inspections and clean, unwatermarked PDF reports. Cancel anytime in Settings.")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        premiumFeaturesList

                        #if DEBUG
                        if ScreenshotMode.isActive {
                            // Screenshot capture: always render the static rows.
                            // They mirror purchaseButton pixel-for-pixel with the
                            // FINAL App Store Connect display names/prices — the
                            // sandbox otherwise serves whatever stale metadata is
                            // currently saved in ASC.
                            screenshotStaticPlans
                        } else if subscriptions.products.isEmpty {
                            emptyProductsBlock
                        } else {
                            subscriptionOptions
                        }
                        #else
                        if subscriptions.products.isEmpty {
                            emptyProductsBlock
                        } else {
                            subscriptionOptions
                        }
                        #endif

                        legalText

                        Spacer(minLength: 20)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Premium Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Maybe Later") { dismiss() }
                        .accessibilityLabel("Dismiss paywall")
                        .font(.headline)
                        .padding(8)
                }
            }
            .alert("Purchase Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
        }
        .task {
            if subscriptions.products.isEmpty {
                await subscriptions.refresh()
            }
        }
        .onAppear {
            // Defensive dismiss: if the paywall was somehow opened while
            // the user is already Pro (e.g. stale caller state from a
            // tab that read isPro before it refreshed), bail immediately.
            // Previously only the .onChange below dismissed, but that
            // doesn't fire for an already-true value at mount time —
            // which is exactly the beta-reported "paywall still appears
            // after I upgraded" bug.
            if subscriptions.isPro {
                DispatchQueue.main.async { dismiss() }
            }
        }
        .onChange(of: subscriptions.isPro) { _, newValue in
            if newValue { dismiss() }
        }
    }

    // MARK: - Sections

    private var premiumFeaturesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(title: "Unlimited Inspections", requiresUpgrade: true)
            featureRow(title: "Clean, Unwatermarked PDF Reports", requiresUpgrade: true)
            featureRow(title: "Priority Support", requiresUpgrade: true)
            // LiDAR scanning and the annotation tools are available to everyone
            // within the free quota — they're free authoring features, not Pro
            // upsells. List them as included so the paywall isn't selling what
            // users already have.
            featureRow(title: "LiDAR Scanning", requiresUpgrade: false)
            featureRow(title: "Annotation Tools", requiresUpgrade: false)
            featureRow(title: "\(SubscriptionManager.freeInspectionLimit) Free Inspections", requiresUpgrade: false)
        }
        .inspectionCard()
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

    /// Shown while products are loading (or failed to load): spinner,
    /// error detail, and a retry button. Extracted verbatim from the body.
    private var emptyProductsBlock: some View {
        VStack(spacing: 8) {
            ProgressView("Loading purchase options…")
            if let err = subscriptions.lastError {
                #if DEBUG
                Text("Debug: \(err)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                #else
                Text("Unable to load purchase options. Please check your connection and try again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                #endif
            }
            Button("Retry") {
                Task { await subscriptions.refresh() }
            }
            .font(.caption)
        }
        .padding()
    }

    #if DEBUG
    /// Screenshot-only (never compiled into Release): static plan rows that
    /// mirror subscriptionOptions/purchaseButton exactly, using the display
    /// names, descriptions, and prices configured in App Store Connect for
    /// com.nexgenspec.annualv1 / com.nexgenspec.monthlyv1 — what the live
    /// paywall shows once StoreKit serves real products.
    private var screenshotStaticPlans: some View {
        VStack(spacing: 12) {
            Text("Choose Your Plan")
                .font(.headline)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

            staticPlanRow(
                name: "NexGenSpec Pro — Annual",
                description: "Unlimited inspections and watermark-free, branded PDF reports with your company logo, across iPhone, iPad, and Mac. Billed annually.",
                price: "$449.00")
            staticPlanRow(
                name: "NexGenSpec Pro — Monthly",
                description: "Unlimited inspections and watermark-free, branded PDF reports with your company logo, across iPhone, iPad, and Mac. Billed monthly.",
                price: "$49.00")

            Button(action: {}) {
                Text("Restore Purchases")
            }
            .buttonStyle(AppSecondaryButtonStyle())
            .padding(.top, 20)
        }
    }

    private func staticPlanRow(name: String, description: String, price: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(price)
                .font(.headline)
        }
        .padding()
        .background(AppColor.accent.opacity(0.10))
        .cornerRadius(16)
    }
    #endif

    private var subscriptionOptions: some View {
        VStack(spacing: 12) {
            Text("Choose Your Plan")
                .font(.headline)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            ForEach(subscriptions.products, id: \.id) { product in
                purchaseButton(for: product)
            }

            Button(action: restore) {
                Text("Restore Purchases")
            }
            .buttonStyle(AppSecondaryButtonStyle())
            .accessibilityHint("Restore previous purchases")
            .padding(.top, 20)
            .disabled(purchaseInProgress || subscriptions.isBusy)
        }
    }

    private func purchaseButton(for product: Product) -> some View {
        Button {
            buy(product)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    if !product.description.isEmpty {
                        Text(product.description)
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
            .background(AppColor.accent.opacity(0.10))
            .cornerRadius(16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(product.displayName), \(product.displayPrice), tap to purchase")
        }
        .disabled(purchaseInProgress || subscriptions.isBusy)
        .contentShape(Rectangle())
    }

    private var legalText: some View {
        VStack(spacing: 8) {
            Text("""
            • Prices shown are in your local currency and include applicable taxes.
            • Subscriptions auto-renew monthly or yearly until cancelled.
            • Cancel anytime in your App Store account settings.
            • Payment is charged to your Apple ID at purchase confirmation.
            """)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)

            HStack(spacing: 24) {
                Link("Terms of Use", destination: URL(string: "https://nexgenspec.com/terms.html")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)
                    .underline()
                Link("Privacy Policy", destination: URL(string: "https://nexgenspec.com/privacy.html")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)
                    .underline()
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func buy(_ product: Product) {
        purchaseInProgress = true
        Task {
            let ok = await subscriptions.purchase(product)
            purchaseInProgress = false
            if !ok, let msg = subscriptions.lastError {
                errorMessage = msg
                showError = true
            }
            // On success, onChange(isPro) dismisses.
        }
    }

    private func restore() {
        purchaseInProgress = true
        Task {
            await subscriptions.restore()
            purchaseInProgress = false
            if !subscriptions.isPro {
                errorMessage = subscriptions.lastError ?? "No active subscriptions to restore."
                showError = true
            }
        }
    }
}

struct LogoLockup: View {
    var body: some View {
        BrandLockup(
            subtitle: "Unlock the full inspection toolkit.",
            markSize: 72
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
}
