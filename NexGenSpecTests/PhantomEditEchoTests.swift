//
//  PhantomEditEchoTests.swift
//  NexGenSpecTests
//
//  Phantom-edit echo regression coverage (B-0122 round 3).
//
//  The defect: InspectionView starts the session timer on every editable open
//  and BOTH teardown paths (onDisappear / willResignActive) call pauseTimer()
//  BEFORE the build-38 dirty check — the timer fold mutates
//  `timerElapsedSeconds`, so `draft != lastPersistedDraft` passed on every
//  open→close and the full flush re-stamped the LWW clock and pushed. Merely
//  VIEWING an inspection claimed authorship; a receiver closing a stale copy
//  echoed it over the zone with a newer clock, overwriting the editor's real
//  edits ("whoever closes last wins"). The weather auto-fetch on open was a
//  second phantom source, and mid-open it also clobbered freshly-applied
//  remote content on disk via the per-keystroke file-only autosave.
//
//  Covered here:
//    1. The `syncContentEquals` matrix — bookkeeping-only diffs (timer fields,
//       weather) compare equal; any content diff compares unequal.
//    2. The store-level clock backstop — `writeVersionFileOnlyForAutoSave`
//       refuses a copy whose LWW clock is strictly older than the
//       authoritative row's, and proceeds on equal clocks.
//    3. The receiver-open-during-pull scenario at the store seam:
//       applyRemoteVersion(newer content) followed by a stale file-only write
//       leaves the applied content on disk.
//

import XCTest
@testable import NexGenSpec

final class PhantomEditEchoTests: XCTestCase {

    // MARK: - Fixtures

    /// Fixed clocks, strictly ordered, far in the past so they are always
    /// strictly OLDER than any live `Date()` stamp the store writes.
    private let tStale = Date(timeIntervalSince1970: 1_700_000_100)

    private func makeVersion(id: UUID = UUID()) -> InspectionVersion {
        let item = InspectionItem(
            templateItemId: "roof-shingles",
            title: "Shingles",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major
        )
        let section = InspectionSection(id: UUID(), title: "Roof", items: [item])
        let inspection = Inspection(
            id: id,
            clientName: "Echo Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "1 Phantom Way",
            inspectionDate: Date(timeIntervalSince1970: 1_690_000_000),
            inspectorName: "Inspector",
            sections: [section]
        )
        return InspectionVersion(
            id: id, versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, inspection: inspection
        )
    }

    private func makeWeather() -> WeatherData {
        WeatherData(temperature: 72, conditions: "Sunny", humidity: 40,
                    windSpeed: 5, capturedAt: Date(timeIntervalSince1970: 1_690_000_500))
    }

    /// Asserts the two copies genuinely DIFFER by full equality (so the case is
    /// real) but compare equal by sync content — in both directions.
    private func assertBookkeepingOnly(_ a: InspectionVersion, _ b: InspectionVersion,
                                       _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(a, b, "\(what): fixture must be a real value diff", file: file, line: line)
        XCTAssertTrue(a.syncContentEquals(b), "\(what) must be bookkeeping-only", file: file, line: line)
        XCTAssertTrue(b.syncContentEquals(a), "\(what) must be symmetric", file: file, line: line)
    }

    private func assertContentDiff(_ a: InspectionVersion, _ b: InspectionVersion,
                                   _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(a.syncContentEquals(b), "\(what) is a REAL content change", file: file, line: line)
        XCTAssertFalse(b.syncContentEquals(a), "\(what) must be symmetric", file: file, line: line)
    }

    // MARK: - 1. syncContentEquals matrix — bookkeeping-only diffs are equal

    func testIdenticalCopiesAreSyncContentEqual() {
        let a = makeVersion()
        XCTAssertTrue(a.syncContentEquals(a))
    }

    func testTimerElapsedOnlyDiffIsSyncContentEqual() {
        let a = makeVersion()
        var b = a
        // pauseTimer() on teardown: folds the open session into the total.
        b.inspection.timerElapsedSeconds += 37
        assertBookkeepingOnly(a, b, "timerElapsedSeconds-only diff")
    }

    func testTimerStartDateOnlyDiffIsSyncContentEqual() {
        let a = makeVersion()
        var b = a
        // startTimer() on first open: seeds the start date when nil.
        b.inspection.timerStartDate = Date(timeIntervalSince1970: 1_690_000_400)
        assertBookkeepingOnly(a, b, "timerStartDate-only diff")
    }

    func testWeatherOnlyDiffIsSyncContentEqual() {
        let a = makeVersion()
        var b = a
        // The auto-fetch on open: seeds weather when nil.
        b.inspection.weather = makeWeather()
        assertBookkeepingOnly(a, b, "weather-only diff")
    }

    func testUpdatedAtOnlyDiffIsSyncContentEqual() {
        let a = makeVersion()
        var b = a
        // The version-level LWW clock is stamped BY writes — it is
        // bookkeeping by definition, never content.
        b.updatedAt = Date(timeIntervalSince1970: 1_690_000_600)
        assertBookkeepingOnly(a, b, "updatedAt-only diff (LWW clock)")
    }

    func testAllThreeBookkeepingDiffsCombinedAreSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.timerElapsedSeconds += 120
        b.inspection.timerStartDate = Date(timeIntervalSince1970: 1_690_000_400)
        b.inspection.weather = makeWeather()
        b.updatedAt = Date(timeIntervalSince1970: 1_690_000_600)
        assertBookkeepingOnly(a, b, "combined timer+weather+clock diff (the full open→close phantom)")
    }

    // MARK: - 1b. syncContentEquals matrix — content diffs are NOT equal

    func testClientNameDiffIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.clientName = "Renamed Client"
        assertContentDiff(a, b, "clientName diff")
    }

    func testItemTitleDiffIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.sections[0].items[0].title = "Flashing"
        assertContentDiff(a, b, "item title diff")
    }

    func testDefectSeverityDiffIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.sections[0].items[0].defectSeverity = .safety
        assertContentDiff(a, b, "defectSeverity diff")
    }

    func testIncludeInReportDiffIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.sections[0].items[0].includeInReport = false
        assertContentDiff(a, b, "includeInReport diff")
    }

    func testAddedItemIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.sections[0].items.append(
            InspectionItem(templateItemId: "roof-gutters", title: "Gutters")
        )
        assertContentDiff(a, b, "added item")
    }

    func testAddedSectionIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        b.inspection.sections.append(InspectionSection(id: UUID(), title: "Attic", items: []))
        assertContentDiff(a, b, "added section")
    }

    func testBookkeepingPlusContentDiffIsNotSyncContentEqual() {
        let a = makeVersion()
        var b = a
        // The realistic mixed close: timer folded AND the user actually edited.
        b.inspection.timerElapsedSeconds += 300
        b.inspection.weather = makeWeather()
        b.inspection.clientName = "Really Edited Client"
        assertContentDiff(a, b, "combined bookkeeping+content diff")
    }

    // MARK: - Store-level fixtures

    /// Stashes the real on-disk store aside for the duration of the test and
    /// restores it in teardown — same hygiene as SyncRoundTripRegressionTests.
    private func stashRealStoreAside() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        let stash = fm.temporaryDirectory.appendingPathComponent("ngs-phantom-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stash, withIntermediateDirectories: true)
        let inspectionsDir = FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true)
        let stashedPairs: [(name: String, live: URL)] = [
            ("Inspections", inspectionsDir),
            ("inspections.json", FilePaths.inspectionsIndex),
            ("inspections.json.backup", FilePaths.inspectionsIndexBackup)
        ]
        for (name, live) in stashedPairs where fm.fileExists(atPath: live.path) {
            try fm.moveItem(at: live, to: stash.appendingPathComponent(name))
        }
        addTeardownBlock {
            for (name, live) in stashedPairs {
                try? fm.removeItem(at: live)
                let src = stash.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: live) }
            }
            try? fm.removeItem(at: stash)
        }
    }

    /// Drains the serial ioQueue behind a (possibly) enqueued async file-only
    /// write by pushing a synchronous write for a DIFFERENT version through it
    /// (FIFO: insert → writeVersionToFile → ioQueue.sync).
    @MainActor
    private func drainIOQueue(of store: InspectionStore) {
        store.insert(version: makeVersion(id: UUID()))
    }

    // MARK: - 2. Clock backstop in writeVersionFileOnlyForAutoSave

    /// Row's LWW clock strictly newer than the passed copy's → the file-only
    /// write is refused and current.json is untouched.
    @MainActor
    func testFileOnlyWriteRefusedWhenRowClockIsNewer() throws {
        try stashRealStoreAside()
        let store = InspectionStore()

        let id = UUID()
        store.insert(version: makeVersion(id: id))
        // insert → writeVersionToFile stamped `updatedAt = now` (2026) onto
        // row + disk; the loaded copy carries that same stamp.
        let loaded = try XCTUnwrap(store.loadFullVersion(id: id))
        let authoritativeClock = try XCTUnwrap(loaded.updatedAt)

        // A stale copy: same lineage but its clock predates the row's.
        var stale = loaded
        stale.inspection.clientName = "Stale Autosave"
        stale.updatedAt = tStale
        XCTAssertLessThan(tStale, authoritativeClock, "precondition: the stale clock is strictly older")

        store.writeVersionFileOnlyForAutoSave(stale)
        drainIOQueue(of: store)

        let readBack = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertEqual(readBack.inspection.clientName, "Echo Client",
                       "a file-only write with an older clock must be refused — disk unchanged")
        XCTAssertEqual(readBack.updatedAt, authoritativeClock,
                       "the refused write must not touch the on-disk LWW clock either")

        store.saveNow()   // flush the debounced index save before teardown restores the real store
    }

    /// Equal clocks (the normal-editing case: the open draft and the row share
    /// the same lineage/stamp) → the write proceeds, without re-stamping.
    @MainActor
    func testFileOnlyWriteProceedsWithEqualClocks() throws {
        try stashRealStoreAside()
        let store = InspectionStore()

        let id = UUID()
        store.insert(version: makeVersion(id: id))
        let loaded = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertNotNil(loaded.updatedAt, "precondition: insert stamped the LWW clock")

        // Per-keystroke autosave of the open draft: same stamp as the row,
        // new content + the phantom bookkeeping fields.
        var edited = loaded
        edited.inspection.clientName = "Autosaved Edit"
        edited.inspection.weather = makeWeather()
        edited.inspection.timerElapsedSeconds = 42

        store.writeVersionFileOnlyForAutoSave(edited)
        drainIOQueue(of: store)

        let readBack = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertEqual(readBack.inspection.clientName, "Autosaved Edit",
                       "an equal-clock file-only write must reach disk")
        XCTAssertEqual(readBack.inspection.weather?.conditions, "Sunny",
                       "the bookkeeping fields persist locally through the file-only path")
        XCTAssertEqual(readBack.inspection.timerElapsedSeconds, 42)
        XCTAssertEqual(readBack.updatedAt, loaded.updatedAt,
                       "the file-only path never re-stamps the LWW clock")

        store.saveNow()
    }

    // MARK: - 3. Receiver-open-during-pull (the echo scenario minus the view layer)

    /// A remote apply lands while a stale copy of the same draft sits open:
    /// the stale copy's subsequent file-only write (weather fetch / timer fold
    /// via the per-keystroke autosave, or the bookkeeping-only teardown
    /// persist) must NOT clobber the freshly-applied newer content on disk.
    @MainActor
    func testStaleFileOnlyWriteCannotClobberAppliedRemoteContent() throws {
        try stashRealStoreAside()
        let store = InspectionStore()

        // 1) Local draft exists; a copy of it is "open in InspectionView".
        let id = UUID()
        store.insert(version: makeVersion(id: id))
        let openCopy = try XCTUnwrap(store.loadFullVersion(id: id))
        let openClock = try XCTUnwrap(openCopy.updatedAt)

        // 2) The real editor's NEWER edit arrives via pull and is applied.
        var remote = openCopy
        remote.inspection.clientName = "Editor's Real Edit"
        remote.updatedAt = openClock.addingTimeInterval(100)
        XCTAssertTrue(store.applyRemoteVersion(remote), "the remote draft edit applies cleanly")
        XCTAssertEqual(store.loadFullVersion(id: id)?.inspection.clientName, "Editor's Real Edit",
                       "precondition: the applied content is on disk")

        // 3) The stale open copy mutates ONLY via the phantom sources
        //    (weather auto-fetch + timer) and hits the file-only path.
        var staleOpen = openCopy
        staleOpen.inspection.weather = makeWeather()
        staleOpen.inspection.timerElapsedSeconds += 60
        store.writeVersionFileOnlyForAutoSave(staleOpen)
        drainIOQueue(of: store)

        // Disk keeps the applied remote content, untouched.
        let readBack = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertEqual(readBack.inspection.clientName, "Editor's Real Edit",
                       "the stale open copy must not overwrite the applied remote edit on disk")
        XCTAssertEqual(readBack.updatedAt, remote.updatedAt,
                       "the applied remote LWW clock survives")
        XCTAssertNil(readBack.inspection.weather,
                     "the refused stale write leaves no trace (whole-file write, so all-or-nothing)")

        store.saveNow()
    }
}
