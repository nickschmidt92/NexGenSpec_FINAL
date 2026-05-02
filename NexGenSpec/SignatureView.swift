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
    @State private var inspectorSignature: UIImage?
    @State private var clientSignature: UIImage?

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
                        saveSignatures()
                        onComplete()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 800)
        .presentationDetents([.large])
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
    private func saveSignatures() {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let deviceId = UIDevice.current.identifierForVendor?.uuidString
        var existing = version.inspection.signatures
        if !hasInspectorSignature, let inspector = inspectorSignature, let data = inspector.pngData() {
            let sigId = UUID()
            SignatureStore.saveImage(data, jobId: jobId, signatureId: sigId)
            existing.append(InspectionSignature(
                id: sigId,
                name: version.inspection.inspectorName,
                imageFileName: "\(sigId.uuidString).png",
                date: Date(),
                deviceId: deviceId
            ))
        }
        if !hasClientSignature, let client = clientSignature, let data = client.pngData() {
            let sigId = UUID()
            SignatureStore.saveImage(data, jobId: jobId, signatureId: sigId)
            existing.append(InspectionSignature(
                id: sigId,
                name: version.inspection.clientName,
                imageFileName: "\(sigId.uuidString).png",
                date: Date(),
                deviceId: deviceId
            ))
        }
        var copy = version
        copy.inspection.signatures = existing
        version = copy
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