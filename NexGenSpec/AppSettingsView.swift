import SwiftUI
import MessageUI
import UIKit

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

    @EnvironmentObject private var subscriptions: SubscriptionManager
    @ObservedObject private var profile = InspectorProfile.shared
    @State private var showPaywall = false

    // Logo picker
    @State private var showLogoPicker = false

    // Support / Report an Issue
    @State private var showReportMailer = false
    @State private var showMailUnavailable = false

    // Delete Account flow
    @State private var showDeleteConfirm = false
    @State private var showDeletePasswordSheet = false
    @State private var deletePasswordInput = ""
    @State private var deleteErrorMessage: String?
    @State private var showDeleteError = false
    @State private var isDeletingAccount = false

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

                        if !subscriptions.isAdminAccount {
                            Button(subscriptions.isPro ? "Manage Subscription" : "Upgrade to Pro") {
                                showPaywall = true
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                        }

                        Button("Log Out", role: .destructive) {
                            authManager.logout()
                            dismiss()
                        }
                        .buttonStyle(AppSecondaryButtonStyle())

                        Button("Delete Account", role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(isDeletingAccount)

                        Text("Deleting your account permanently removes your login and erases all inspections, photos, and reports stored on this device. This cannot be undone.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }

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
                        title: "Legal & Data Safety",
                        subtitle: "Review the customer-facing legal text, retention posture, and data-safety summary."
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

                        NavigationLink {
                            DataSafetySummaryView()
                        } label: {
                            SettingsNavigationRow(
                                title: "Data Safety Summary",
                                subtitle: "The in-app explanation of storage, access, and sharing rules.",
                                systemImage: "lock.doc.fill"
                            )
                        }
                        .buttonStyle(.plain)


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

                    if authManager.isAdmin {
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
                                createEncryptedBackup()
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .disabled(backupPassphrase.count < 8)

                            SettingsSecureFieldRow(
                                title: "Restore passphrase",
                                text: $restorePassphrase,
                                systemImage: "arrow.clockwise.circle.fill"
                            )

                            Button("Restore Latest Backup") {
                                restoreLatestBackup()
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                            .disabled(restorePassphrase.count < 8)
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
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
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
        .alert("Delete your account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                Task { await performDelete() }
            }
        } message: {
            Text("This permanently deletes your login and erases all inspections, photos, and reports stored on this device. This cannot be undone.")
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
        do {
            try await authManager.deleteAccount()
            finishLocalWipeAndDismiss()
        } catch AuthManager.DeleteAccountError.needsPasswordReauth {
            showDeletePasswordSheet = true
        } catch AuthManager.DeleteAccountError.needsAppleReauth {
            do {
                try await authManager.reauthenticateWithApple()
                try await authManager.deleteAccount()
                finishLocalWipeAndDismiss()
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
            try await authManager.deleteAccount()
            finishLocalWipeAndDismiss()
        } catch {
            deletePasswordInput = ""
            showDeletePasswordSheet = false
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
        }
    }

    @MainActor
    private func finishLocalWipeAndDismiss() {
        store.clearAllLocalData()
        authManager.logout()
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

    private func createEncryptedBackup() {
        do {
            let destination = backupDirectory().appendingPathComponent("backup-\(timestamp()).backup.enc")
            try EncryptedBackupService.createEncryptedBackup(passphrase: backupPassphrase, destinationURL: destination)
            statusMessage = "Encrypted backup created at \(destination.lastPathComponent)."
            showStatus = true
            backupPassphrase = ""
        } catch {
            Diagnostics.logError(context: "Create backup failed", error: error)
            statusMessage = "Backup failed: \(error.localizedDescription)"
            showStatus = true
        }
    }

    private func restoreLatestBackup() {
        do {
            guard let latest = latestBackupURL() else {
                statusMessage = "No encrypted backups found."
                showStatus = true
                return
            }
            try EncryptedBackupService.restoreEncryptedBackup(passphrase: restorePassphrase, sourceURL: latest)
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
        let result = store.purgeExpiredInspections(isAdmin: authManager.isAdmin, actorId: authManager.currentUsername)
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

#if DEBUG
#Preview {
    NavigationStack {
        AppSettingsView()
            .environmentObject(AuthManager())
            .environmentObject(InspectionStore())
    }
}
#endif
