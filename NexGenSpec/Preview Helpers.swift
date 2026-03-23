#if DEBUG
import SwiftUI

/// Convenience wrapper: injects a store into the environment and
/// hands it to the closure so you can tweak sample data.
struct WithStore<Content: View>: View {
    @StateObject private var store = InspectionStore()
    let content: (InspectionStore) -> Content

    var body: some View { content(store).environmentObject(store) }
}
#endif
