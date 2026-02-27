Section(header: Text("Legal")) {
    NavigationLink(destination: TermsAndConditionsView()) {
        Text("Privacy Policy")
            .accessibilityLabel("Privacy Policy")
    }
    NavigationLink(destination: TermsAndConditionsView()) {
        Text("Terms of Service")
            .accessibilityLabel("Terms of Service")
    }
    NavigationLink(destination: DataSafetyView()) {
        Text("Data Safety Summary")
            .accessibilityLabel("Data Safety Summary")
    }
}
.navigationTitle("Settings")
// MARK: - Admin Section

/// A section visible only to admin users, showing admin-related navigation options.
struct SettingsAdminSection: View {
    var body: some View {
        // Show only if user is admin
        if AuthManager.shared.isAdmin {
            Section(header: Text("Admin")) {
                NavigationLink(destination: FeedbackLogView()) {
                    Text("View Feedback Log")
                }
            }
        }
    }
}

/// View displaying the audit log in a scrollable, selectable Text view
struct FeedbackLogView: View {
    private let auditLogText: String = AuditLog.read()
    
    var body: some View {
        ScrollView {
            Text(auditLogText)
                .padding()
                .textSelection(.enabled) // Allows text to be selected and copied
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Feedback Log")
    }
}

/*
 Integration:

 To include the `SettingsAdminSection` in your main Settings view, embed it inside the same Form or List as your other sections, for example:

 Form {
     // Existing settings sections
     Section(header: Text("Legal")) { ... }

     // Add the admin section below, it will only appear for admins
     SettingsAdminSection()
 }

 This ensures the admin section is only visible to users with admin privileges (`AuthManager.shared.isAdmin == true`).

 Make sure your Settings view is embedded in a NavigationView or NavigationStack for proper navigation behavior.
*/

