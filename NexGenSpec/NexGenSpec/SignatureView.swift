//
//  SignatureView.swift
//  InspectIQ
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI
import UIKit

/// View for collecting inspector and client signatures. Stores the signatures into the inspection and executes completion when done.
struct SignatureView: View {
    @Binding var version: InspectionVersion
    var onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inspectorSignature: UIImage?
    @State private var clientSignature: UIImage?
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Inspector Signature")) {
                    SignaturePad(image: $inspectorSignature)
                        .frame(height: 200)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray))
                }
                Section(header: Text("Client / Real Estate Agent")) {
                    SignaturePad(image: $clientSignature)
                        .frame(height: 200)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray))
                }
            }
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
                    .disabled(inspectorSignature == nil || clientSignature == nil)
                }
            }
        }
    }

    private func saveSignatures() {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let deviceId = UIDevice.current.identifierForVendor?.uuidString
        var newSignatures: [InspectionSignature] = []
        if let inspector = inspectorSignature, let inspectorData = inspector.pngData() {
            let sigId = UUID()
            SignatureStore.saveImage(inspectorData, jobId: jobId, signatureId: sigId)
            let sig = InspectionSignature(id: sigId, name: version.inspection.inspectorName, imageFileName: "\(sigId.uuidString).png", date: Date(), deviceId: deviceId)
            newSignatures.append(sig)
        }
        if let client = clientSignature, let clientData = client.pngData() {
            let sigId = UUID()
            SignatureStore.saveImage(clientData, jobId: jobId, signatureId: sigId)
            let sig = InspectionSignature(id: sigId, name: version.inspection.clientName, imageFileName: "\(sigId.uuidString).png", date: Date(), deviceId: deviceId)
            newSignatures.append(sig)
        }
        var copy = version
        copy.inspection.signatures = newSignatures
        version = copy
    }
}

/// A reusable signature pad that allows freehand drawing. Once the drawing stops, the image is stored in the provided binding.
struct SignaturePad: View {
    @Binding var image: UIImage?
    @State private var currentDrawing: [CGPoint] = []
    @State private var drawings: [[CGPoint]] = []
    @State private var lineColor: Color = .black
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
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