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
        NavigationView {
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

                        Text("Unlock unlimited inspections, PDF export, voice input, LiDAR scanning, and the annotation pack. Cancel anytime in Settings.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        premiumFeaturesList

                        if subscriptions.products.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView("Loading purchase options…")
                                if let err = subscriptions.lastError {
                                    Text("Debug: \(err)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                                Button("Retry") {
                                    Task { await subscriptions.refresh() }
                                }
                                .font(.caption)
                            }
                            .padding()
                        } else {
                            subscriptionOptions
                        }

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
        .onChange(of: subscriptions.isPro) { _, newValue in
            if newValue { dismiss() }
        }
    }

    // MARK: - Sections

    private var premiumFeaturesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(title: "Unlimited Inspections", requiresUpgrade: true)
            featureRow(title: "PDF Export", requiresUpgrade: true)
            featureRow(title: "Voice Input", requiresUpgrade: true)
            featureRow(title: "LiDAR Scanning", requiresUpgrade: true)
            featureRow(title: "Annotation Pack", requiresUpgrade: true)
            featureRow(title: "Basic Inspection Reports", requiresUpgrade: false)
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
                Link("Terms of Service", destination: URL(string: "https://www.nexgenspec.com/terms")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)
                    .underline()
                Link("Privacy Policy", destination: URL(string: "https://www.nexgenspec.com/privacy")!)
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
