import SwiftUI

/// Shows the revision history of Terms & Conditions versions and user acceptance audit log.
public struct LegalHistoryView: View {
    public var auditLogText: String { AuditLog.read() }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Terms & Conditions Revision History")
                    .font(.title2).bold()
                    .accessibilityAddTraits(.isHeader)
                Text("Below is a history of all Terms & Conditions acceptance and updates, including app version and user identity for each action.")
                    .font(.body)
                    .foregroundColor(.secondary)
                Divider()
                Text(auditLogText)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Audit Log")
                    .padding(.vertical)
            }
            .padding()
        }
        .navigationTitle("T&C History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct LegalHistoryView_Previews: PreviewProvider {
    public static var previews: some View {
        NavigationStack { LegalHistoryView() }
    }
}
