import SwiftUI
import AuthenticationServices

/// Email/password login with Firebase-backed AuthManager.
/// Adds Forgot Password flow and live password complexity hints.
/// Sign in with Apple lands in Step 3.
struct LoginView: View {
    @ObservedObject var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var showingError = false
    @State private var showingCreateAccount = false
    @State private var showingForgotPassword = false
    @State private var forgotPasswordEmail = ""
    @State private var forgotPasswordInfo: String?
    @FocusState private var focusedField: LoginField?

    private enum LoginField {
        case email
        case password
    }

    var body: some View {
        ZStack {
            AppColor.brandNavy
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Spacing.xl) {
                    VStack(spacing: Spacing.md) {
                        if UIImage(named: "NexGenSpecLogo") != nil {
                            Image("NexGenSpecLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .accessibilityLabel("NexGenSpec Logo")
                        } else {
                            BrandMark(size: 80)
                            Text("NexGenSpec")
                                .font(AppFont.hero)
                                .foregroundStyle(.white)
                                .kerning(-1.2)
                        }
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.xl)

                    VStack(spacing: Spacing.lg) {
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Sign In")
                                    .font(AppFont.title2)
                                    .foregroundStyle(.white)

                                Text("Use your NexGenSpec account email and password.")
                                    .font(AppFont.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            VStack(spacing: Spacing.md) {
                                LoginDarkField(title: "Email", systemImage: "envelope.fill") {
                                    TextField("you@example.com", text: $email)
                                        .textInputAutocapitalization(.never)
                                        .keyboardType(.emailAddress)
                                        .textContentType(.username)
                                        .autocorrectionDisabled()
                                        .submitLabel(.next)
                                        .focused($focusedField, equals: .email)
                                        .onSubmit { focusedField = .password }
                                        .foregroundStyle(.white)
                                }

                                LoginDarkField(title: "Password", systemImage: "lock.fill") {
                                    SecureField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .textContentType(.password)
                                        .submitLabel(.go)
                                        .focused($focusedField, equals: .password)
                                        .onSubmit { attemptLogin() }
                                        .foregroundStyle(.white)
                                }
                            }

                            Button {
                                attemptLogin()
                            } label: {
                                if authManager.isBusy {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Log In")
                                }
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .disabled(authManager.isBusy)
                            .accessibilityLabel("Log In")

                            HStack(spacing: Spacing.sm) {
                                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                                Text("or").font(AppFont.footnote).foregroundStyle(.white.opacity(0.5))
                                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                            }

                            Button {
                                attemptAppleSignIn()
                            } label: {
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "applelogo")
                                    Text("Sign in with Apple")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .foregroundStyle(AppColor.brandNavy)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .disabled(authManager.isBusy)
                            .accessibilityLabel("Sign in with Apple")

                            HStack {
                                Button("Forgot password?") {
                                    forgotPasswordEmail = email
                                    forgotPasswordInfo = nil
                                    showingForgotPassword = true
                                }
                                .font(AppFont.footnote)
                                .foregroundStyle(.white.opacity(0.6))

                                Spacer()

                                Button("Create new account") {
                                    showingCreateAccount = true
                                }
                                .font(AppFont.footnote)
                                .foregroundStyle(AppColor.brandCyan)
                            }
                        }
                        .padding(Spacing.lg)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
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
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordSheet(
                authManager: authManager,
                email: $forgotPasswordEmail,
                info: $forgotPasswordInfo
            ) {
                showingForgotPassword = false
            }
        }
        .onAppear {
            focusedField = .email
        }
    }

    private func attemptLogin() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let ok = await authManager.login(email: trimmed, password: password)
            if ok {
                email = trimmed
                password = ""
            } else {
                showingError = true
            }
        }
    }

    private func attemptAppleSignIn() {
        Task { @MainActor in
            let ok = await authManager.signInWithApple()
            if !ok && authManager.authErrorMessage != nil {
                showingError = true
            }
        }
    }
}

// MARK: - Forgot password sheet

private struct ForgotPasswordSheet: View {
    @ObservedObject var authManager: AuthManager
    @Binding var email: String
    @Binding var info: String?
    var onDismiss: () -> Void

    @State private var localError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                } header: {
                    Text("Reset your password")
                } footer: {
                    Text("We’ll send a password reset link to this email.")
                }

                if let info {
                    Section {
                        Text(info).foregroundStyle(.green).font(.caption)
                    }
                }
                if let localError {
                    Section {
                        Text(localError).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Forgot Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss(); onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Link") { sendLink() }
                        .disabled(authManager.isBusy)
                }
            }
        }
    }

    private func sendLink() {
        localError = nil
        info = nil
        Task { @MainActor in
            let ok = await authManager.sendPasswordReset(email: email)
            if ok {
                info = "Password reset link sent. Check your inbox."
            } else {
                localError = authManager.authErrorMessage ?? "Could not send reset link."
            }
        }
    }
}

// MARK: - Create account

private struct CreateAccountView: View {
    @ObservedObject var authManager: AuthManager
    var onDismiss: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var passwordComplaint: String? {
        password.isEmpty ? nil : AuthManager.validatePassword(password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                } header: {
                    Text("Create your NexGenSpec account")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password must be at least 12 characters and include an uppercase letter, a lowercase letter, a number, and a symbol.")
                        if let passwordComplaint {
                            Text(passwordComplaint).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createAccount() }
                        .disabled(authManager.isBusy)
                }
            }
        }
    }

    private func createAccount() {
        errorMessage = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter an email address."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        Task { @MainActor in
            let ok = await authManager.createAccount(email: trimmed, password: password)
            if ok {
                dismiss()
                onDismiss()
            } else {
                errorMessage = authManager.authErrorMessage ?? "Could not create account."
            }
        }
    }
}

// MARK: - Reusable UI bits (unchanged from previous version)

private struct LoginDarkField<Content: View>: View {
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
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppColor.brandCyan)
                    .frame(width: 20)

                content
                    .font(AppFont.body)
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 54)
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
