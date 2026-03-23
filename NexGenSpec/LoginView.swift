import SwiftUI

/// A simple username/password login view. On success, calls authManager.login
struct LoginView: View {
    @ObservedObject var authManager: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var showingError = false
    @State private var showingCreateAccount = false
    @FocusState private var focusedField: LoginField?

    private enum LoginField {
        case username
        case password
    }

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        BrandLockup(
                            subtitle: "Professional inspection reports, secure media, and field-ready workflows.",
                            markSize: 76
                        )

                        HStack(spacing: Spacing.sm) {
                            LoginCapabilityChip(title: "LiDAR Ready", systemImage: "viewfinder")
                            LoginCapabilityChip(title: "PDF Reports", systemImage: "doc.richtext")
                            LoginCapabilityChip(title: "Audit Trail", systemImage: "lock.doc")
                        }

                        Text("Built for field inspectors who need evidence-grade media, defensible reports, and a cleaner handoff to the client.")
                            .font(AppFont.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.xl)

                    VStack(spacing: Spacing.lg) {
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Sign In")
                                    .font(AppFont.title2)

                                Text("Resume inspections, reports, and retention-safe records with your existing workspace account.")
                                    .font(AppFont.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(spacing: Spacing.md) {
                                AuthFieldContainer(title: "Username", systemImage: "person.crop.circle") {
                                    TextField("Username", text: $username)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .submitLabel(.next)
                                        .focused($focusedField, equals: .username)
                                        .onSubmit {
                                            focusedField = .password
                                        }
                                }

                                AuthFieldContainer(title: "Password", systemImage: "lock.fill") {
                                    SecureField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .submitLabel(.go)
                                        .focused($focusedField, equals: .password)
                                        .onSubmit {
                                            attemptLogin()
                                        }
                                }
                            }

                            Button("Log In") {
                                attemptLogin()
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .accessibilityLabel("Log In")

                            Button("Create new account") {
                                showingCreateAccount = true
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                        }
                        .inspectionCard()

                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Why this build feels production-ready")
                                .font(AppFont.headline)

                            VStack(spacing: Spacing.sm) {
                                LoginSignalRow(
                                    title: "Cleaner handoff",
                                    subtitle: "The dashboard starts focused on active work instead of demo data or scaffolding.",
                                    systemImage: "sparkles"
                                )
                                LoginSignalRow(
                                    title: "Locked-down records",
                                    subtitle: "Media, legal screens, and audit history stay inside the inspection workflow.",
                                    systemImage: "lock.shield"
                                )
                                LoginSignalRow(
                                    title: "Branded experience",
                                    subtitle: "The app now uses your real NexGenSpec identity across entry, dashboard, and settings.",
                                    systemImage: "swatchpalette"
                                )
                            }

                            Text("Accounts are still local to the device, so you can test the workflow without backend risk before TestFlight.")
                                .font(AppFont.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .inspectionCard()
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .alert("Login Failed", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authManager.authErrorMessage ?? "Unable to sign in.")
        }
        .sheet(isPresented: $showingCreateAccount) {
            CreateAccountView(authManager: authManager) {
                showingCreateAccount = false
            }
        }
        .onAppear {
            focusedField = .username
        }
    }

    private func attemptLogin() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        if authManager.login(username: trimmedUsername, password: password) {
            username = trimmedUsername
            password = ""
        } else {
            showingError = true
        }
    }
}

private struct LoginSignalRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppColor.accentSoft.opacity(0.54))
                    .frame(width: 42, height: 42)

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.accentDeep)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppFont.headline)

                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(AppColor.elevatedSurface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AuthFieldContainer<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 20)

                content
                    .font(AppFont.body)
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 54)
            .background(AppColor.elevatedSurface.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct LoginCapabilityChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(AppColor.accentSoft.opacity(0.45))
            .foregroundStyle(AppColor.accentDeep)
            .clipShape(Capsule())
    }
}

// MARK: - Create account (demo: just picks username/password, then logs in)
private struct CreateAccountView: View {
    @ObservedObject var authManager: AuthManager
    var onDismiss: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Choose your credentials")
                } footer: {
                    Text("This account is stored locally on the device so you can keep testing the workflow without relying on a backend service.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Create account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create account") {
                        createAccount()
                    }
                }
            }
        }
    }

    private func createAccount() {
        errorMessage = nil
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUsername.isEmpty else {
            errorMessage = "Please enter a username."
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Please enter a password."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        if authManager.createAccount(username: trimmedUsername, password: password) {
            dismiss()
            onDismiss()
        } else {
            errorMessage = authManager.authErrorMessage ?? "Could not create account. Try a different username and password."
        }
    }
}
