//
//  SectionSidebarView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

// Note: InspectionSection.ID must conform to Hashable for selection binding to work.

/// A reusable sidebar listing sections with issue counts. Can be used independently or within a split view.
struct SectionSidebarView: View {
    var sections: [InspectionSection]
    @Binding var selectedSectionID: UUID?
    var body: some View {
        List {
            ForEach(sections) { section in
                Button(action: { selectedSectionID = section.id }) {
                    sectionRow(section: section)
                }
                .buttonStyle(.plain)
                .listRowBackground(selectedSectionID == section.id ? Color.secondary.opacity(0.12) : Color.clear)
            }
        }
    }
    
    @ViewBuilder private func safetyBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2)
                .padding(4)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .clipShape(Circle())
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder private func majorBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2)
                .padding(4)
                .background(Color.orange.opacity(0.2))
                .foregroundColor(.orange)
                .clipShape(Circle())
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder private func marginalBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2)
                .padding(4)
                .background(Color.yellow.opacity(0.2))
                .foregroundColor(.yellow)
                .clipShape(Circle())
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder private func minorBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2)
                .padding(4)
                .background(Color.green.opacity(0.2))
                .foregroundColor(.green)
                .clipShape(Circle())
        } else {
            EmptyView()
        }
    }
    
    private func sectionRow(section: InspectionSection) -> some View {
        let safety = safetyBadge(section.safetyCount)
        let major = majorBadge(section.majorCount)
        let marginal = marginalBadge(section.marginalCount)
        let minor = minorBadge(section.minorCount)
        return HStack(alignment: .center, spacing: 4) {
            Text(section.title)
            Spacer()
            safety
            major
            marginal
            minor
        }
    }
}

struct SectionSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        let section1 = InspectionSection(title: "Roofing", items: [])
        let section2 = InspectionSection(title: "Plumbing", items: [])
        return SectionSidebarView(sections: [section1, section2], selectedSectionID: .constant(section1.id))
    }
}

