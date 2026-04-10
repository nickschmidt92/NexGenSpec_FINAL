//
//  SectionDetailView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

/// Displays the items for a particular section in a list of cards. Selecting a card reveals its detail in the detail column.
/// If `onItemTap` is provided, each row is a button that triggers the closure when tapped instead of the default selection behavior.
struct SectionDetailView: View {
    @Binding var section: InspectionSection
    @ObservedObject var viewModel: InspectionViewModel
    var onItemTap: ((UUID) -> Void)? = nil
    
    var body: some View {
        List(selection: $viewModel.selectedItemID) {
            ForEach(section.items) { item in
                if let onItemTap = onItemTap {
                    Button(action: { onItemTap(item.id) }) {
                        ItemCardView(item: item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                } else {
                    ItemCardView(item: item)
                        .listRowInsets(EdgeInsets())
                        .onTapGesture {
                            viewModel.selectedItemID = item.id
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(section.title)
    }
}

/// Represents a card summarising an inspection item.
private struct ItemCardView: View {
    let item: InspectionItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.title)
                    .font(.headline)
                Spacer()
                if let sev = item.defectSeverity {
                    Text(sev.displayName)
                        .font(.caption)
                        .padding(4)
                        .background(AppColor.forSeverity(sev).opacity(0.2))
                        .foregroundColor(AppColor.forSeverity(sev))
                        .clipShape(Capsule())
                }
            }
            HStack {
                Text(item.status.displayName)
                    .font(.caption)
                    .foregroundColor(item.isDefect ? .red : .secondary)
                Spacer()
                Image(systemName: item.includeInReport ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(item.includeInReport ? .green : .gray)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }
}

struct SectionDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let item = InspectionItem(
            templateItemId: "preview",
            title: "Roof Leak",
            status: .inspected,
            defectSeverity: .major,
            location: "Roof",
            observed: "Leak near chimney",
            implication: "Potential water damage",
            recommendation: "Repair roof flashing",
            contractorTag: "Roofing Contractor",
            photos: []
        )
        let section = InspectionSection(title: "Roofing", items: [item])
        let version = InspectionVersion(versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: Inspection(clientName: "", propertyAddress: "", inspectionDate: Date(), inspectorName: "", sections: [section], inspectorConfirmed: false))
        let viewModel = InspectionViewModel(version: version)
        return SectionDetailView(section: .constant(section), viewModel: viewModel)
    }
}
