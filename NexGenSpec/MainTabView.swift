//
//  MainTabView.swift
//  NexGenSpec
//
//  Root post-auth UI: three-tab bar holding the existing Dashboard
//  (Workspace), the new Calendar, and Settings. Moving Settings into
//  its own tab (rather than a sheet launched from Dashboard) lets the
//  calendar preferences live next to the rest of the app-level config.
//

import SwiftUI

/// Names for programmatic tab switching, e.g. when an inspection-level
/// view needs to route the user to a sibling tab (Workspace → Calendar).
public enum MainTab: Hashable {
    case workspace
    case calendar
    case archived
    case settings
}

/// Shared router so any view inside the tab hierarchy can request a
/// tab switch. We keep it per-user-session — the instance is created
/// in `MainTabView` and passed down as an environment object.
@MainActor
public final class TabRouter: ObservableObject {
    @Published public var selected: MainTab = .workspace

    public init(initial: MainTab = .workspace) {
        self.selected = initial
    }

    public func show(_ tab: MainTab) {
        selected = tab
    }
}

struct MainTabView: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager

    @StateObject private var router = TabRouter()

    var body: some View {
        tabBody
    }

    private var tabBody: some View {
        TabView(selection: $router.selected) {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Workspace", systemImage: "square.grid.2x2.fill")
            }
            .tag(MainTab.workspace)

            NavigationStack {
                CalendarView()
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
            .tag(MainTab.calendar)

            NavigationStack {
                ArchivedInspectionsView()
            }
            .tabItem {
                Label("Archived", systemImage: "archivebox.fill")
            }
            .tag(MainTab.archived)

            NavigationStack {
                AppSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(MainTab.settings)
        }
        .environmentObject(router)
    }
}

#if DEBUG
#Preview {
    MainTabView()
        .environmentObject(InspectionStore())
        .environmentObject(AuthManager())
        .environmentObject(SubscriptionManager())
        .environmentObject(SyncCoordinator())
}
#endif
