//
//  FirebaseBootstrap.swift
//  NexGenSpec
//
//  Configures Firebase exactly once at app launch.
//  Called from NexGenSpecApp.init() before any Firebase API is touched.
//

import Foundation
import FirebaseCore

enum FirebaseBootstrap {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        // FirebaseApp.configure() reads GoogleService-Info.plist from the app bundle.
        // If the plist is missing the app will crash here, which is the behavior we want —
        // shipping without the plist would silently disable auth.
        FirebaseApp.configure()
    }
}
