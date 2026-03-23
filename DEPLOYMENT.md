# NexGenSpec – TestFlight Deployment

## Pre-flight checklist

- **Team**: Signing & Capabilities uses Development Team `CPTLCQYSJJ` (already set).
- **Bundle ID**: `com.nexgenspec.app` (already set).
- **Version**: Marketing Version `1.0`, Build `1` (in Xcode: **General** tab).
- **Privacy**: `PrivacyInfo.xcprivacy` is in the app target; Camera and Photo Library usage descriptions are in build settings.
- **Capabilities**: Add any required capabilities (e.g. iCloud) in Xcode if needed.

## Steps to deploy to TestFlight

1. **Open in Xcode**  
   Open `NexGenSpec.xcodeproj` in Xcode.

2. **Select destination**  
   In the scheme selector, choose **Any iOS Device** (or a connected device). Do not use a simulator for archiving.

3. **Increment build (for later uploads)**  
   For each new TestFlight upload, bump **Current Project Version** (e.g. to `2`, `3`, …) in the target’s **General** tab so TestFlight accepts the build.

4. **Archive**  
   Menu: **Product → Archive**. Wait for the archive to finish.

5. **Distribute**  
   In the Organizer window that appears:
   - Click **Distribute App**.
   - Choose **App Store Connect** → **Upload**.
   - Select the correct team and options (e.g. upload symbols, manage version and build number if desired).
   - Complete the flow; the build will upload to App Store Connect.

6. **App Store Connect**  
   - Go to [App Store Connect](https://appstoreconnect.apple.com).
   - Open your app (create it first if needed: **My Apps → + → New App**).
   - Open the **TestFlight** tab.
   - Wait for the new build to finish processing (can take several minutes).
   - Add **Internal** testers (same team) and/or **External** testers (requires Beta App Review for first external group).
   - For external testing, submit the build for **Beta App Review** when prompted.

## Running unit tests

- Select the **NexGenSpecTests** scheme or ensure the test target is built with the app.
- **Product → Test** (⌘U) to run unit tests in the simulator.

## Troubleshooting

- **Signing errors**: Confirm the correct Development Team and that a valid provisioning profile exists for `com.nexgenspec.app`.
- **Missing usage description**: Camera and Photo Library strings are set via `INFOPLIST_KEY_NSCameraUsageDescription` and `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` in the target build settings.
- **Privacy manifest**: Required for App Store; `PrivacyInfo.xcprivacy` declares UserDefaults usage (CA92.1).
