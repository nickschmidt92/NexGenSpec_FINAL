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
                Section(
                    header: Text("Sections in Report"),
                    footer: Text("Sections with no defects reported (orange) will be omitted from the PDF. If a section is missing, it will not appear in the report. Review before finalizing.")
                        .font(.footnote)
                ) {
                    ForEach(version.inspection.sections) { section in
                        let defectCount = section.items.filter { $0.isDefect && $0.includeInReport }.count
                        HStack(spacing: 10) {
                            Image(systemName: defectCount > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(defectCount > 0 ? .green : .orange)
                            Text(section.title)
                            Spacer()
                            Text("\(defectCount) defect\(defectCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(section.title), \(defectCount) defect\(defectCount == 1 ? "" : "s")")
                    }
                }
                Section(
                    header: Text("Signatures"),
                    footer: signaturesFooter
                ) {
                    ForEach(version.inspection.signatures) { sig in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sig.name).font(.subheadline.weight(.semibold))
                                Text("\(sig.date, formatter: DateFormatters.mediumDateTime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("LOCKED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if version.inspection.signatures.count < 2 {
                        Button {
                            showSignatureSheet = true
                        } label: {
                            Label(
                                version.inspection.signatures.isEmpty
                                    ? "Collect Signatures"
                                    : "Add Remaining Signature",
                                systemImage: "signature"
                            )
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .disabled(!version.state.isEditable)
                    }
                }
                Section(
                    footer: Text("Once you finalize, the report is locked. Defect entries, photos, notes, and signatures cannot be altered after this point. Make sure everything looks right above before tapping Finalize & Lock.")
                        .font(.footnote)
                ) {
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

    @ViewBuilder
    private var signaturesFooter: some View {
        if version.inspection.signatures.isEmpty {
            Text("Inspector and client / real estate agent must sign before finalizing. Signatures are locked once saved and become part of the permanent record.")
                .font(.footnote)
        } else if version.inspection.signatures.count < 2 {
            Text("One signature on file. Add the remaining signature to enable Finalize & Lock. Signatures cannot be modified after they are saved.")
                .font(.footnote)
        } else {
            Text("Both signatures captured. They are locked and will appear on the final PDF alongside a SHA-256 verification hash.")
                .font(.footnote)
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
