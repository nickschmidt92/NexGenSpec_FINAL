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
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    BrandLockup(
                        subtitle: "Professional inspection reports, secure media, and field-ready workflows.",
                        markSize: 76
                    )
                    .padding(.top, Spacing.xl)
                    .padding(.horizontal, Spacing.lg)

                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Sign In")
                                .font(AppFont.title2)

                            Text("Use an existing account to resume inspections, reports, and retention-safe records. In DEBUG builds you can still use the owner, admin, or testflight demo credentials.")
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

                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("What this build is ready for")
                                .font(AppFont.headline)

                            HStack(spacing: Spacing.sm) {
                                LoginCapabilityChip(title: "LiDAR Ready", systemImage: "viewfinder")
                                LoginCapabilityChip(title: "PDF Reports", systemImage: "doc.richtext")
                                LoginCapabilityChip(title: "Audit Trail", systemImage: "lock.doc")
                            }
                        }

                        Text("This is still a local-account build. Network authentication can be swapped in later without changing the inspection workflow.")
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .inspectionCard()
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
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
                    Text("Demo mode: your account is created locally. Use these same credentials to log in next time. This will be replaced with real sign-up when the app uses a backend.")
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
