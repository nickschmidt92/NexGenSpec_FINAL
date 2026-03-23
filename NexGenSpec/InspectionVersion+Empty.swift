import Foundation

extension InspectionVersion {
    /// An entirely empty placeholder (all default values).
    static var empty: InspectionVersion {
        InspectionVersion(
            id: UUID(),
            versionNumber: 0,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: Inspection(
                id: UUID(),
                clientName: "",
                propertyAddress: "",
                inspectionDate: .now,
                inspectorName: "",
                sections: [],
                inspectorConfirmed: false
            )
        )
    }
}
