import SwiftUI

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

    var body: some View {
        AppScreenBackground {
            Form {
                Section {
                    SettingsHeroCard(
                        username: authManager.currentUsername ?? "Unknown",
                        roleLabel: roleLabel
                    )
                }
                .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                .listRowBackground(Color.clear)

                Section("Account") {
                    LabeledContent("User", value: authManager.currentUsername ?? "Unknown")
                    LabeledContent("Role", value: roleLabel)

                    Button("Log Out", role: .destructive) {
                        authManager.logout()
                        dismiss()
                    }
                }

                Section {
                    NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                    NavigationLink("Terms of Service") { TermsOfServiceView() }
                    NavigationLink("Data Safety Summary") { DataSafetySummaryView() }
                    NavigationLink("View Feedback Log") { LegalHistoryView() }
                } header: {
                    Text("Legal & Data Safety")
                } footer: {
                    Text("Use these screens to review the current legal text, audit history, and the in-app data safety summary shown to customers.")
                }

                if authManager.isAdmin {
                    Section {
                        SecureField("Backup passphrase", text: $backupPassphrase)
                        Button("Create Encrypted Backup") {
                            createEncryptedBackup()
                        }
                        .disabled(backupPassphrase.count < 8)

                        SecureField("Restore passphrase", text: $restorePassphrase)
                        Button("Restore Latest Backup") {
                            restoreLatestBackup()
                        }
                        .disabled(restorePassphrase.count < 8)
                    } header: {
                        Text("Admin Backup")
                    } footer: {
                        Text("Encrypted backups are stored in the protected app backup directory.")
                    }

                    Section {
                        Button("Purge Expired Records (5+ years)", role: .destructive) {
                            runRetentionPurge()
                        }
                    } header: {
                        Text("Admin Retention")
                    } footer: {
                        Text("Retention purge is restricted to admin accounts and permanently removes records outside the policy window.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("Settings")
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
    }

    private var roleLabel: String {
        switch authManager.role {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .user: return "User"
        case .none: return "Signed Out"
        }
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

private struct SettingsBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(AppColor.elevatedSurface.opacity(0.92))
            .foregroundStyle(AppColor.accentDeep)
            .clipShape(Capsule())
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
