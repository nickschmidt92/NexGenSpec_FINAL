//
//  FinalizeView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

/// Presents a confirmation screen before locking the inspection. Shows collected signatures and summary counts.
/// Does not mutate version; calls onFinalize(version) so the store performs the state transition via InspectionStateMachine.
struct FinalizeView: View {
    @Binding var version: InspectionVersion
    /// Callback to perform finalization (e.g. store.finalize(version)). Store enforces state machine.
    var onFinalize: (InspectionVersion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showSignatureSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Summary")) {
                    let counts = version.inspection.summaryCounts()
                    HStack {
                        Text("Safety: \(counts.safety)")
                        Spacer()
                        Text("Major: \(counts.major)")
                        Spacer()
                        Text("Marginal: \(counts.marginal)")
                        Spacer()
                        Text("Minor: \(counts.minor)")
                    }
                }
                Section(header: Text("Signatures")) {
                    ForEach(version.inspection.signatures) { sig in
                        HStack {
                            Text(sig.name)
                            Spacer()
                            Text("\(sig.date, formatter: DateFormatters.mediumDateTime)")
                        }
                    }
                    if version.inspection.signatures.count < 2 {
                        Button {
                            showSignatureSheet = true
                        } label: {
                            Label("Collect Signatures", systemImage: "signature")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .disabled(!version.state.isEditable)
                        Text("Inspector and client / real estate agent must sign before finalizing.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button {
                            showSignatureSheet = true
                        } label: {
                            Label("Update Signatures", systemImage: "signature")
                        }
                    }
                }
                Section {
                    Button(action: finalize) {
                        Text("Finalize & Lock")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(!version.state.isEditable || version.inspection.signatures.count < 2)
                    .accessibilityLabel("Finalize and lock inspection")
                    .accessibilityHint("Requires both signatures. Cannot be undone.")
                }
            }
            .navigationTitle("Finalize Inspection")
            .accessibilityLabel("Finalize inspection")
            .accessibilityHint("Collect signatures and lock report. Requires both inspector and client signatures.")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showSignatureSheet) {
                SignatureView(version: $version) {
                    showSignatureSheet = false
                }
            }
        }
    }

    /// Request finalization; store performs transition. View does not mutate state.
    private func finalize() {
        onFinalize(version)
        dismiss()
    }
}

struct FinalizeView_Previews: PreviewProvider {
    static var previews: some View {
        var inspection = Inspection(clientName: "", propertyAddress: "", inspectionDate: Date(), inspectorName: "", sections: [], inspectorConfirmed: false)
        let signature = InspectionSignature(name: "Inspector", imageData: Data(), date: Date())
        inspection.signatures = [signature]
        let version = InspectionVersion(versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        return FinalizeView(version: .constant(version)) { _ in }
    }
}
