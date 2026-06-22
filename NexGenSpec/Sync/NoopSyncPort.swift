//
//  NoopSyncPort.swift
//  NexGenSpec
//
//  The inert SyncPort used whenever sync must not run: feature flag OFF,
//  local-only mode, or no iCloud account. Every method is a no-op and status is
//  always `.off` (the factory substitutes `.localOnly` semantics at a higher
//  level when appropriate). This type is what makes "flag OFF == build 21"
//  provable — it does literally nothing.
//

import Foundation

public final class NoopSyncPort: SyncPort {

    public init() {}

    public var status: SyncStatus { .off }

    public func bind(firebaseUID: String) async {}

    public func unbind() {}

    public func recordLocalChange(_ change: SyncChange) {}

    public func seedIfNeeded(firebaseUID: String) async {}

    public func pull() async {}

    public func flushPending() async {}
}
