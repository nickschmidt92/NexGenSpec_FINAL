import SwiftUI

/// A simple username/password login view. On success, calls authManager.login
struct LoginView: View {
    @ObservedObject var authManager: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var showingError = false
    @State private var showingCreateAccount = false

    var body: some View {
        VStack(spacing: 24) {
            Text("App Login")
                .font(.largeTitle)

            Text("Use an existing account. In DEBUG builds you can use owner/admin/testflight demo credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Log In") {
                if authManager.login(username: username, password: password) {
                    // Successful login
                } else {
                    showingError = true
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
            .accessibilityLabel("Log In")

            Button("Create new account") {
                showingCreateAccount = true
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)

            Text("This is demo-only login. Real authentication will replace this later.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top, 16)
        }
        .padding()
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
        guard !username.isEmpty else {
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
        if authManager.createAccount(username: username, password: password) {
            dismiss()
            onDismiss()
        } else {
            errorMessage = authManager.authErrorMessage ?? "Could not create account. Try a different username and password."
        }
    }
}
