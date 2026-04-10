//
//  ItemListView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

/// Displays a list of items within a section. Selecting an item highlights it and sets the selection binding.
struct ItemListView: View {
    var items: [InspectionItem]
    @Binding var selectedItemID: InspectionItem.ID?
    var body: some View {
        List(selection: $selectedItemID) {
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.status.displayName)
                            .font(.caption)
                            .foregroundColor(item.isDefect ? .red : .secondary)
                    }
                    Spacer()
                    if let sev = item.defectSeverity {
                        Text(sev.displayName)
                            .font(.caption)
                            .padding(4)
                            .background(sev.badgeColor.opacity(0.2))
                            .foregroundColor(sev.badgeColor)
                            .clipShape(Capsule())
                    }
                }
                .tag(item.id)
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ItemListView_Previews: PreviewProvider {
    static var previews: some View {
        let item1 = InspectionItem(templateItemId: "test1", title: "Leak", includeInReport: true, status: .inspected, defectSeverity: .major, location: "", observed: "", implication: "", recommendation: "", contractorTag: "", photos: [])
        let item2 = InspectionItem(templateItemId: "test2", title: "Crack", includeInReport: true, status: .inspected, defectSeverity: nil, location: "", observed: "", implication: "", recommendation: "", contractorTag: "", photos: [])
        ItemListView(items: [item1, item2], selectedItemID: .constant(nil))
    }
}
