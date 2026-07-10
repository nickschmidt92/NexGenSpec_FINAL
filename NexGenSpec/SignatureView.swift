//
//  SignatureView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI
import UIKit

/// View for collecting inspector and client signatures. Stores the signatures into the inspection and executes completion when done.
///
/// Signature lock policy (beta feedback 2026-04-22): once a signature is
/// saved it cannot be replaced. This view only asks for signatures the
/// inspection doesn't already have. Existing signatures render as
/// read-only rows with a "LOCKED" badge. That makes the signature page
/// a legally-defensible record of who signed and when, rather than a
/// blank slate that any future editor could overwrite.
struct SignatureView: View {
    @Binding var version: InspectionVersion
    var onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    // Gate the comfortable iPad/Mac sheet size to the regular width class.
    // Forcing minWidth:720 on a compact-width iPhone rammed the Form to
    // 720pt inside a ~390pt sheet → the layout blew out horizontally.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var inspectorSignature: UIImage?
    @State private var clientSignature: UIImage?
    @State private var showSaveError = false

    private var hasInspectorSignature: Bool {
        version.inspection.signatures.contains { $0.name == version.inspection.inspectorName && !version.inspection.inspectorName.isEmpty }
    }
    private var hasClientSignature: Bool {
        // Anything that isn't the inspector counts as "client-side" here.
        version.inspection.signatures.contains { $0.name != version.inspection.inspectorName }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Inspector Signature")) {
                    if hasInspectorSignature {
                        lockedSignatureRow(name: version.inspection.inspectorName)
                    } else {
                        SignaturePad(image: $inspectorSignature)
                            .frame(height: 150)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppColor.border))
                    }
                }
                // Disclaimer lives on the second section's footer rather
                // than its own empty section. Reclaims ~60pt so both pads
                // fit on iPad without scrolling, while keeping the legal
                // disclosure visible above the Done button.
                Section(
                    header: Text("Client / Real Estate Agent"),
                    footer: Text("Signatures become a permanent part of the inspection record. Once saved, they cannot be cleared or re-signed within the app.")
                        .font(.footnote)
                ) {
                    if hasClientSignature {
                        lockedSignatureRow(name: clientSignatureName)
                    } else {
                        SignaturePad(image: $clientSignature)
                            .frame(height: 150)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppColor.border))
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Signatures")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if saveSignatures() {
                            onComplete()
                            dismiss()
                        } else {
                            // A signature failed to write — the pad stays
                            // unlocked. Keep the sheet open so the user can retry
                            // rather than finalizing a record with a missing sig.
                            showSaveError = true
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(
            minWidth: hSizeClass == .regular ? 720 : nil,
            minHeight: hSizeClass == .regular ? 800 : nil
        )
        .presentationDetents([.large])
        .alert("Couldn't Save Signature", isPresented: $showSaveError) {
            Button("OK") { showSaveError = false }
        } message: {
            Text("The signature couldn't be saved to this device. Please try signing again.")
        }
    }

    /// Enabled only when the user has provided what's still needed.
    private var canSave: Bool {
        let needInspector = !hasInspectorSignature
        let needClient = !hasClientSignature
        if needInspector && inspectorSignature == nil { return false }
        if needClient && clientSignature == nil { return false }
        return needInspector || needClient
    }

    private var clientSignatureName: String {
        version.inspection.signatures
            .first(where: { $0.name != version.inspection.inspectorName })?.name
            ?? "Client"
    }

    @ViewBuilder
    private func lockedSignatureRow(name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                if let sig = version.inspection.signatures.first(where: { $0.name == name }) {
                    Text("Signed \(sig.date, formatter: DateFormatters.mediumDateTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("LOCKED")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Appends new signatures without disturbing existing ones. Only fires
    /// for roles that are currently missing — the UI already prevents the
    /// user from drawing over a locked pad.
    ///
    /// Records (and thereby locks) a signature ONLY if its image actually
    /// saved to disk. A failed encode/write leaves the pad unlocked and
    /// returns false so the caller can alert and let the user retry, instead
    /// of locking a signature whose file is missing from the final report.
    /// Returns true only if every signature the user provided was persisted.
    private func saveSignatures() -> Bool {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let deviceId = UIDevice.current.identifierForVendor?.uuidString
        var existing = version.inspection.signatures
        var allSaved = true
        if !hasInspectorSignature, let inspector = inspectorSignature {
            let sigId = UUID()
            if let data = inspector.pngData(),
               SignatureStore.saveImage(data, jobId: jobId, signatureId: sigId) {
                existing.append(InspectionSignature(
                    id: sigId,
                    name: version.inspection.inspectorName,
                    imageFileName: "\(sigId.uuidString).png",
                    date: Date(),
                    deviceId: deviceId
                ))
            } else {
                allSaved = false
            }
        }
        if !hasClientSignature, let client = clientSignature {
            let sigId = UUID()
            if let data = client.pngData(),
               SignatureStore.saveImage(data, jobId: jobId, signatureId: sigId) {
                existing.append(InspectionSignature(
                    id: sigId,
                    name: version.inspection.clientName,
                    imageFileName: "\(sigId.uuidString).png",
                    date: Date(),
                    deviceId: deviceId
                ))
            } else {
                allSaved = false
            }
        }
        var copy = version
        copy.inspection.signatures = existing
        version = copy
        return allSaved
    }
}

/// A reusable signature pad that allows freehand drawing. Once the drawing stops, the image is stored in the provided binding.
struct SignaturePad: View {
    @Binding var image: UIImage?
    @State private var currentDrawing: [CGPoint] = []
    @State private var drawings: [[CGPoint]] = []
    @State private var lineColor: Color = Color(uiColor: .label)
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppColor.elevatedSurface
                Path { path in
                    for drawing in drawings {
                        guard let first = drawing.first else { continue }
                        path.move(to: first)
                        for point in drawing.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    if let first = currentDrawing.first {
                        path.move(to: first)
                        for point in currentDrawing.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(lineColor, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    currentDrawing.append(value.location)
                }
                .onEnded { _ in
                    drawings.append(currentDrawing)
                    currentDrawing = []
                    // Render image
                    let renderer = UIGraphicsImageRenderer(size: geometry.size)
                    let rendered = renderer.image { ctx in
                        ctx.cgContext.setFillColor(UIColor.white.cgColor)
                        ctx.cgContext.fill(CGRect(origin: .zero, size: geometry.size))
                        ctx.cgContext.setStrokeColor(UIColor.black.cgColor)
                        ctx.cgContext.setLineWidth(2)
                        for drawing in drawings {
                            guard let first = drawing.first else { continue }
                            ctx.cgContext.beginPath()
                            ctx.cgContext.move(to: first)
                            for point in drawing.dropFirst() {
                                ctx.cgContext.addLine(to: point)
                            }
                            ctx.cgContext.strokePath()
                        }
                    }
                    image = rendered
                }
            )
        }
    }
}

struct SignatureView_Previews: PreviewProvider {
    static var previews: some View {
        let inspection = Inspection(clientName: "", propertyAddress: "", inspectionDate: Date(), inspectorName: "", sections: [])
        let version = InspectionVersion(versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        SignatureView(version: .constant(version)) { }
    }
}