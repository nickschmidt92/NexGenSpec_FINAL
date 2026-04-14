//
//  OpenNexGenSpecIntent.swift
//  NexGenSpec
//
//  Minimal AppIntent so the AppIntents metadata processor has something to
//  extract (silences the "Metadata extraction skipped" build warning) and
//  exposes "Open NexGenSpec" as a Siri / Shortcuts action for free.
//

import AppIntents

struct OpenNexGenSpecIntent: AppIntent {
    static let title: LocalizedStringResource = "Open NexGenSpec"
    static let description = IntentDescription("Opens the NexGenSpec inspection app.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct NexGenSpecShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNexGenSpecIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)"
            ],
            shortTitle: "Open NexGenSpec",
            systemImageName: "doc.text.magnifyingglass"
        )
    }
}
