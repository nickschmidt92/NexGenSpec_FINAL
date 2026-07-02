import SwiftUI
import MessageUI
import UIKit
import EventKit
#if DEBUG
import FirebaseCrashlytics
#endif

struct AppSettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var store: InspectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var backupPassphrase = ""
    @State private var restorePassphrase = ""
    @State private var statusMessage: String?
    @State private var showStatus = false
    @State private var purgeSummary = ""
    @State private var showPurgeResult = false
    /// True while an encrypted backup create/restore is running off the main
    /// actor. Drives the inline progress indicator and disables the buttons so
    /// the operation can't be re-triggered mid-flight.
    @State private var isBackupBusy = false

    @EnvironmentObject private var subscriptions: SubscriptionManager
    @ObservedObject private var profile = InspectorProfile.shared
    @State private var showPaywall = false
    // SyncCoordinator is always created + injected by NexGenSpecApp (it's inert
    // when the sync flag is off), so this reference must compile in Release too —
    // the account-deletion teardown below (tearDownDeletedAccount) uses it
    // outside any DEBUG guard. Only the dev-only sync toggle UI is #if DEBUG.
    @EnvironmentObject private var syncCoordinator: SyncCoordinator
    @AppStorage(SyncFeature.localOnlyModeKey) private var localOnlyMode = false

    /// The user-facing iCloud Sync section (Local-Only opt-out). Extracted from the
    /// main settings body to keep that body within the SwiftUI type-checker budget.
    @ViewBuilder
    private var iCloudSyncSection: some View {
        SettingsSectionCard(
            title: "iCloud Sync",
            subtitle: "Your inspection records sync across your Apple devices through your private iCloud. Photos, videos, report PDFs, and thumbnails stay on the device where they were created — they do not sync yet. Your data goes only to your iCloud — NexGenSpec never receives or stores it. Turn on Local-Only mode to keep inspections on this device. Sync is not a backup: deletions sync across your devices."
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Toggle("Local-Only mode", isOn: $localOnlyMode)
                    .onChange(of: localOnlyMode) { _, _ in
                        // Re-evaluate the active port immediately so toggling takes
                        // effect without a relaunch.
                        syncCoordinator.userDidChange(uid: authManager.currentUID)
                    }
                Text(localOnlyMode
                     ? "Inspections stay on this device only. Use the Files-app export to move them between your devices."
                     : "Inspections sync across your own devices through your private iCloud.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
#if DEBUG
    @AppStorage(SyncFeature.devEnabledKey) private var syncDevEnabled = false
    private var syncStatusLabel: String {
        switch syncCoordinator.status {
        case .off: return "Off"
        case .localOnly: return "Local only (no iCloud account)"
        case .idle: return "Bound — idle"
        case .syncing: return "Syncing…"
        case .paused(let reason): return "Paused — \(reason)"
        case .error(let message): return "Error — \(message)"
        }
    }
#endif

    // Logo picker
    @State private var showLogoPicker = false

    // Recovery / fallback email read-back (T-01506). Loaded from the Keychain
    // for the current UID on appear, and re-loaded after the inline editor
    // saves, so the displayed value always reflects what's persisted.
    @State private var recoveryEmail: String?
    @State private var showRecoveryEmailEditor = false

    // Support / Report an Issue
    @State private var showReportMailer = false
    @State private var showMailUnavailable = false

    // Delete Account flow
    @State private var showDeleteConfirm = false
    @State private var deleteConfirmText: String = ""
    @State private var showDeletePasswordSheet = false
    @State private var deletePasswordInput = ""
    @State private var deleteErrorMessage: String?
    @State private var showDeleteError = false
    @State private var isDeletingAccount = false

    // Account-deletion receipt share sheet (T-01216).
    // Switched from MFMailComposeViewController → UIActivityViewController so
    // the receipt is deliverable even if iOS Mail isn't configured (e.g.
    // Yahoo-only users). The share sheet auto-detects installed Mail apps
    // (Yahoo Mail / Gmail / Outlook), AirDrop, Messages, Files, etc., and the
    // receipt PDF is also saved at Application Support/NexGenSpecReceipts/ (a
    // private, non-file-shared location) as a permanent record regardless of how
    // the user delivers it.
    @State private var showDeletionReceiptShareSheet = false
    @State private var pendingDeletionReceiptURL: URL?
    @State private var pendingDeletionReceiptBody: String = ""

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    SettingsHeroCard(
                        username: authManager.currentUsername ?? "Unknown",
                        roleLabel: roleLabel
                    )

                    SettingsSectionCard(
                        title: "Account",
                        subtitle: "Current session identity and access level."
                    ) {
                        SettingsValueRow(title: "User", value: authManager.currentUsername ?? "Unknown")
                        SettingsValueRow(title: "Role", value: roleLabel)
                        SettingsValueRow(title: "Subscription", value: subscriptionLabel)

                        // Recovery email read-back (T-01506). Shows the
                        // fallback email the user set at signup (or later)
                        // so it's no longer write-only. "Not set" when the
                        // Keychain has no value for the current UID.
                        SettingsValueRow(
                            title: "Recovery email",
                            value: (recoveryEmail?.isEmpty == false) ? recoveryEmail! : "Not set"
                        )

                        Button((recoveryEmail?.isEmpty == false) ? "Update Recovery Email" : "Add Recovery Email") {
                            showRecoveryEmailEditor = true
                        }
                        .buttonStyle(AppSecondaryButtonStyle())

                        Text("Used only to reach you for receipts, account recovery, or important service notices if you ever lose access to your primary email.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)

                        if !subscriptions.isAdminAccount {
                            // Pro users go to iOS Subscriptions directly to
                            // cancel / change plan; only non-Pro users see
                            // the in-app paywall. Fixes a beta-reported bug
                            // where tapping "Manage Subscription" re-opened
                            // the upgrade paywall instead of taking the user
                            // somewhere they could actually manage the sub.
                            if subscriptions.isPro {
                                Button("Manage Subscription") {
                                    if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .buttonStyle(AppPrimaryButtonStyle())
                            } else {
                                Button("Upgrade to Pro") {
                                    showPaywall = true
                                }
                                .buttonStyle(AppPrimaryButtonStyle())
                            }
                        }

                        Button("Log Out", role: .destructive) {
                            // Flush any pending debounced save before we
                            // tear down the session. Protects against
                            // the data-loss bug caught in the first
                            // TestFlight cohort (2026-04-19): editing
                            // an inspection then hitting Log Out used
                            // to drop the last unsaved changes on the
                            // floor.
                            store.saveNow()
                            authManager.logout()
                            dismiss()
                        }
                        .buttonStyle(AppSecondaryButtonStyle())

                        Text("Logging out preserves all inspections, photos, and reports on this device. Sign back in to restore access.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)

                        Button("Delete Account", role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(isDeletingAccount)

                        Text("Delete Account permanently erases your login AND every inspection, photo, signature, and report stored on this device. NexGenSpec keeps no server-side copy and cannot recover this data. This cannot be undone.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.critical)
                    }

                    SettingsSectionCard(
                        title: "Backup & Data",
                        subtitle: "NexGenSpec keeps no server-side copies of your inspections. Back up your data so it survives device loss, factory reset, or accidental uninstall."
                    ) {
                        BackupStatusView(metadataCount: store.metadataList.count)
                    }

                    iCloudSyncSection
#if DEBUG
                    SettingsSectionCard(
                        title: "CloudKit Sync (DEBUG)",
                        subtitle: "Developer-only. Pushes inspection JSON to the DEVELOPMENT CloudKit environment so sync can be tested on a real device. Push-only for now: changes appear in the CloudKit Dashboard, not on other devices. Compiled out of release builds."
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Toggle("Enable sync (this debug build only)", isOn: $syncDevEnabled)
                                .onChange(of: syncDevEnabled) { _, _ in
                                    syncCoordinator.userDidChange(uid: authManager.currentUID)
                                }
                            Text("Status: \(syncStatusLabel)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
#endif

                    SettingsSectionCard(
                        title: "Inspector Profile",
                        subtitle: "Saved across inspections. Auto-fills new inspection forms and appears on reports."
                    ) {
                        // Company logo
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Label("Company Logo", systemImage: "photo.badge.plus")
                                .font(AppFont.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: Spacing.md) {
                                if let logo = profile.companyLogo {
                                    Image(uiImage: logo)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.secondary.opacity(0.1))
                                        .frame(width: 64, height: 64)
                                        .overlay(
                                            Image(systemName: "building.2")
                                                .font(.title2)
                                                .foregroundStyle(.secondary)
                                        )
                                }

                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Button {
                                        showLogoPicker = true
                                    } label: {
                                        Text(profile.companyLogo == nil ? "Add Logo" : "Change Logo")
                                            .font(AppFont.subheadline.weight(.semibold))
                                    }

                                    if profile.companyLogo != nil {
                                        Button(role: .destructive) {
                                            profile.removeCompanyLogo()
                                        } label: {
                                            Text("Remove")
                                                .font(AppFont.caption)
                                        }
                                    }
                                }

                                Spacer()
                            }

                            Text("Appears on PDF reports in place of the NexGenSpec logo.")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, Spacing.xs)

                        SettingsTextFieldRow(title: "Inspector Name", text: $profile.inspectorName, systemImage: "person.fill")
                        SettingsTextFieldRow(title: "Company Name", text: $profile.companyName, systemImage: "building.2.fill")
                        SettingsTextFieldRow(title: "License #", text: $profile.licenseNumber, systemImage: "checkmark.seal.fill")
                        SettingsTextFieldRow(title: "Phone", text: $profile.phone, systemImage: "phone.fill")
                        SettingsTextFieldRow(title: "Email", text: $profile.email, systemImage: "envelope.fill")
                    }

                    SettingsSectionCard(
                        title: "Templates",
                        subtitle: "Manage inspection templates. Duplicate the built-in template and customize it."
                    ) {
                        NavigationLink {
                            TemplateManagerView()
                        } label: {
                            SettingsNavigationRow(
                                title: "Manage Templates",
                                subtitle: "View, duplicate, and edit inspection templates.",
                                systemImage: "doc.badge.gearshape.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSectionCard(
                        title: "Reports",
                        subtitle: "Browse and re-share the report PDFs and ZIP backups you’ve exported. They’re saved to your account; with iCloud Sync on, report PDFs sync across your own Apple devices through your private iCloud."
                    ) {
                        NavigationLink {
                            MyReportsView()
                        } label: {
                            SettingsNavigationRow(
                                title: "My Reports",
                                subtitle: "Saved report PDFs and backups. Tap to share or save to Files.",
                                systemImage: "folder.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSectionCard(
                        title: "Legal",
                        subtitle: "Review the customer-facing legal text shown to inspection clients."
                    ) {
                        NavigationLink {
                            PrivacyPolicyView()
                        } label: {
                            SettingsNavigationRow(
                                title: "Privacy Policy",
                                subtitle: "How personal and inspection data is handled.",
                                systemImage: "hand.raised.fill"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            TermsOfServiceView()
                        } label: {
                            SettingsNavigationRow(
                                title: "Terms of Service",
                                subtitle: "The current operating terms shown inside the app.",
                                systemImage: "doc.text.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSectionCard(
                        title: "Calendar",
                        subtitle: "Choose where NexGenSpec writes inspection events and manage OS-level access."
                    ) {
                        CalendarSettingsSection()
                            .environmentObject(authManager)
                    }

                    SettingsSectionCard(
                        title: "Support",
                        subtitle: "Report a bug or send feedback to the NexGenSpec team."
                    ) {
                        Button {
                            if MFMailComposeViewController.canSendMail() {
                                showReportMailer = true
                            } else {
                                showMailUnavailable = true
                            }
                        } label: {
                            SettingsNavigationRow(
                                title: "Report an Issue",
                                subtitle: "Opens an email to contact@nexgenspec.com with your device details pre-filled.",
                                systemImage: "exclamationmark.bubble.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if subscriptions.isAdminAccount {
                        SettingsSectionCard(
                            title: "Admin Backup",
                            subtitle: "Encrypted backups stay in the protected app backup directory."
                        ) {
                            SettingsSecureFieldRow(
                                title: "Backup passphrase",
                                text: $backupPassphrase,
                                systemImage: "key.fill"
                            )

                            Button("Create Encrypted Backup") {
                                Task { await createEncryptedBackup() }
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .disabled(backupPassphrase.count < EncryptedBackupService.minPassphraseLength || isBackupBusy)

                            SettingsSecureFieldRow(
                                title: "Restore passphrase",
                                text: $restorePassphrase,
                                systemImage: "arrow.clockwise.circle.fill"
                            )

                            Button("Restore Latest Backup") {
                                Task { await restoreLatestBackup() }
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                            .disabled(restorePassphrase.count < EncryptedBackupService.minPassphraseLength || isBackupBusy)

                            if isBackupBusy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Working… keep the app open until this finishes.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Backup in progress")
                            }
                        }

                        SettingsSectionCard(
                            title: "Admin Retention",
                            subtitle: "Use this only when records are outside the policy window and should be permanently removed."
                        ) {
                            Button("Purge Expired Records (5+ years)", role: .destructive) {
                                runRetentionPurge()
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                        }
                    }

                    #if DEBUG
                    SettingsSectionCard(
                        title: "Debug — Screenshot Fixture",
                        subtitle: "Loads two demo inspections (one draft for live PencilKit annotation, one ready-to-finalize) populated from marketing/screenshot-assets/. Debug builds only."
                    ) {
                        Button("Load Demo Inspection Data") {
                            DemoModeFixture.populate(store: store)
                        }
                        .buttonStyle(AppPrimaryButtonStyle())
                    }
                    #endif

                    // Open-Meteo requires visible attribution for use of their
                    // free weather API (see their Terms of Use). Kept as a
                    // subtle centered footnote linking to their site.
                    if let openMeteoURL = URL(string: "https://open-meteo.com/") {
                        Link(destination: openMeteoURL) {
                            Text("Weather data provided by Open-Meteo.com")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .underline()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Spacing.sm)
                        .accessibilityHint("Opens open-meteo.com in your browser")
                    }

                }
                .frame(maxWidth: 860)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Settings")
        }
        .task {
            reloadRecoveryEmail()
        }
        .sheet(isPresented: $showRecoveryEmailEditor, onDismiss: reloadRecoveryEmail) {
            RecoveryEmailEditorSheet(
                authManager: authManager,
                currentEmail: recoveryEmail
            )
        }
        .alert("Status", isPresented: $showStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .alert("Retention Purge", isPresented: $showPurgeResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purgeSummary)
        }
        .sheet(isPresented: $showDeleteConfirm) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Label("This action cannot be undone", systemImage: "exclamationmark.triangle.fill")
                            .font(AppFont.headline)
                            .foregroundStyle(AppColor.critical)

                        Text("Deleting your account will:")
                            .font(AppFont.subheadline.weight(.semibold))
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Permanently remove your authentication record from our servers.", systemImage: "person.crop.circle.badge.minus")
                            Label("Permanently erase ALL inspections, photos, signatures, audit logs, and PDF reports from this device.", systemImage: "trash.fill")
                            Label("Make all locally stored data unrecoverable. NexGenSpec does not maintain server-side copies.", systemImage: "icloud.slash")
                            Label("Generate an account-deletion receipt (PDF) you can save or email for your records via the share sheet.", systemImage: "envelope.badge")
                        }
                        .font(AppFont.footnote)
                        .foregroundStyle(.primary)

                        Divider().padding(.vertical, 4)

                        Text("Your subscription is separate:")
                            .font(AppFont.subheadline.weight(.semibold))
                        VStack(alignment: .leading, spacing: 6) {
                            Label("If you have an active Pro subscription, deleting your account does NOT cancel it — Apple keeps billing you until you cancel the subscription yourself.", systemImage: "creditcard.trianglebadge.exclamationmark")
                        }
                        .font(AppFont.footnote)
                        .foregroundStyle(.primary)
                        Button("Manage / Cancel Subscription") {
                            if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(AppFont.footnote.weight(.semibold))

                        Divider().padding(.vertical, 4)

                        Text("Before continuing, consider:")
                            .font(AppFont.subheadline.weight(.semibold))
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Have you exported your finalized inspections to Files / iCloud Drive?", systemImage: "square.and.arrow.up")
                            Label("Do you have an iCloud Backup of this device that includes the app?", systemImage: "icloud")
                            Label("Did you mean to LOG OUT instead? Logging out preserves all your data on the device.", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 4)

                        Text("To confirm, type DELETE in the box below:")
                            .font(AppFont.subheadline.weight(.semibold))
                        TextField("Type DELETE", text: $deleteConfirmText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(Spacing.sm)
                            .background(AppColor.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppColor.border, lineWidth: 1)
                            )
                    }
                    .padding(Spacing.lg)
                }
                .navigationTitle("Delete Account")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            deleteConfirmText = ""
                            showDeleteConfirm = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Delete Forever", role: .destructive) {
                            deleteConfirmText = ""
                            showDeleteConfirm = false
                            Task { await performDelete() }
                        }
                        .disabled(deleteConfirmText.trimmingCharacters(in: .whitespacesAndNewlines) != "DELETE" || isDeletingAccount)
                    }
                }
            }
        }
        .sheet(isPresented: $showDeletePasswordSheet) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Password", text: $deletePasswordInput)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Confirm your password")
                    } footer: {
                        Text("For security, please re-enter your password to finish deleting your account.")
                    }
                }
                .navigationTitle("Confirm Delete")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            deletePasswordInput = ""
                            showDeletePasswordSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Delete") {
                            Task { await confirmPasswordAndDelete() }
                        }
                        .disabled(deletePasswordInput.isEmpty || isDeletingAccount)
                    }
                }
            }
        }
        .alert("Delete Account", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "Could not delete account.")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $showLogoPicker) {
            LogoImagePicker { image in
                if let image {
                    profile.companyLogo = image
                }
            }
        }
        .sheet(isPresented: $showReportMailer) {
            MailComposeView(
                toRecipients: ["contact@nexgenspec.com"],
                subject: "NexGenSpec — Report an Issue",
                body: reportIssueBody(),
                isHTML: false,
                onDismiss: { showReportMailer = false }
            )
            .ignoresSafeArea()
        }
        .sheet(
            isPresented: $showDeletionReceiptShareSheet,
            onDismiss: {
                AuditLog.log(event: "Account deletion receipt share sheet dismissed")
                finishLocalWipeAndDismiss()
            }
        ) {
            if let url = pendingDeletionReceiptURL {
                ShareSheet(activityItems: [url, pendingDeletionReceiptBody])
                    .ignoresSafeArea()
            }
        }
        .alert("Mail Not Configured", isPresented: $showMailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up the Mail app, or email contact@nexgenspec.com directly from any mail client.")
        }
    }

    private func reportIssueBody() -> String {
        let device = UIDevice.current
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return """


        —
        Please describe the issue above. The details below help us diagnose faster.

        App: NexGenSpec \(appVersion) (\(build))
        Device: \(device.model) · iOS \(device.systemVersion)
        User: \(authManager.currentUsername ?? "unknown")
        Subscription: \(subscriptionLabel)
        """
    }

    @MainActor
    private func performDelete() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        // Snapshot what we'll need for the receipt BEFORE Firebase clears the user.
        let snapshot = captureDeletionInputs()
        do {
            try await authManager.deleteAccount()
            await proceedAfterFirebaseDelete(snapshot)
        } catch AuthManager.DeleteAccountError.needsPasswordReauth {
            showDeletePasswordSheet = true
        } catch AuthManager.DeleteAccountError.needsAppleReauth {
            do {
                try await authManager.reauthenticateWithApple()
                let postReauthSnapshot = captureDeletionInputs() ?? snapshot
                try await authManager.deleteAccount()
                await proceedAfterFirebaseDelete(postReauthSnapshot)
            } catch {
                deleteErrorMessage = error.localizedDescription
                showDeleteError = true
            }
        } catch {
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
        }
    }

    @MainActor
    private func confirmPasswordAndDelete() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await authManager.reauthenticateWithPassword(deletePasswordInput)
            deletePasswordInput = ""
            showDeletePasswordSheet = false
            let snapshot = captureDeletionInputs()
            try await authManager.deleteAccount()
            await proceedAfterFirebaseDelete(snapshot)
        } catch {
            deletePasswordInput = ""
            showDeletePasswordSheet = false
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
        }
    }

    /// Loads the recovery (fallback) email from the Keychain for the current
    /// UID into local state so the read-back row can display it. No-op result
    /// (nil) when signed out or none is set. (T-01506)
    private func reloadRecoveryEmail() {
        guard let uid = authManager.currentUserUID else {
            recoveryEmail = nil
            return
        }
        recoveryEmail = AuthManager.loadFallbackEmail(forUID: uid)
    }

    /// Captures everything needed for the deletion receipt while the Firebase
    /// user is still resolvable. Must run BEFORE `authManager.deleteAccount()`.
    @MainActor
    private func captureDeletionInputs() -> AccountDeletionReceiptService.Inputs? {
        guard let uid = authManager.currentUserUID else { return nil }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return AccountDeletionReceiptService.Inputs(
            accountEmail: authManager.currentUsername ?? "—",
            firebaseUID: uid,
            fallbackEmail: AuthManager.loadFallbackEmail(forUID: uid),
            inspectionsDeletedCount: store.metadataList.count,
            providerLabel: authManager.currentProviderLabel,
            appVersion: appVersion,
            buildNumber: build,
            deviceModel: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion
        )
    }

    /// Generates the deletion-receipt PDF and presents an iOS share sheet so
    /// the user can deliver it via whatever channel works for them — Yahoo
    /// Mail, Gmail, Apple Mail, AirDrop, Messages, Files, etc. The share sheet
    /// is more robust than MFMailComposeViewController because canSendMail()
    /// returns true on iPads where the Mail app exists but no account is
    /// configured, leading to silently-undelivered receipts. The local wipe
    /// only runs AFTER the share sheet dismisses, so the receipt PDF is
    /// reachable for attachment. The PDF is also saved at
    /// Application Support/NexGenSpecReceipts/ (private, non-file-shared)
    /// regardless of delivery choice.
    @MainActor
    private func proceedAfterFirebaseDelete(_ snapshot: AccountDeletionReceiptService.Inputs?) async {
        // T-01412: Firebase has deleted the account; mark the local wipe as owed
        // BEFORE it runs — and before the receipt share sheet, which the user can
        // abandon by killing the app. This flag lives in UserDefaults, which
        // clearAllLocalData() does not touch, so it survives the wipe and is
        // cleared once the wipe actually completes (here on success, or on the
        // next launch if this flow is interrupted).
        UserDefaults.standard.set(true, forKey: "deletion-pending-wipe")
        guard let snapshot else {
            finishLocalWipeAndDismiss()
            return
        }
        // B-0096: pin this user's UID so the local wipe — which runs AFTER
        // Firebase has already cleared `currentUser` (deleteAccount completed
        // above) — still resolves `appRoot` to the DELETED user's per-UID
        // namespace, and keeps doing so across a force-quit relaunch (the pin is
        // persisted). Without this the wipe would target the signed-out segment
        // and leave the user's inspections/PII on disk (5.1.1(v)). Released in
        // finishLocalWipeAndDismiss once the wipe finishes.
        SessionScope.pin(snapshot.firebaseUID)
        AuditLog.log(event: "Account deletion receipt requested for \(snapshot.firebaseUID)")
        do {
            // Render + write the receipt PDF off the main actor.
            // UIGraphicsPDFRenderer is safe off-main, drawReceipt only uses
            // renderer-context drawing, FileSecurity's helpers are static,
            // and `snapshot` is a value-type Inputs. The enclosing function
            // is @MainActor, so resumption after `.value` hops back here —
            // receipt-before-wipe ordering is preserved, and the UI is
            // already locked by isDeletingAccount during the await.
            let receiptURL = try await Task.detached(priority: .userInitiated) {
                try AccountDeletionReceiptService.generateReceipt(snapshot)
            }.value
            pendingDeletionReceiptURL = receiptURL
            pendingDeletionReceiptBody = AccountDeletionReceiptService.shareBody(
                for: snapshot,
                attachmentFileName: receiptURL.lastPathComponent
            )
            showDeletionReceiptShareSheet = true
        } catch {
            Diagnostics.logError(context: "Deletion receipt PDF generation failed", error: error)
            finishLocalWipeAndDismiss()
        }
    }

    @MainActor
    private func finishLocalWipeAndDismiss() {
        // Reset in-memory state + gate writes synchronously, then run the heavy
        // disk wipe in the BACKGROUND. We deliberately do NOT await it: flipping
        // auth and dismissing immediately means the user never sits on an
        // authenticated screen for an account that no longer exists. `store` is
        // captured directly so the background wipe survives this view's teardown.
        let store = self.store
        // Build 22 fix C / edge G: tear down the deleted account's CloudKit zone +
        // local binding so no residual client PII lingers in the user's private
        // iCloud (5.1.1(v) parity). The deleting UID is the active deletion pin (set
        // in proceedAfterFirebaseDelete before Firebase cleared currentUser); capture
        // it BEFORE the wipe Task below releases the pin. Strict no-op when the sync
        // flag is off or no binding exists.
        if let deletedUID = SessionScope.pinnedUID {
            syncCoordinator.tearDownDeletedAccount(uid: deletedUID)
        }
        store.beginWipe()
        Task {
            await store.performDiskWipe()
            // Retry guard cleared only AFTER the wipe actually completes, so an
            // interrupted background wipe still retries on next launch (T-01412).
            UserDefaults.standard.removeObject(forKey: "deletion-pending-wipe")
            // B-0096: release the per-UID deletion pin now the namespace is
            // wiped, so `appRoot` reverts to the live (signed-out) segment.
            SessionScope.unpin()
        }
        // Wipe the device-local inspector profile (name, company, license,
        // phone, email + logo) as part of account deletion. Apple 5.1.1(v)
        // requires deletion to remove the user's personal data — and this PII
        // is auto-CC'd on invoices and printed on client reports, so it must
        // not survive into the next session on a shared device. The disk wipe
        // above clears inspections; the profile lives in UserDefaults and is
        // otherwise only cleared by AuthManager.logout(), a path the delete
        // flow never traverses (B-0073).
        InspectorProfile.shared.clear()
        // Clear the per-UID custom templates held in the launch-time singleton
        // (B-0096 sibling): the wipe removes the disk file; this drops the
        // in-memory copy so it can't be observed before relaunch.
        CustomTemplateStore.shared.clear()
        // finalizeDeletion releases the auth-state hold set by deleteAccount()
        // and flips isAuthenticated to false, triggering RootView to swap in
        // LoginView.
        authManager.finalizeDeletion()
        dismiss()
    }

    private var roleLabel: String {
        // The admin-email whitelist overrides the Firebase role so whitelisted
        // accounts appear as "Admin" in the UI even before Firestore custom
        // claims are wired up.
        if subscriptions.isAdminAccount { return "Admin" }
        switch authManager.role {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .user: return "User"
        case .none: return "Signed Out"
        }
    }

    /// Displayed next to "Subscription" in Settings. Admins see "Admin" rather
    /// than "Free" so the label matches their access level.
    private var subscriptionLabel: String {
        if subscriptions.isAdminAccount { return "Admin" }
        return subscriptions.isPro ? "Pro" : "Free"
    }

    /// Reads every file under the app root, encrypts it, and writes the
    /// envelope to disk. The encryption + bulk file I/O run on a detached
    /// background task so a large inspection library can't freeze the UI (or
    /// trip the watchdog); only the loading flag and the final status update
    /// stay on the main actor. `passphrase` and `destination` are `Sendable`
    /// value types, so handing them to the detached task is race-free.
    @MainActor
    private func createEncryptedBackup() async {
        let passphrase = backupPassphrase
        let destination = backupDirectory().appendingPathComponent("backup-\(timestamp()).backup.enc")
        isBackupBusy = true
        defer { isBackupBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try EncryptedBackupService.createEncryptedBackup(passphrase: passphrase, destinationURL: destination)
            }.value
            statusMessage = "Encrypted backup created at \(destination.lastPathComponent)."
            showStatus = true
            backupPassphrase = ""
        } catch {
            Diagnostics.logError(context: "Create backup failed", error: error)
            statusMessage = "Backup failed: \(error.localizedDescription)"
            showStatus = true
        }
    }

    /// Decrypts the latest backup envelope and writes its files back to disk on
    /// a detached background task, then reloads the store on the main actor.
    /// Decryption + file I/O stay off-main; the final `reloadFromDisk()` and
    /// status update are the only main-actor work.
    @MainActor
    private func restoreLatestBackup() async {
        guard let latest = latestBackupURL() else {
            statusMessage = "No encrypted backups found."
            showStatus = true
            return
        }
        let passphrase = restorePassphrase
        isBackupBusy = true
        defer { isBackupBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try EncryptedBackupService.restoreEncryptedBackup(passphrase: passphrase, sourceURL: latest)
            }.value
            store.reloadFromDisk()
            statusMessage = "Backup restored from \(latest.lastPathComponent)."
            showStatus = true
            restorePassphrase = ""
        } catch {
            Diagnostics.logError(context: "Restore backup failed", error: error)
            statusMessage = "Restore failed: \(error.localizedDescription)"
            showStatus = true
        }
    }

    private func runRetentionPurge() {
        // Attribute the purge by Firebase UID, never the user's email — the audit
        // log is plaintext and user-exportable (mirrors AuthManager's SIWA convention).
        let result = store.purgeExpiredInspections(isAdmin: subscriptions.isAdminAccount, actorId: authManager.currentUserUID)
        purgeSummary = "Deleted: \(result.deletedInspectionIDs.count)\nSkipped: \(result.skippedInspectionIDs.count)"
        showPurgeResult = true
    }

    private func backupDirectory() -> URL {
        let dir = FilePaths.appRoot.appendingPathComponent("Backups", isDirectory: true)
        try? FileSecurity.ensureProtectedDirectory(dir)
        return dir
    }

    private func latestBackupURL() -> URL? {
        let dir = backupDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files
            .filter { $0.pathExtension == "enc" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

private struct SettingsHeroCard: View {
    let username: String
    let roleLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandLockup(
                subtitle: "Account controls, legal text, encrypted backups, and retention policy tools.",
                markSize: 60
            )

            HStack(spacing: Spacing.sm) {
                SettingsBadge(title: username, systemImage: "person.crop.circle.fill")
                SettingsBadge(title: roleLabel, systemImage: "person.badge.shield.checkmark")
            }
        }
        .inspectionCard()
    }
}

/// Inline editor for the recovery (fallback) email, reached from the Account
/// section's "Add / Update Recovery Email" button (T-01506). Mirrors the
/// signup-time `FallbackEmailPromptSheet` in RootView so wording and the
/// underlying `setFallbackEmail` validation stay consistent; the only
/// difference is this is reachable any time from Settings and pre-fills the
/// current value. The read-back in AppSettingsView re-loads on dismiss.
private struct RecoveryEmailEditorSheet: View {
    @ObservedObject var authManager: AuthManager
    let currentEmail: String?
    @State private var email: String = ""
    @State private var inlineError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Add a recovery email so we can reach you for receipts, account recovery, or important service notices if you ever lose access to your primary email.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("you@example.com", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                } header: {
                    Text("Recovery email")
                } footer: {
                    if let inlineError {
                        Text(inlineError).foregroundStyle(.red).font(.caption)
                    } else {
                        Text("Stored securely on this device. We never send marketing email here without your opt-in.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Recovery Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { email = currentEmail ?? "" }
        }
    }

    private func save() {
        inlineError = nil
        if authManager.setFallbackEmail(email) {
            dismiss()
        } else {
            inlineError = "Please enter a valid email address."
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppFont.title3)

                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Spacing.sm) {
                content
            }
        }
        .inspectionCard()
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(AppFont.headline)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppColor.accent.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppFont.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SettingsSecureFieldRow: View {
    let title: String
    @Binding var text: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 20)

                SecureField(title, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 54)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(AppColor.accent)
                .frame(width: 20)

            TextField(title, text: $text)
                .font(AppFont.body)
                .textInputAutocapitalization(title == "Email" ? .never : .words)
                .autocorrectionDisabled()
                .keyboardType(title == "Phone" ? .phonePad : title == "Email" ? .emailAddress : .default)
                .onChange(of: text) { _, newValue in
                    if title == "Phone" {
                        let formatted = formatPhoneNumber(newValue)
                        if formatted != newValue { text = formatted }
                    }
                }
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: 50)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SettingsBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(AppColor.accent.opacity(0.12))
            .foregroundStyle(AppColor.accent)
            .clipShape(Capsule())
    }
}

// MARK: - Logo Image Picker

private struct LogoImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onPick(image)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Calendar settings

/// Settings block for choosing which OS calendar NexGenSpec writes to
/// and surfacing grant status / deep link to system Settings.app.
/// Pulled out into its own view so the parent `SettingsSectionCard`
/// composition stays declarative.
private struct CalendarSettingsSection: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var calendarService = CalendarService.shared

    @State private var selectedIdentifier: String = ""
    @State private var calendars: [EKCalendar] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            statusRow

            switch calendarService.authorizationState {
            case .notDetermined:
                Button("Allow Calendar Access") {
                    Task { await calendarService.requestAccess(); refreshCalendars() }
                }
                .buttonStyle(AppPrimaryButtonStyle())
            case .denied, .restricted:
                Button("Open System Settings") {
                    openAppSettings()
                }
                .buttonStyle(AppSecondaryButtonStyle())
            case .writeOnly:
                Button("Enable Full Access in Settings") {
                    openAppSettings()
                }
                .buttonStyle(AppSecondaryButtonStyle())
                calendarPicker
            case .fullAccess:
                calendarPicker
            case .unknown:
                EmptyView()
            }

            Text("NexGenSpec writes events titled “NexGenSpec: <address>” and stores the client name, phone, email, and agent contact info in the event notes so you can see the full context at a glance. Deleting an inspection in NexGenSpec also deletes its calendar event.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            calendarService.refreshAuthorizationState()
            refreshCalendars()
            selectedIdentifier = CalendarPreferences.defaultCalendarIdentifier(for: authManager.currentUsername) ?? ""
        }
    }

    private var statusRow: some View {
        HStack {
            Text("Access")
                .font(AppFont.subheadline)
            Spacer()
            Text(authLabel)
                .font(AppFont.subheadline.weight(.semibold))
                .foregroundStyle(authColor)
        }
    }

    @ViewBuilder
    private var calendarPicker: some View {
        if calendars.isEmpty {
            Text("No writable calendars available.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Default Calendar", selection: $selectedIdentifier) {
                Text("Device Default").tag("")
                ForEach(calendars, id: \.calendarIdentifier) { cal in
                    Text(cal.title).tag(cal.calendarIdentifier)
                }
            }
            .onChange(of: selectedIdentifier) { _, newValue in
                CalendarPreferences.setDefaultCalendarIdentifier(
                    newValue.isEmpty ? nil : newValue,
                    for: authManager.currentUsername
                )
            }
        }
    }

    private func refreshCalendars() {
        calendars = calendarService.writableCalendars()
    }

    private var authLabel: String {
        switch calendarService.authorizationState {
        case .notDetermined: return "Not Asked"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .writeOnly: return "Write-Only"
        case .fullAccess: return "Full"
        case .unknown: return "Unknown"
        }
    }

    private var authColor: Color {
        switch calendarService.authorizationState {
        case .fullAccess: return .green
        case .writeOnly: return .orange
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AppSettingsView()
            .environmentObject(AuthManager())
            .environmentObject(InspectionStore())
            .environmentObject(SyncCoordinator())
    }
}
#endif
