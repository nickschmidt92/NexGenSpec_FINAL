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
