//
//  NexGenSpecUITests.swift
//  NexGenSpecUITests
//
//  End-to-end regression test for the async autosave path introduced in
//  0c1a390 ("perf: optimize main-thread blocking and UI responsiveness"),
//  where `InspectionStore.writeVersionFileOnlyForAutoSave` moved from a
//  blocking main-thread write to `ioQueue.async`.
//
//  The risk that change introduced: an edit that is autosaved off-main might
//  not be flushed to disk if the process dies before the async write lands.
//  This test forces exactly that scenario:
//
//      open inspection → edit a finding comment → wait for the 2s debounce +
//      async ioQueue write → SIGKILL the process (no graceful flush) →
//      relaunch → confirm the edit is still there.
//
//  Auth/seed strategy: launches through the DEBUG ScreenshotHost
//  (`-screenshotMode -screenshotRoute inspection`), which bypasses login and
//  seeds DemoModeFixture ONLY when the store is empty. On relaunch the seeded
//  data is already on disk, so it is NOT re-seeded (re-seeding would overwrite
//  the autosaved edit and produce a false pass). This reuses the same launch
//  pattern the screenshot tooling already relies on.
//
//  NOTE: requires a DEBUG build (ScreenshotHost is `#if DEBUG`).
//

import XCTest
import Foundation   // kill / SIGKILL

final class NexGenSpecAutosaveUITests: XCTestCase {

    /// Unique, timestamped marker typed into the finding comment so the
    /// post-relaunch assertion can't pass on stale/seed text.
    private let marker = "UITESTAUTOSAVE\(Int(Date().timeIntervalSince1970))"

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        // -screenshotMode: route through ScreenshotHost (no network / no login).
        // -screenshotRoute inspection: open the first seeded inspection directly.
        // Seeding is gated on an empty store inside ScreenshotHost, so the
        // RELAUNCH below does not re-seed and clobber the edit.
        app.launchArguments = ["-screenshotMode", "-screenshotRoute", "draftInspection"]
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAutosavedEditSurvivesForceKill() throws {
        // ----- Launch 1: open inspection, edit, autosave, then SIGKILL -----
        let app = makeApp()
        app.launch()

        let observed = try openFirstItemObservedEditor(in: app, phase: "initial launch")

        // Edit the finding comment with the unique marker. Typing mutates the
        // bound model, which fires InspectionView's onChange → 2s debounce →
        // store.writeVersionFileOnlyForAutoSave (the off-main ioQueue.async path).
        //
        // Focus is acquired robustly (see focusAndType): the item-detail sheet's
        // present animation / focus handoff isn't reliably settled when the
        // editor first exists, so a bare tap+typeText raced and intermittently
        // failed under full-suite runs.
        focusAndType(observed, text: marker, in: app, phase: "initial launch")

        // Wait past the 2s autosave debounce AND let the async ioQueue write
        // complete. (3.5s gives margin; the write itself is sub-ms once queued.)
        Thread.sleep(forTimeInterval: 3.5)

        // True force-kill: SIGKILL, NOT app.terminate(). terminate() lets the
        // app receive willResignActive / scene-disconnect, which fire
        // NexGenSpec's SYNCHRONOUS flush (InspectionStore + InspectionView) —
        // that would mask a broken async autosave by writing on the way out.
        // SIGKILL gives the process no chance to flush, so persistence here
        // proves the async ioQueue write already reached disk on its own.
        //
        // GAP: XCUIApplication exposes no public `processIdentifier` in this
        // SDK (Xcode 26.5), so we parse the PID from `debugDescription`
        // (best-effort) and SIGKILL it. If that ever fails to yield a PID we
        // fall back to terminate() — less rigorous (see note above) — rather
        // than skip the kill entirely.
        if let pid = processID(of: app), pid > 0 {
            kill(pid, SIGKILL)
        } else {
            XCTFail("could not obtain app PID for SIGKILL; falling back to terminate() which is a weaker test")
            app.terminate()
        }

        // ----- Launch 2: relaunch (no re-seed) and verify the edit persisted -----
        let relaunched = makeApp()
        relaunched.launch()

        let observedAgain = try openFirstItemObservedEditor(in: relaunched, phase: "relaunch")
        let value = (observedAgain.value as? String) ?? ""
        XCTAssertTrue(
            value.contains(marker),
            "autosaved edit did NOT persist across SIGKILL. Expected the observed field to contain \"\(marker)\" but got \"\(value)\""
        )
    }

    // MARK: - Navigation helper

    /// Navigates the inspection → first section → first item → `observedEditor`
    /// and returns the editor element. Fails the test (with the phase noted) if
    /// any step's element never appears.
    private func openFirstItemObservedEditor(in app: XCUIApplication, phase: String) throws -> XCUIElement {
        // Section list (InspectionView). Section rows carry id "sectionRow";
        // SwiftUI NavigationLinks surface as either buttons or cells depending
        // on OS, so accept either.
        let section = firstElement(in: app, identifier: "sectionRow")
        XCTAssertTrue(section.waitForExistence(timeout: 20),
                      "[\(phase)] no section row appeared — inspection did not open")
        section.tap()

        // Item list (section pane). Item rows carry id "itemRow".
        let item = firstElement(in: app, identifier: "itemRow")
        if !item.waitForExistence(timeout: 10) {
            // DIAGNOSTIC: dump the element tree so we can see how the section
            // pane actually surfaces its rows to XCUITest.
            print("=== ELEMENT TREE AFTER SECTION TAP [\(phase)] ===\n\(app.debugDescription)\n=== END TREE ===")
            XCTFail("[\(phase)] no item row appeared — section did not open")
        }
        item.tap()

        // ItemDetailView is presented as a sheet; the observed comment is a
        // TextEditor with id "observedEditor".
        let observed = app.textViews["observedEditor"]
        XCTAssertTrue(observed.waitForExistence(timeout: 10),
                      "[\(phase)] observed editor did not appear — item detail sheet did not open")
        return observed
    }

    // MARK: - Focus / typing helpers

    /// Robustly makes `element` first responder, then types `text`.
    ///
    /// Why this exists: a bare `element.tap(); element.typeText(...)` was flaky
    /// on full-suite runs. The item-detail sheet's present animation / focus
    /// handoff isn't always settled when the editor first exists, so the tap
    /// didn't make the SwiftUI `TextEditor` first responder and `typeText`
    /// failed with "Neither element nor any descendant has keyboard focus" (the
    /// editor reported Disabled). This does NOT assume the first tap focuses it:
    ///   1. waits for the editor to be enabled + hittable before touching it,
    ///   2. taps, then VERIFIES focus was acquired before typing — the software
    ///      keyboard appearing (plus the editor's `hasFocus`) is the precondition
    ///      typeText requires. (This SDK, Xcode 26.5, does not expose
    ///      `XCUIElement.hasKeyboardFocus`, so the on-screen keyboard is the
    ///      deterministic focus signal.)
    ///   3. re-taps (a coordinate tap on the element's centre) up to a bounded
    ///      number of times if focus didn't land, failing with a clear message,
    ///   4. after typing, CONFIRMS the marker actually landed in this editor —
    ///      turning any residual focus miss into a clear, local failure rather
    ///      than a confusing post-relaunch mismatch.
    /// It never weakens the test: the marker is still typed into the real editor.
    private func focusAndType(_ element: XCUIElement, text: String,
                              in app: XCUIApplication, phase: String) {
        // Don't touch the editor until the sheet has settled enough that the
        // element is actually interactive — this is the race the bare
        // tap+typeText lost.
        XCTAssertTrue(
            waitUntil(10) { element.isEnabled && element.isHittable },
            "[\(phase)] observed editor never became enabled + hittable — cannot focus it"
        )

        // Acquire keyboard focus, RE-TAPPING up to a bounded number of times.
        // The keyboard appearing after we tap this (now-interactive) element is
        // our focus signal; `hasFocus` is an extra best-effort confirmation.
        let keyboard = app.keyboards.firstMatch
        let maxAttempts = 4
        var focused = false
        for attempt in 1...maxAttempts {
            if attempt == 1 {
                element.tap()
            } else {
                // A centre coordinate tap is more reliable than .tap() when a
                // placeholder overlay or an in-flight animation intercepts the
                // first hit.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if waitUntil(3, { keyboard.exists && element.hasFocus }) {
                focused = true
                break
            }
            // Some SwiftUI/OS combos don't surface `hasFocus` on a TextEditor;
            // fall back to the keyboard alone as the focus signal.
            if waitUntil(1, { keyboard.exists }) {
                focused = true
                break
            }
        }

        XCTAssertTrue(
            focused,
            "[\(phase)] keyboard never appeared after \(maxAttempts) taps on the observed editor "
            + "(hasFocus=\(element.hasFocus), keyboardShown=\(keyboard.exists)). "
            + "If the keyboard never appears, ensure the simulator software keyboard is enabled "
            + "(ConnectHardwareKeyboard = 0)."
        )

        element.typeText(text)

        // Confirm the marker actually landed in THIS editor before we depend on
        // it (guards the rare case where focus went elsewhere or the tap missed).
        XCTAssertTrue(
            waitUntil(5, { ((element.value as? String) ?? "").contains(text) }),
            "[\(phase)] typed marker did not appear in the observed editor "
            + "(value=\"\((element.value as? String) ?? "")\")"
        )
    }

    /// Polls `condition` at short intervals until it returns true or `timeout`
    /// elapses; returns the final result. Deterministic bounded wait — used for
    /// focus acquisition instead of a single arbitrary long sleep.
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return condition()
    }

    /// Best-effort extraction of the app-under-test's PID. XCUIApplication has
    /// no public PID accessor, but its `debugDescription` includes a
    /// "pid: <n>" fragment we can parse so we can send a real SIGKILL.
    private func processID(of app: XCUIApplication) -> pid_t? {
        let desc = app.debugDescription
        guard let range = desc.range(of: #"pid:?\s*\d+"#, options: .regularExpression) else { return nil }
        let digits = desc[range].filter(\.isNumber)
        guard let value = Int32(digits) else { return nil }
        return value
    }

    /// First element matching `identifier`, trying buttons then cells then any
    /// descendant — SwiftUI row containers vary across OS versions.
    private func firstElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists { return button }
        let cell = app.cells[identifier].firstMatch
        if cell.exists { return cell }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

// MARK: - Known automation gaps (documented per task request)
//
// These steps depend on XCUITest's ability to drive SwiftUI controls and may
// require live iteration on a real run to harden; they are implemented as the
// best-effort path above:
//
//  1. SwiftUI `TextEditor` (UITextView) targeting: `app.textViews["observedEditor"]`
//     relies on the accessibilityIdentifier added in ItemDetailView. Focus is
//     no longer assumed from a single tap: `focusAndType` waits for the editor
//     to be enabled + hittable, then taps and VERIFIES focus (the software
//     keyboard appearing, plus the editor's `hasFocus`) before typing, re-tapping
//     via a coordinate tap up to a bounded number of times, and finally confirms
//     the marker landed in the editor. This SDK (Xcode 26.5) does not expose
//     `XCUIElement.hasKeyboardFocus`, so the on-screen keyboard is the focus
//     signal. This resolved the intermittent full-suite failure where the editor
//     was reported Disabled with "Neither element nor any descendant has
//     keyboard focus".
//  2. `typeText` requires the simulator's *software* keyboard
//     (Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard = OFF, or
//     `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard 0`).
//  3. Reading the persisted value via `observedAgain.value` returns the
//     UITextView text; if a future build shows the placeholder as the
//     accessibility value when empty, prefer asserting against a fresh tap.
//  4. NavigationLink row identifiers surface as button/cell/other depending on
//     iOS version — `firstElement(in:identifier:)` tries all three.
