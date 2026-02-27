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
}
