import XCTest

@MainActor
final class MyAppUITests: XCTestCase {
    
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Test onboarding flow navigation and UI elements
    func testOnboardingFlow() throws {
        // Assert the onboarding screen is shown
        XCTAssertTrue(app.staticTexts["Welcome"].exists, "Onboarding welcome text should be visible")
        
        // Tap on the "Next" button to go to the next onboarding screen
        let nextButton = app.buttons["Next"]
        XCTAssertTrue(nextButton.exists, "Next button should exist on onboarding screen")
        nextButton.tap()
        
        // Assert the next onboarding screen content is visible
        XCTAssertTrue(app.staticTexts["Features"].exists, "Features screen should be visible after tapping Next")
        
        // Tap on "Get Started" to finish onboarding
        let getStartedButton = app.buttons["Get Started"]
        XCTAssertTrue(getStartedButton.exists, "Get Started button should be on the last onboarding screen")
        getStartedButton.tap()
        
        // Assert onboarding is dismissed and main screen is visible
        XCTAssertTrue(app.otherElements["MainView"].exists, "Main view should be visible after onboarding")
    }

    /// Test onboarding legal links navigation
    func testOnboardingLegalLinks() throws {
        // On onboarding screen, tap "Read Privacy Policy"
        let privacyPolicyButton = app.buttons["Read Privacy Policy"]
        XCTAssertTrue(privacyPolicyButton.exists, "Read Privacy Policy button should exist on onboarding screen")
        privacyPolicyButton.tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].exists, "Privacy Policy screen should be shown after tapping Read Privacy Policy")
        app.navigationBars.buttons["Back"].tap()
        
        // Tap "Read Terms of Service"
        let termsButton = app.buttons["Read Terms of Service"]
        XCTAssertTrue(termsButton.exists, "Read Terms of Service button should exist on onboarding screen")
        termsButton.tap()
        XCTAssertTrue(app.staticTexts["Terms of Service"].exists, "Terms of Service screen should be shown after tapping Read Terms of Service")
        app.navigationBars.buttons["Back"].tap()
        
        // Tap "Data Safety Summary"
        let dataSafetyButton = app.buttons["Data Safety Summary"]
        XCTAssertTrue(dataSafetyButton.exists, "Data Safety Summary button should exist on onboarding screen")
        dataSafetyButton.tap()
        XCTAssertTrue(app.staticTexts["Data Safety Summary"].exists, "Data Safety Summary screen should be shown after tapping Data Safety Summary")
        app.navigationBars.buttons["Back"].tap()
    }

    /// Test paywall view presentation and button interaction
    func testPaywallView() throws {
        // Navigate to paywall screen (assuming a button from main view)
        let paywallButton = app.buttons["Show Paywall"]
        XCTAssertTrue(paywallButton.exists, "Show Paywall button should be on main screen")
        paywallButton.tap()
        
        // Assert paywall view is visible
        XCTAssertTrue(app.otherElements["PaywallView"].exists, "Paywall view should be presented")
        
        // Tap on subscribe button
        let subscribeButton = app.buttons["Subscribe"]
        XCTAssertTrue(subscribeButton.exists, "Subscribe button should be present on paywall")
        subscribeButton.tap()
        
        // Assert subscription confirmation or next flow is presented
        XCTAssertTrue(app.staticTexts["Thank you for subscribing"].waitForExistence(timeout: 5), "Subscription confirmation should appear")
    }

    /// Test paywall legal links navigation
    func testPaywallLegalLinks() throws {
        // Open paywall screen
        let paywallButton = app.buttons["Show Paywall"]
        XCTAssertTrue(paywallButton.exists, "Show Paywall button should be on main screen")
        paywallButton.tap()
        XCTAssertTrue(app.otherElements["PaywallView"].exists, "Paywall view should be presented")
        
        // Tap Privacy Policy link
        let privacyPolicyLink = app.buttons["Privacy Policy"]
        XCTAssertTrue(privacyPolicyLink.exists, "Privacy Policy link should be visible on paywall")
        privacyPolicyLink.tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].exists, "Privacy Policy screen should appear after tapping on paywall link")
        app.navigationBars.buttons["Back"].tap()
        
        // Tap Terms of Service link
        let termsLink = app.buttons["Terms of Service"]
        XCTAssertTrue(termsLink.exists, "Terms of Service link should be visible on paywall")
        termsLink.tap()
        XCTAssertTrue(app.staticTexts["Terms of Service"].exists, "Terms of Service screen should appear after tapping on paywall link")
        app.navigationBars.buttons["Back"].tap()
    }

    /// Test legal acceptance flow and navigation after acceptance
    func testLegalAcceptanceFlow() throws {
        // Assume legal acceptance is presented at launch if not accepted
        if app.otherElements["LegalView"].exists {
            // Assert legal text is present
            XCTAssertTrue(app.staticTexts["Terms and Conditions"].exists, "Legal terms should be visible")
            
            // Tap on accept button
            let acceptButton = app.buttons["Accept"]
            XCTAssertTrue(acceptButton.exists, "Accept button should be visible on legal screen")
            acceptButton.tap()
            
            // Assert legal view is dismissed and onboarding or main screen appears
            XCTAssertFalse(app.otherElements["LegalView"].exists, "Legal view should be dismissed after acceptance")
            XCTAssertTrue(app.otherElements["OnboardingView"].exists || app.otherElements["MainView"].exists, "Next screen should appear after legal acceptance")
        }
    }

    /// Test admin section visibility for admin user
    func testAdminSectionVisibleForAdmin() throws {
        app.terminate()
        app.launchArguments = ["-ResetLogin"]
        app.launch()

        // Log in as admin user
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "Username field should exist on login screen")
        usernameField.tap()
        usernameField.typeText("admin")
        
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.exists, "Password field should exist on login screen")
        passwordField.tap()
        passwordField.typeText("supersecret")
        
        let loginButton = app.buttons["Login"]
        XCTAssertTrue(loginButton.exists, "Login button should exist on login screen")
        loginButton.tap()
        
        // Navigate to settings screen
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist after login")
        settingsButton.tap()
        
        // Assert admin section is visible
        XCTAssertTrue(app.staticTexts["View Feedback Log"].exists, "Admin section 'View Feedback Log' should be visible for admin user")
    }

    /// Test admin section not visible for non-admin user
    func testAdminSectionNotVisibleForNonAdmin() throws {
        app.terminate()
        app.launchArguments = ["-ResetLogin"]
        app.launch()

        // Log in as non-admin user
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "Username field should exist on login screen")
        usernameField.tap()
        usernameField.typeText("testflight")
        
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.exists, "Password field should exist on login screen")
        passwordField.tap()
        passwordField.typeText("testpassword")
        
        let loginButton = app.buttons["Login"]
        XCTAssertTrue(loginButton.exists, "Login button should exist on login screen")
        loginButton.tap()
        
        // Navigate to settings screen
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist after login")
        settingsButton.tap()
        
        // Assert admin section is NOT visible
        XCTAssertFalse(app.staticTexts["View Feedback Log"].exists, "Admin section 'View Feedback Log' should NOT be visible for non-admin user")
    }

    /// Test full onboarding and legal acceptance flow with acceptance logging
    func testFullOnboardingAndLegalAcceptance() throws {
        // Launch fresh app with reset arguments to start at onboarding
        app.terminate()
        app.launchArguments = ["-ResetAppState"]
        app.launch()
        
        // Onboarding flow
        XCTAssertTrue(app.staticTexts["Welcome"].exists, "Onboarding welcome text should be visible at start")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Features"].exists, "Features screen should be visible after Next")
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.otherElements["MainView"].exists, "Main view should appear after onboarding")

        // Legal acceptance if shown
        if app.otherElements["LegalView"].exists {
            XCTAssertTrue(app.staticTexts["Terms and Conditions"].exists, "Legal terms should be visible")
            app.buttons["Accept"].tap()
            XCTAssertFalse(app.otherElements["LegalView"].exists, "Legal view dismissed after acceptance")
            XCTAssertTrue(app.otherElements["MainView"].exists || app.otherElements["OnboardingView"].exists, "Next screen after legal acceptance")
        }

        // Assert acceptance logged - mock by presence of confirmation text or element
        XCTAssertTrue(app.staticTexts["Thank you for accepting"].waitForExistence(timeout: 5), "Acceptance should be logged and confirmed")
    }

    /// Test creating a new inspection and asserting it appears in dashboard
    func testInspectionCreation() throws {
        // Ensure on main dashboard
        XCTAssertTrue(app.otherElements["MainView"].exists, "Main view must be visible")
        
        // Tap "New Inspection" button
        let newInspectionButton = app.buttons["New Inspection"]
        XCTAssertTrue(newInspectionButton.exists, "New Inspection button should exist")
        newInspectionButton.tap()

        // Fill in inspection details
        let titleField = app.textFields["InspectionTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Inspection title field should appear")
        titleField.tap()
        titleField.typeText("Test Inspection 001")

        let addressField = app.textFields["InspectionAddress"]
        XCTAssertTrue(addressField.exists, "Inspection address field should exist")
        addressField.tap()
        addressField.typeText("123 Test Lane")

        // Save inspection
        let saveButton = app.buttons["SaveInspection"]
        XCTAssertTrue(saveButton.exists, "Save button should exist")
        saveButton.tap()

        // Assert new inspection appears in the dashboard list
        let inspectionCell = app.staticTexts["Test Inspection 001"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5), "Newly created inspection should appear in dashboard")
    }

    /// Test editing an existing inspection and asserting changes persist
    func testInspectionEditing() throws {
        // Locate existing inspection cell and tap it
        let inspectionCell = app.staticTexts["Test Inspection 001"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5), "Inspection to edit should exist")
        inspectionCell.tap()

        // Tap Edit button
        let editButton = app.buttons["EditInspection"]
        XCTAssertTrue(editButton.exists, "Edit button should exist on inspection detail")
        editButton.tap()

        // Change the title
        let titleField = app.textFields["InspectionTitle"]
        XCTAssertTrue(titleField.exists, "Title field should exist in edit mode")
        titleField.tap()
        titleField.clearText()
        titleField.typeText("Test Inspection 001 - Edited")

        // Save changes
        let saveButton = app.buttons["SaveInspection"]
        XCTAssertTrue(saveButton.exists, "Save button should exist in edit mode")
        saveButton.tap()

        // Assert updated title is shown in inspection detail and dashboard
        XCTAssertTrue(app.staticTexts["Test Inspection 001 - Edited"].exists, "Edited title should be visible in detail")
        app.navigationBars.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Test Inspection 001 - Edited"].exists, "Edited title should appear in dashboard list")
    }

    /// Test finalizing inspection with signatures and asserting lock
    func testInspectionFinalization() throws {
        // Open an inspection
        let inspectionCell = app.staticTexts["Test Inspection 001 - Edited"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5), "Inspection to finalize should exist")
        inspectionCell.tap()

        // Navigate to signatures section
        let signaturesTab = app.buttons["Signatures"]
        XCTAssertTrue(signaturesTab.exists, "Signatures tab should exist")
        signaturesTab.tap()

        // Add inspector signature
        let inspectorSignatureButton = app.buttons["Add Inspector Signature"]
        XCTAssertTrue(inspectorSignatureButton.exists, "Inspector signature button should exist")
        inspectorSignatureButton.tap()
        // Mock signature by tapping on canvas or any element
        let signatureCanvas = app.otherElements["SignatureCanvas"]
        XCTAssertTrue(signatureCanvas.exists, "Signature canvas should be available")
        signatureCanvas.tap() // simulate a tap as signature input
        app.buttons["Done"].tap()

        // Add client signature
        let clientSignatureButton = app.buttons["Add Client Signature"]
        XCTAssertTrue(clientSignatureButton.exists, "Client signature button should exist")
        clientSignatureButton.tap()
        XCTAssertTrue(signatureCanvas.exists, "Signature canvas should be available")
        signatureCanvas.tap() // simulate a tap as signature input
        app.buttons["Done"].tap()

        // Finalize inspection
        let finalizeButton = app.buttons["Finalize Inspection"]
        XCTAssertTrue(finalizeButton.exists, "Finalize button should exist")
        finalizeButton.tap()

        // Assert inspection is locked and no further edits allowed
        XCTAssertTrue(app.staticTexts["Inspection Locked"].waitForExistence(timeout: 5), "Inspection should be locked after finalization")
        XCTAssertFalse(app.buttons["EditInspection"].exists, "Edit button should be disabled after finalization")

        app.navigationBars.buttons["Back"].tap()
    }

    /// Test adding photo and annotation to an inspection
    func testPhotoAndAnnotation() throws {
        // Open an inspection
        let inspectionCell = app.staticTexts["Test Inspection 001 - Edited"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5), "Inspection to add photo should exist")
        inspectionCell.tap()

        // Navigate to Photos tab
        let photosTab = app.buttons["Photos"]
        XCTAssertTrue(photosTab.exists, "Photos tab should exist")
        photosTab.tap()

        // Tap Add Photo button
        let addPhotoButton = app.buttons["Add Photo"]
        XCTAssertTrue(addPhotoButton.exists, "Add Photo button should exist")
        addPhotoButton.tap()

        // Since we cannot use real camera, simulate photo selection from library or mock
        let photoCell = app.cells["MockPhotoCell"]
        if photoCell.waitForExistence(timeout: 5) {
            photoCell.tap()
        } else {
            // If no mock photo, fail test
            XCTFail("Mock photo cell not available for photo selection")
        }

        // Assert photo added to list
        XCTAssertTrue(app.cells["Photo_0"].waitForExistence(timeout: 5), "Added photo should appear in photos list")

        // Select photo to annotate
        let photoCellAnnotated = app.cells["Photo_0"]
        photoCellAnnotated.tap()

        // Tap Annotate button
        let annotateButton = app.buttons["AnnotatePhoto"]
        XCTAssertTrue(annotateButton.exists, "Annotate button should exist")
        annotateButton.tap()

        // Simulate annotation by tapping on canvas
        let annotationCanvas = app.otherElements["AnnotationCanvas"]
        XCTAssertTrue(annotationCanvas.exists, "Annotation canvas should be available")
        annotationCanvas.tap()

        // Save annotation
        app.buttons["SaveAnnotation"].tap()

        // Assert annotation is present (e.g., annotation overlay exists)
        XCTAssertTrue(app.otherElements["AnnotationOverlay"].exists, "Annotation overlay should appear after saving")

        app.navigationBars.buttons["Back"].tap()
        app.navigationBars.buttons["Back"].tap()
    }

    /// Test adding and displaying inspector and client signatures
    func testSignaturesDisplay() throws {
        // Open inspection
        let inspectionCell = app.staticTexts["Test Inspection 001 - Edited"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5))
        inspectionCell.tap()

        // Navigate to Signatures tab
        let signaturesTab = app.buttons["Signatures"]
        XCTAssertTrue(signaturesTab.exists)
        signaturesTab.tap()

        // Assert existing inspector signature present
        XCTAssertTrue(app.images["InspectorSignatureImage"].exists, "Inspector signature image should be displayed")

        // Assert existing client signature present
        XCTAssertTrue(app.images["ClientSignatureImage"].exists, "Client signature image should be displayed")

        app.navigationBars.buttons["Back"].tap()
    }

    /// Test premium gating: free user sees paywall, admin user can access feature
    func testPremiumGating() throws {
        // Relaunch app as free/testflight user
        app.terminate()
        app.launchArguments = ["-ResetLogin"]
        app.launch()

        // Log in as testflight user
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        usernameField.tap()
        usernameField.typeText("testflight")

        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.exists)
        passwordField.tap()
        passwordField.typeText("testpassword")

        let loginButton = app.buttons["Login"]
        XCTAssertTrue(loginButton.exists)
        loginButton.tap()

        // Attempt to access premium feature
        let premiumFeatureButton = app.buttons["Premium Feature"]
        XCTAssertTrue(premiumFeatureButton.waitForExistence(timeout: 5))
        premiumFeatureButton.tap()

        // Assert paywall appears
        XCTAssertTrue(app.otherElements["PaywallView"].waitForExistence(timeout: 5), "Paywall should appear for free user")

        // Relaunch app as admin user
        app.terminate()
        app.launchArguments = ["-ResetLogin"]
        app.launch()

        // Log in as admin user
        let adminUsernameField = app.textFields["Username"]
        XCTAssertTrue(adminUsernameField.waitForExistence(timeout: 5))
        adminUsernameField.tap()
        adminUsernameField.typeText("admin")

        let adminPasswordField = app.secureTextFields["Password"]
        XCTAssertTrue(adminPasswordField.exists)
        adminPasswordField.tap()
        adminPasswordField.typeText("supersecret")

        let adminLoginButton = app.buttons["Login"]
        XCTAssertTrue(adminLoginButton.exists)
        adminLoginButton.tap()

        // Access premium feature
        let premiumFeatureButtonAdmin = app.buttons["Premium Feature"]
        XCTAssertTrue(premiumFeatureButtonAdmin.waitForExistence(timeout: 5))
        premiumFeatureButtonAdmin.tap()

        // Assert paywall does NOT appear
        XCTAssertFalse(app.otherElements["PaywallView"].exists, "Paywall should not appear for admin user")
        XCTAssertTrue(app.otherElements["PremiumFeatureView"].waitForExistence(timeout: 5), "Premium feature view should appear for admin")
    }

    /// Test LiDAR feature navigation and fallback on unsupported devices
    func testLiDARNavigation() throws {
        // Ensure on main view
        XCTAssertTrue(app.otherElements["MainView"].exists)

        // Navigate to Room Capture
        let roomCaptureButton = app.buttons["Room Capture"]
        XCTAssertTrue(roomCaptureButton.exists)
        roomCaptureButton.tap()

        // Check for LiDAR availability label or fallback
        if app.staticTexts["LiDAR Not Available"].exists {
            // Assert fallback UI shown
            XCTAssertTrue(app.staticTexts["LiDAR Not Available"].exists, "LiDAR unavailable fallback should show")
        } else {
            // Assert LiDAR capture UI visible
            XCTAssertTrue(app.otherElements["LiDARCaptureView"].exists, "LiDAR capture view should appear on supported device")
        }

        app.navigationBars.buttons["Back"].tap()
    }

    /// Test export functionality for PDF and text
    func testExportFunctionality() throws {
        // Open an inspection
        let inspectionCell = app.staticTexts["Test Inspection 001 - Edited"]
        XCTAssertTrue(inspectionCell.waitForExistence(timeout: 5))
        inspectionCell.tap()

        // Tap Export button
        let exportButton = app.buttons["Export"]
        XCTAssertTrue(exportButton.exists)
        exportButton.tap()

        // Export as PDF
        let exportPDFButton = app.buttons["Export PDF"]
        XCTAssertTrue(exportPDFButton.waitForExistence(timeout: 5))
        exportPDFButton.tap()

        // Assert export success message or UI feedback
        XCTAssertTrue(app.staticTexts["Export Successful"].waitForExistence(timeout: 10), "Export success message should appear for PDF")

        // Export as Text
        exportButton.tap()
        let exportTextButton = app.buttons["Export Text"]
        XCTAssertTrue(exportTextButton.waitForExistence(timeout: 5))
        exportTextButton.tap()

        // Assert export success message for text
        XCTAssertTrue(app.staticTexts["Export Successful"].waitForExistence(timeout: 10), "Export success message should appear for Text")

        app.navigationBars.buttons["Back"].tap()
    }

    /// Test feedback log accessibility and events for admin user
    func testFeedbackLogForAdmin() throws {
        app.terminate()
        app.launchArguments = ["-ResetLogin"]
        app.launch()

        // Log in as admin user
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        usernameField.tap()
        usernameField.typeText("admin")

        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.exists)
        passwordField.tap()
        passwordField.typeText("supersecret")

        let loginButton = app.buttons["Login"]
        XCTAssertTrue(loginButton.exists)
        loginButton.tap()

        // Navigate to Settings
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Tap on Feedback Log
        let feedbackLogButton = app.buttons["View Feedback Log"]
        XCTAssertTrue(feedbackLogButton.exists)
        feedbackLogButton.tap()

        // Assert feedback events displayed
        XCTAssertTrue(app.tables["FeedbackEventsTable"].exists, "Feedback events table should be visible")
        XCTAssertTrue(app.staticTexts["User reported bug"].exists || app.staticTexts["Feedback submitted"].exists, "Feedback entries should be present")

        app.navigationBars.buttons["Back"].tap()
        app.navigationBars.buttons["Back"].tap()
    }

    /// Test tapping all legal/data safety links in settings and onboarding screens
    func testLegalDataSafetyLinksNavigation() throws {
        // Navigate to Settings
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Tap Privacy Policy
        let privacyPolicyLink = app.buttons["Privacy Policy"]
        XCTAssertTrue(privacyPolicyLink.exists)
        privacyPolicyLink.tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].exists)
        app.navigationBars.buttons["Back"].tap()

        // Tap Terms of Service
        let termsLink = app.buttons["Terms of Service"]
        XCTAssertTrue(termsLink.exists)
        termsLink.tap()
        XCTAssertTrue(app.staticTexts["Terms of Service"].exists)
        app.navigationBars.buttons["Back"].tap()

        // Tap Data Safety Summary
        let dataSafetyLink = app.buttons["Data Safety Summary"]
        XCTAssertTrue(dataSafetyLink.exists)
        dataSafetyLink.tap()
        XCTAssertTrue(app.staticTexts["Data Safety Summary"].exists)
        app.navigationBars.buttons["Back"].tap()

        // Also test legal links in onboarding if onboarding screen is shown
        if app.otherElements["OnboardingView"].exists {
            let onboardingPrivacyPolicy = app.buttons["Read Privacy Policy"]
            if onboardingPrivacyPolicy.exists {
                onboardingPrivacyPolicy.tap()
                XCTAssertTrue(app.staticTexts["Privacy Policy"].exists)
                app.navigationBars.buttons["Back"].tap()
            }
            let onboardingTerms = app.buttons["Read Terms of Service"]
            if onboardingTerms.exists {
                onboardingTerms.tap()
                XCTAssertTrue(app.staticTexts["Terms of Service"].exists)
                app.navigationBars.buttons["Back"].tap()
            }
            let onboardingDataSafety = app.buttons["Data Safety Summary"]
            if onboardingDataSafety.exists {
                onboardingDataSafety.tap()
                XCTAssertTrue(app.staticTexts["Data Safety Summary"].exists)
                app.navigationBars.buttons["Back"].tap()
            }
        }

        app.navigationBars.buttons["Back"].tap()
    }

    /// Test restore purchases flow and UI feedback
    func testRestorePurchases() throws {
        // Navigate to Settings
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Tap Restore Purchases button
        let restoreButton = app.buttons["Restore Purchases"]
        XCTAssertTrue(restoreButton.exists)
        restoreButton.tap()

        // Assert success or failure message is shown (depending on mocked state)
        let successMessage = app.staticTexts["Purchases Restored"]
        let failureMessage = app.staticTexts["No Purchases Found"]

        let didShowSuccess = successMessage.waitForExistence(timeout: 10)
        let didShowFailure = failureMessage.waitForExistence(timeout: 10)

        XCTAssertTrue(didShowSuccess || didShowFailure, "Either success or failure message should appear after restore purchases")
        
        app.navigationBars.buttons["Back"].tap()
    }
}
private extension XCUIElement {
    func clearText() {
        guard let stringValue = self.value as? String else {
            return
        }

        tap()

        let deleteString = stringValue.map { _ in XCUIKeyboardKey.delete.rawValue }.joined()
        typeText(deleteString)
    }
}

