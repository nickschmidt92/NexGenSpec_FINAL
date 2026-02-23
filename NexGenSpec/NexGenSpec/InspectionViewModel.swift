//
//  InspectionViewModel.swift
//  NexGenSpec
//

import Foundation
import Combine

@MainActor
public final class InspectionViewModel: ObservableObject {
    @Published public var version: InspectionVersion
    @Published public var selectedSectionID: UUID?
    @Published public var selectedItemID: UUID?
    @Published public var severityFilter: Set<Severity> = []

    public init(version: InspectionVersion) {
        self.version = version
        self.selectedSectionID = version.inspection.sections.first?.id
    }

    public var sections: [InspectionSection] {
        version.inspection.sections
    }

    public var selectedSection: InspectionSection? {
        sections.first { $0.id == selectedSectionID }
    }

    public var selectedItem: InspectionItem? {
        selectedSection?.items.first { $0.id == selectedItemID }
    }
}
