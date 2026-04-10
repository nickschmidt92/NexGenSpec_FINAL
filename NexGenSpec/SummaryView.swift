//
//  SummaryView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

/// Displays a summary of all defect items across an inspection with filtering by severity and search.
struct SummaryView: View {
    @ObservedObject var viewModel: InspectionViewModel
    @State private var searchText: String = ""
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                ForEach(Severity.allCases) { severity in
                    SeverityFilterButton(severity: severity, isSelected: viewModel.severityFilter.contains(severity)) {
                        toggleFilter(severity)
                    }
                }
            }
            .padding([.top, .horizontal])
            // Search bar
            TextField("Search", text: $searchText)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)
                .onChange(of: searchText) { _, _ in }
            List(filteredDefects()) { record in
                VStack(alignment: .leading) {
                    HStack {
                        Text(record.item.title)
                            .font(.headline)
                        Spacer()
                        if let sev = record.item.defectSeverity {
                            Text(sev.displayName)
                                .font(.caption)
                                .padding(4)
                                .background(AppColor.forSeverity(sev).opacity(0.2))
                                .foregroundColor(AppColor.forSeverity(sev))
                                .clipShape(Capsule())
                        }
                    Text("Section: \(record.section.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
                .onTapGesture {
                    // Navigate to section and item detail
                    viewModel.selectedSectionID = record.section.id
                    viewModel.selectedItemID = record.item.id
                    // set summary filter to none to avoid interfering
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Summary")
    }

    /// Returns the list of items that are defects and match selected severities and search.
    private func filteredDefects() -> [DefectRecord] {
        var results: [DefectRecord] = []
        for section in viewModel.version.inspection.sections {
            for item in section.items where item.isDefect {
                // Filter by severity
                if !viewModel.severityFilter.isEmpty, let sev = item.defectSeverity, !viewModel.severityFilter.contains(sev) { continue }
                // Filter by search text
                if !searchText.isEmpty && !(item.title.localizedCaseInsensitiveContains(searchText) || item.observed.localizedCaseInsensitiveContains(searchText) || item.recommendation.localizedCaseInsensitiveContains(searchText)) {
                    continue
                }
                results.append(DefectRecord(section: section, item: item))
            }
        }
        return results
    }

    /// Toggles a severity filter.
    private func toggleFilter(_ severity: Severity) {
        if viewModel.severityFilter.contains(severity) {
            viewModel.severityFilter.remove(severity)
        } else {
            viewModel.severityFilter.insert(severity)
        }
    }
}

private struct SeverityFilterButton: View {
    let severity: Severity
    var isSelected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(severity.displayName)
                    .font(.caption)
                    .padding(6)
                    .background(isSelected ? AppColor.forSeverity(severity).opacity(0.2) : Color(.systemGray5))
                    .foregroundColor(isSelected ? AppColor.forSeverity(severity) : .primary)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(severity.displayName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DefectRecord: Identifiable {
    var id: String { section.id.uuidString + "-" + item.id.uuidString }
    let section: InspectionSection
    let item: InspectionItem
}

struct SummaryView_Previews: PreviewProvider {
    static var previews: some View {
        // Create sample data
        let item1 = InspectionItem(templateItemId: "preview1", title: "GFCI Missing", status: .inspected, defectSeverity: .safety, location: "Kitchen", observed: "No GFCI outlet", implication: "Shock hazard", recommendation: "Install GFCI", contractorTag: "Electrician", photos: [])
        let item2 = InspectionItem(templateItemId: "preview2", title: "Loose Handrail", status: .inspected, defectSeverity: .minor, location: "Stairs", observed: "Loose mounting", implication: "Tripping hazard", recommendation: "Secure handrail", contractorTag: "Carpenter", photos: [])
        let section1 = InspectionSection(title: "Electrical", items: [item1])
        let section2 = InspectionSection(title: "Interior", items: [item2])
        let inspection = Inspection(clientName: "", propertyAddress: "", inspectionDate: Date(), inspectorName: "", sections: [section1, section2], inspectorConfirmed: false)
        let version = InspectionVersion(versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        let vm = InspectionViewModel(version: version)
        return SummaryView(viewModel: vm)
    }
}
