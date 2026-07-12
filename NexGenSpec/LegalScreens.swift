import SwiftUI

// MARK: - Branding Constants
struct Branding {
    static let accentColor = AppColor.accent
}

// MARK: - URLs and Effective Dates
struct LegalConstants {
    // Safe URL resolution: try Info.plist first, fall back to canonical
    // nexgenspec.com endpoints. No force-unwraps — an empty/missing plist
    // key on older builds used to crash the app when tapping the link.
    // Use the standalone .html files rather than the bare /privacy /terms
    // routes. The bare routes redirect to index.html and open a JS modal that
    // (a) depends on the homepage caching the latest content correctly, and
    // (b) fights Chrome iOS's WebKit cache when content updates ship. The
    // standalone .html pages serve the canonical Apr 28+ legal text directly.
    private static let fallbackPrivacy = "https://nexgenspec.com/privacy.html"
    private static let fallbackTerms   = "https://nexgenspec.com/terms.html"

    static let privacyPolicyURL: URL = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String) ?? ""
        return URL(string: s) ?? URL(string: fallbackPrivacy)!
    }()
    static let termsOfServiceURL: URL = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "TermsAndConditionsURL") as? String) ?? ""
        return URL(string: s) ?? URL(string: fallbackTerms)!
    }()

    static let privacyPolicyEffectiveDate = "Effective Date: May 30, 2026"
    static let termsOfServiceEffectiveDate = "Effective Date: May 30, 2026"
}

// MARK: - PrivacyPolicyView (Full Text + External Link)
struct PrivacyPolicyView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationStack {
            AppScreenBackground {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(LegalConstants.privacyPolicyEffectiveDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)

                        BrandLockup(
                            subtitle: "Privacy expectations and data handling for NexGenSpec customers.",
                            markSize: 60
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)

                        Text("Privacy Policy")
                            .font(.largeTitle)
                            .bold()
                            .foregroundColor(Branding.accentColor)
                            .padding(.bottom, 10)

                        Group {
                            Text("""
                            1. Zero-Storage Commitment
                            NexGenSpec ("we," "us," or "our") does not store, host, or have access to your inspection data, client information, photos, or reports. We operate no server-side database of inspection content. Your data stays on your device and, when iCloud Sync is on (the default), syncs across your own Apple devices through your private iCloud account (Apple CloudKit) — it goes only to your iCloud, never to NexGenSpec. Turn on Local-Only mode to keep inspections on a single device. iCloud Sync is not a backup, and deletions sync across your devices.

                            2. Information We Receive (Limited)
                            We do not store your inspection content on our servers. The only data that leaves your device is:
                            • Account login: Your email and an encrypted password — or, if you use Sign in with Apple, an Apple-issued user identifier and the email Apple chooses to share. Stored in Firebase Authentication.
                            • Optional fallback contact email: If you provide one at signup, used only if your primary email becomes unreachable.
                            • Anonymized crash reports: Sent to Firebase Crashlytics if the app crashes. No inspection content, no client info.
                            • Inspection weather (automatic): When you create or open an inspection that has no saved weather, the approximate coordinates (~1 km) of your current location are sent to Open-Meteo (open-meteo.com), a free no-account weather service, to fetch current conditions. No account, no identifier, no tracking, and we keep no copy. Deny Location in iOS Settings to turn it off.
                            • iCloud Sync (on by default): When iCloud Sync is on, your inspections — the inspection record, report PDFs, thumbnails, and LiDAR floor plans — sync across your own Apple devices through your private iCloud account (Apple CloudKit). Full-resolution photos, videos, and 3D scan files stay on the device that captured them. This data goes only to your iCloud; NexGenSpec never receives, stores, or can access it. Turn on Local-Only mode to keep inspections on a single device.

                            We do not collect analytics, advertising identifiers, contact lists, or any inspection content. We do not collect or store your location on our servers (see Device Permissions → Location below for the only, on-demand uses of location).

                            3. Device Permissions (How & Why)
                            • Camera: Capture inspection photos and video. Saved only to NexGenSpec's secure storage — never written to your iPhone/iPad Photos app.
                            • Photo Library (read-only): Import existing photos and video into a specific inspection (e.g. drone or thermal imagery you AirDropped). NexGenSpec never writes back to your Photo Library, never scans it in the background, and never accesses photos outside picker actions you initiate.
                            • Microphone (optional): Records audio together with the video when you capture a walkthrough video of an inspection area to include in your report. Audio is captured only while you are actively recording, is stored only in NexGenSpec's secure storage, and is never sent to our servers. Decline the prompt to record video without sound.
                            • Calendar (optional): Adds scheduled inspection appointments to a calendar you choose, and reads your other events to flag scheduling conflicts. Calendar data stays on your device — NexGenSpec never sends it to our servers.
                            • Location (optional, in-use only): Used two ways. (1) Inspection weather (automatic): when you create or open an inspection that has no weather yet, a one-time fix's approximate coordinates (~1 km) are sent to Open-Meteo (open-meteo.com) to fetch current conditions. (2) Auto-fill property address (only when you tap "Use Current Location"): a one-time fix is resolved into a street address using Apple's location services — those coordinates go to Apple, not to NexGenSpec or Open-Meteo. NexGenSpec never tracks your location in the background, never stores it on our servers, and never links it to your identity. Every other feature works with Location off.
                            • Notifications (optional): Inspection reminders.

                            Revoke any permission anytime in iOS Settings → NexGenSpec.

                            4. Data Ownership and Control
                            You are the sole owner and controller of all inspection content. You are the data controller for any personal information about your clients, agents, or other parties you enter into the app. You are responsible for:
                            • Backing up your inspection records.
                            • Managing the security of your device.
                            • Ensuring client privacy in accordance with local laws.

                            5. Multi-Device
                            \(SyncFeature.multiDeviceLegalClause)

                            6. Third-Party Services & Email
                            When you export or email a report, the data is subject to the privacy and retention policies of that provider. NexGenSpec does not control it after delivery. Once a PDF is emailed, retention of the delivered copy is governed by the email providers — not by NexGenSpec.

                            7. Security
                            Data is protected by your device's security (passcode, Face ID / Touch ID, iOS encryption). Keep iOS updated and enable iCloud Backup so inspections survive device loss.

                            8. Privacy Rights (GDPR / CCPA / Other)
                            NexGenSpec holds only your account login and (if provided) your optional fallback email. We do not have your inspection content, client information, photos, signatures, or reports. Right to access, deletion, or portability — email contact@nexgenspec.com or use Settings → Delete Account. Requests from your clients are referred back to you (the data controller).

                            9. Children
                            NexGenSpec is intended for adult professional inspectors. Not directed at children under 13.

                            10. Contact
                            NexGenSpec — contact@nexgenspec.com
                            """)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal)

                        Button(action: {
                            externalLink = LegalConstants.privacyPolicyURL
                            showExternalLinkAlert = true
                        }) {
                            Text("View Full Privacy Policy Online")
                                .foregroundColor(Branding.accentColor)
                                .font(.headline)
                                .underline()
                        }
                        .padding(.vertical)
                        .appPencilHover()

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $showExternalLinkAlert) {
                Alert(
                    title: Text("Open External Link?"),
                    message: Text("You are about to open the full Privacy Policy in your browser."),
                    primaryButton: .default(Text("Open")) {
                        if let url = externalLink {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .tint(Branding.accentColor)
    }
}

// MARK: - PrivacyPolicyContent (no NavigationStack — for embedding in existing navigation)
struct PrivacyPolicyContent: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.privacyPolicyEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top)

                    BrandMark(size: 96)
                        .padding(.bottom, 4)

                    Text("Privacy Policy")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    Group {
                        Text("""
                        1. Zero-Storage Commitment
                        NexGenSpec ("we," "us," or "our") does not store, host, or have access to your inspection data, client information, photos, or reports. We operate no server-side database of inspection content. Your data stays on your device and, when iCloud Sync is on (the default), syncs across your own Apple devices through your private iCloud account (Apple CloudKit) — it goes only to your iCloud, never to NexGenSpec. Turn on Local-Only mode to keep inspections on a single device. iCloud Sync is not a backup, and deletions sync across your devices.

                        2. Information Handling
                        We do not store your inspection content on our servers. We interact with the following:
                        • iCloud Sync (on by default): When iCloud Sync is on, your inspections — the inspection record, report PDFs, thumbnails, and LiDAR floor plans — sync across your own Apple devices through your private iCloud account (Apple CloudKit). Full-resolution photos, videos, and 3D scan files stay on the device that captured them. This data goes only to your iCloud; NexGenSpec never receives, stores, or can access it. Turn on Local-Only mode to keep inspections on a single device.
                        • Device Permissions: The App can request access to your Camera, Microphone, Photo Library, Calendar, and Location. The Microphone is used only to record audio alongside video when you capture a walkthrough video; that audio stays on your device and is never sent to our servers. The Calendar permission, when granted, lets NexGenSpec add inspection appointments to a calendar you choose and read your other events to flag scheduling conflicts; calendar data never leaves your device. Location is optional: when you create or open an inspection, the app automatically fetches current weather by sending the approximate coordinates (~1 km) of your location to Open-Meteo (open-meteo.com); and when you tap "Use Current Location," a one-time fix is resolved into a street address using Apple's location services. Location is never stored on our servers, never linked to your identity, and never used for tracking. All other features work without it.
                        • Usage & Diagnostics: We may receive anonymous technical logs (crash reports) via standard developer tools to fix bugs. This data does not contain your inspection content or client personal information.

                        3. Data Ownership and Control
                        You are the sole owner and controller of your data. You are responsible for:
                        • Backing up your inspection records and generated reports.
                        • Managing the security of your hardware.
                        • Ensuring the privacy of your clients and stakeholders in accordance with local laws.

                        4. Third-Party Services
                        When you export a report via email or save it to a cloud provider (like Google Drive or iCloud), that data is subject to the privacy policy of that specific provider. NexGenSpec does not control or see this data during the transfer.

                        5. Security
                        On your device, your data is protected by your device's security (Passcode, FaceID/TouchID, and iOS Encryption). When iCloud Sync is on, your inspections sync through your private iCloud account, where Apple encrypts them in transit and at rest; NexGenSpec never receives or stores them. We recommend keeping your device updated and utilizing Apple's native security features to protect professional records.

                        6. Contact
                        NexGenSpec — contact@nexgenspec.com
                        """)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal)

                    Link(destination: LegalConstants.privacyPolicyURL) {
                        Text("View full document online")
                            .foregroundColor(Branding.accentColor)
                            .font(.headline)
                            .underline()
                    }
                    .padding(.vertical)
                    .appPencilHover()

                    Spacer(minLength: 30)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TermsOfServiceView (Full Text + External Link)
struct TermsOfServiceView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationStack {
            AppScreenBackground {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(LegalConstants.termsOfServiceEffectiveDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)

                        BrandLockup(
                            subtitle: "Service terms, responsibilities, and operating boundaries for the app.",
                            markSize: 60
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)

                        Text("Terms of Service")
                            .font(.largeTitle)
                            .bold()
                            .foregroundColor(Branding.accentColor)
                            .padding(.bottom, 10)

                        Group {
                            Text("""
                            1. About NexGenSpec
                            NexGenSpec is a professional home inspection app for licensed property inspectors, available on the Apple App Store for iPhone and iPad. The app is provided by NexGenSpec ("we", "us", "the developer") to inspectors ("you", "the user") who have downloaded the app and accepted these Terms.

                            2. Account & Subscription
                            • An account is required to protect inspection data (client personal information, property photos, defect findings).
                            • The app is free to download. Free users may create up to 3 complete inspections with full PDF export. After 3 inspections, a Pro subscription is required to create additional inspections.
                            • Pro subscription: $49/month or $449/year. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage subscriptions in iOS Settings → Apple ID → Subscriptions.
                            • Payment is processed by Apple. NexGenSpec does not collect payment information directly.
                            • Communications. NexGenSpec may email you in connection with your account (authentication, password resets, subscription receipts, important service or security notices) and, from time to time, regarding new features, updates, deals, or upgrade offers. Opt out of marketing emails any time by emailing contact@nexgenspec.com with "unsubscribe" in the subject line. Transactional and account-related emails will continue regardless.

                            3. Inspector Responsibility
                            NexGenSpec is a tool for documenting inspections. The accuracy and completeness of every inspection report is the responsibility of the licensed inspector who creates it. The developer is not responsible for inspection findings, omissions, or any decisions made by the inspector or their clients based on app-generated reports.

                            Professional licensing & insurance. The inspector is solely responsible for maintaining all professional licenses and certifications required by their state, province, or licensing board, and for the type and amount of insurance coverage required to perform inspections legally and responsibly — including, where applicable, Errors & Omissions (E&O) coverage and general liability insurance. As recommended by most home-inspector licensing bodies, NexGenSpec strongly encourages inspectors to maintain professional E&O and general liability coverage at all times. Coverage decisions are entirely at the inspector's discretion and responsibility; NexGenSpec does not provide, recommend specific carriers for, or assume responsibility for any insurance arrangements.

                            4. Invoice & Payment Collection
                            NexGenSpec includes invoice formatting and email-delivery features as a convenience. NexGenSpec does not process payments. Any payment between the inspector and their client is collected directly by the inspector outside the app. The "Mark Invoice as Paid" toggle is a record-keeping aid only.

                            5. Data & Privacy
                            Inspection data, including photos, defect findings, client information, and signatures, is stored on your device using iOS Data Protection. The data sent off-device is (a) authentication tokens for sign-in, (b) anonymized crash reports, (c) when an inspection captures weather, the approximate coordinates of your location, sent to Open-Meteo (open-meteo.com) to fetch current conditions, and (d) when iCloud Sync is on (the default), your inspections — the inspection record, report PDFs, thumbnails, and LiDAR floor plans — which sync across your own Apple devices through your private iCloud account (Apple CloudKit); full-resolution photos, videos, and 3D scan files stay on the device that captured them. iCloud-synced data goes only to your iCloud; NexGenSpec never receives, stores, or can access it. Turn on Local-Only mode to keep inspections on a single device. iCloud Sync is not a backup, and deletions sync across your devices. NexGenSpec maintains no server-side copy of any inspection content.

                            6. Acceptable Use
                            • Use the app for lawful, professional inspection purposes only.
                            • Don't reverse-engineer, decompile, or extract source code.
                            • Don't use the app to harass, defame, or harm any third party.
                            • You are responsible for the confidentiality of your account credentials.

                            7. Termination & Account Deletion
                            Sign out anytime (Settings → Log Out) — local inspections are PRESERVED on the device. Sign back in to restore access.

                            Delete account anytime (Settings → Delete Account). Account deletion is PERMANENT and CANNOT be undone. When you delete:
                            • Your authentication record is removed from Firebase.
                            • All locally stored inspections, photos, signatures, audit logs, and PDFs are erased from the device.
                            • NexGenSpec issues an account-deletion receipt by email to your account address and to contact@nexgenspec.com.
                            • NexGenSpec retains no copy of your inspection data and cannot recover it.

                            We may suspend or terminate accounts that violate these Terms.

                            8. Data Retention & Backup Responsibility
                            IMPORTANT — please read carefully. \(SyncFeature.dataLocationClause) iCloud Sync is not a backup: it keeps your own devices in step (including propagating deletions), but it does not protect against the loss events below.

                            Your inspection data will be permanently and irrecoverably lost in any of the following events:
                            • You tap "Delete Account" inside the app — this wipes the device and tears down your synced iCloud copy.
                            • You delete an inspection while iCloud Sync is on — the deletion syncs to your other devices.
                            • You uninstall the app, factory-reset, restore, sell, or lose the device — and have no iCloud Sync copy on another device, no iCloud Backup, and no export.
                            • The device experiences hardware failure, is lost, or is stolen, with no iCloud Sync copy on another device, no iCloud Backup, and no export.
                            • A bug in the app or in iOS results in data corruption.
                            • Full-resolution photos, videos, and 3D scan (USDZ) files exist only on the device that captured them — iCloud Sync does not copy them, so losing, resetting, or replacing that device loses those originals even when the inspection record synced to another device.

                            NexGenSpec cannot recover lost inspection data under any circumstance, for any user, for any reason.

                            Inspector backup obligations. Inspectors are strongly advised to:
                            • Enable iCloud Backup (iOS Settings → [your name] → iCloud → iCloud Backup → On).
                            • Export every finalized inspection to a long-term backup location (iCloud Drive, external drive, NAS, or another system) immediately after finalization. NexGenSpec provides a one-tap export to the Files app.
                            • Retain encrypted copies for the duration of any applicable retention obligations. Industry standard: 5 years. Consult your professional liability insurance carrier and licensing board for jurisdiction-specific requirements.
                            • Manage device storage proactively. iPad storage is finite. The inspector is solely responsible for archiving older inspections to long-term backup before storage runs out.

                            \(SyncFeature.multiDeviceTermsClause)

                            Email delivery and retention. When you email a PDF report to a client, agent, or any recipient, the report is transmitted by your email provider and received by the recipient's email provider. Once the email leaves the device, retention of the delivered copy is governed entirely by the email providers — not by NexGenSpec. Don't rely on a sent email as the sole long-term archive of an inspection. Always retain a separate backup copy.

                            9. Disclaimer of Warranties
                            The app is provided "as is" and "as available" without warranties of any kind, express or implied, including but not limited to merchantability, fitness for a particular purpose, non-infringement, or uninterrupted operation. We don't guarantee NexGenSpec will be uninterrupted, error-free, free of viruses, or compatible with every iOS version or device.

                            10. Limitation of Liability
                            NexGenSpec is software. Our liability is limited to the operation of that software — app availability, app bugs that cause data loss inside the app, and similar app-level issues.

                            Maximum remedy. To the maximum extent permitted by law, our total liability to you for any claim arising out of or relating to your use of NexGenSpec is limited to a refund of the subscription fee you paid for the calendar month in which the issue occurred, contingent on (a) you reporting the issue in writing within that same calendar month, and (b) you providing reasonable supporting documentation. No other remedy is available.

                            What NexGenSpec does not cover:
                            • The accuracy, completeness, or quality of any inspection report you create. Those are the licensed inspector's professional work product and professional liability.
                            • Defects, damages, or losses at a property — whether identified, missed, or misclassified.
                            • Decisions made by buyers, sellers, agents, lenders, or any other party based on a NexGenSpec-generated report.
                            • Third-party services (Apple's iOS, Open-Meteo, StoreKit, Firebase, your email provider, Apple Pay). Each is governed by its own terms. Weather data provided by Open-Meteo.com (https://open-meteo.com/).
                            • Any payment dispute between an inspector and a client. NexGenSpec does not process payments.
                            • Loss of inspection data caused by any of the events listed in Section 8.
                            • Retention of email-delivered reports once the email has left your device.
                            • Indirect, consequential, incidental, special, or punitive damages, including lost revenue, lost profits, lost business opportunities, loss of goodwill, professional reputation harm, or claims by clients of the inspector.

                            Outage refund. If NexGenSpec experiences an extended outage caused by NexGenSpec (and not by Apple, Firebase, your network, your device, or other services outside our control), our maximum responsibility is a pro-rated refund of subscription fees for the duration of the outage. Outages must be reported in writing within the calendar month they occur to qualify.

                            11. Changes to These Terms
                            We may update these Terms from time to time. Material changes will be communicated through the app and require fresh acceptance before continued use.

                            12. Governing Law & Venue
                            These Terms are governed by the laws of the State of Colorado, USA, without regard to its conflict-of-laws principles. You and NexGenSpec agree that any dispute shall be brought exclusively in the state or federal courts located in Denver, Colorado, and you consent to personal jurisdiction in those courts.

                            Canadian users: If you are a resident of Canada, the foregoing does not deprive you of any non-waivable consumer-protection rights granted by your province or territory. Where such rights apply, they remain in effect notwithstanding the choice of Colorado law.

                            You and NexGenSpec agree any dispute will be resolved on an individual basis only. Class actions, class arbitrations, and consolidated proceedings are not permitted.

                            13. Contact
                            NexGenSpec — contact@nexgenspec.com
                            """)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal)

                        Button(action: {
                            externalLink = LegalConstants.termsOfServiceURL
                            showExternalLinkAlert = true
                        }) {
                            Text("View Full Terms of Service Online")
                                .foregroundColor(Branding.accentColor)
                                .font(.headline)
                                .underline()
                        }
                        .padding(.vertical)
                        .appPencilHover()

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Terms of Service")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $showExternalLinkAlert) {
                Alert(
                    title: Text("Open External Link?"),
                    message: Text("You are about to open the full Terms of Service in your browser."),
                    primaryButton: .default(Text("Open")) {
                        if let url = externalLink {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .tint(Branding.accentColor)
    }
}

// MARK: - TermsOfServiceContent (no NavigationStack — for embedding in existing navigation)
struct TermsOfServiceContent: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.termsOfServiceEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top)

                    BrandMark(size: 96)
                        .padding(.bottom, 4)

                    Text("Terms of Service")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    Group {
                        Text("""
                        1. About NexGenSpec
                        NexGenSpec is a professional home inspection app for licensed property inspectors, available on the Apple App Store for iPhone and iPad. The app is provided by NexGenSpec ("we", "us", "the developer") to inspectors ("you", "the user") who have downloaded the app and accepted these Terms.

                        2. Account & Subscription
                        • An account is required to protect inspection data (client personal information, property photos, defect findings).
                        • The app is free to download. Free users may create up to 3 complete inspections with full PDF export. After 3 inspections, a Pro subscription is required to create additional inspections.
                        • Pro subscription: $49/month or $449/year. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage subscriptions in iOS Settings → Apple ID → Subscriptions.
                        • Payment is processed by Apple. NexGenSpec does not collect payment information directly.
                        • Communications. NexGenSpec may email you in connection with your account (e.g. authentication, password resets, subscription receipts, important service or security notices) and, from time to time, regarding new features, updates, deals, or upgrade offers. You may opt out of marketing emails at any time by emailing contact@nexgenspec.com with the word "unsubscribe" in the subject line. Transactional and account-related emails will continue regardless of marketing preferences.

                        3. Inspector Responsibility
                        NexGenSpec is a tool for documenting inspections. The accuracy and completeness of every inspection report is the responsibility of the licensed inspector who creates it. The developer is not responsible for inspection findings, omissions, or any decisions made by the inspector or their clients based on app-generated reports.

                        4. Invoice & Payment Collection
                        NexGenSpec includes invoice formatting and email-delivery features as a convenience. NexGenSpec does not process payments. Any payment between the inspector and their client is collected directly by the inspector outside the app. The "Mark Invoice as Paid" toggle inside the app is a record-keeping aid only.

                        5. Data & Privacy
                        Inspection data, including photos, defect findings, client information, and signatures, is stored on your device using iOS Data Protection. The data sent off-device is (a) authentication tokens for sign-in, (b) anonymized crash reports, (c) when an inspection captures weather, the approximate coordinates of your location, sent to Open-Meteo (open-meteo.com) to fetch current conditions, and (d) when iCloud Sync is on (the default), your inspections — the inspection record, report PDFs, thumbnails, and LiDAR floor plans — which sync across your own Apple devices through your private iCloud account (Apple CloudKit); full-resolution photos, videos, and 3D scan files stay on the device that captured them. iCloud-synced data goes only to your iCloud; NexGenSpec never receives, stores, or can access it. Turn on Local-Only mode to keep inspections on a single device. iCloud Sync is not a backup, and deletions sync across your devices. NexGenSpec maintains no server-side copy of any inspection content.

                        6. Acceptable Use
                        • You agree to use the app for lawful, professional inspection purposes only.
                        • You will not attempt to reverse-engineer, decompile, or extract source code from the app.
                        • You will not use the app to harass, defame, or harm any third party.
                        • You are responsible for maintaining the confidentiality of your account credentials.

                        7. Termination
                        You may delete your account at any time from inside the app (Settings → Delete Account), which permanently removes your authentication record and all locally stored inspections. We may suspend or terminate accounts that violate these Terms.

                        8. Disclaimer of Warranties
                        The app is provided "as is" without warranties of any kind. We don't guarantee NexGenSpec will be uninterrupted, error-free, or compatible with every iOS version or device. Inspection content is stored on your device and, when iCloud Sync is on, in your own private iCloud account — never on a NexGenSpec server. iCloud Sync is not a backup; inspectors are responsible for maintaining their own backups.

                        9. Limitation of Liability
                        NexGenSpec is software. Our liability is limited to the operation of that software — specifically: app availability, app bugs that cause data loss inside the app, and similar app-level issues.

                        Maximum remedy. To the maximum extent permitted by law, our total liability to you for any claim arising out of or relating to your use of NexGenSpec is limited to a refund of the subscription fee you paid for the calendar month in which the issue occurred, contingent on (a) you reporting the issue to NexGenSpec in writing within that same calendar month, and (b) you providing reasonable supporting documentation evidencing the issue. No other remedy is available.

                        What NexGenSpec does not cover:
                        • The accuracy, completeness, or quality of any inspection report you create. Those are the licensed inspector's professional work product and professional liability.
                        • Defects, damages, or losses at a property — whether identified, missed, or misclassified during an inspection.
                        • Decisions made by buyers, sellers, agents, lenders, or any other party based on a NexGenSpec-generated report.
                        • Third-party services the app integrates with (Apple's iOS, Open-Meteo, StoreKit, Firebase, your email provider, Apple Pay, etc.). Each is governed by its own terms. Weather data provided by Open-Meteo.com (https://open-meteo.com/).
                        • Any payment dispute between an inspector and a client. NexGenSpec does not process payments.
                        • Loss of inspection data caused by device failure, accidental deletion, OS upgrades, lost or stolen devices, or anything outside our direct control. NexGenSpec does not maintain server-side copies of inspection content and cannot recover it.
                        • Indirect, consequential, incidental, special, or punitive damages, including lost revenue, lost profits, lost business opportunities, or loss of goodwill.

                        Outage refund. If NexGenSpec experiences an extended outage caused by NexGenSpec (and not by Apple, Firebase, your network, your device, or other services outside our control), our maximum responsibility is a pro-rated refund of subscription fees for the duration of the outage. Outages must be reported in writing within the calendar month they occur to qualify.

                        10. Changes to These Terms
                        We may update these Terms from time to time. Material changes will be communicated through the app and require fresh acceptance before continued use.

                        11. Governing Law & Venue
                        These Terms are governed by the laws of the State of Colorado, USA, without regard to its conflict-of-laws principles. You and NexGenSpec agree that any dispute arising out of or relating to these Terms or the app shall be brought exclusively in the state or federal courts located in Denver, Colorado, and you consent to personal jurisdiction in those courts.

                        Canadian users: If you are a resident of Canada, the foregoing does not deprive you of any non-waivable consumer-protection rights granted by your province or territory of residence. Where such rights apply, they remain in effect notwithstanding the choice of Colorado law.

                        You and NexGenSpec agree that any dispute will be resolved on an individual basis only. Class actions, class arbitrations, and consolidated proceedings are not permitted.

                        12. Contact
                        NexGenSpec — contact@nexgenspec.com
                        """)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal)

                    Link(destination: LegalConstants.termsOfServiceURL) {
                        Text("View full document online")
                            .foregroundColor(Branding.accentColor)
                            .font(.headline)
                            .underline()
                    }
                    .padding(.vertical)
                    .appPencilHover()

                    Spacer(minLength: 30)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PDFKitView Wrapper for PDF Display
import PDFKit
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
        #if DEBUG
        // Screenshot capture: `-screenshotPDFPage <n|last>` opens the report on
        // a specific page (1-indexed), fitted as a single page. Debug-only and
        // inert without -screenshotMode.
        if ScreenshotMode.isActive,
           let i = CommandLine.arguments.firstIndex(of: "-screenshotPDFPage"),
           i + 1 < CommandLine.arguments.count,
           let doc = pdfView.document, doc.pageCount > 0 {
            let arg = CommandLine.arguments[i + 1]
            let requested = (arg == "last") ? doc.pageCount - 1 : (Int(arg) ?? 1) - 1
            let index = max(0, min(requested, doc.pageCount - 1))
            // Stay in .singlePageContinuous: autoScales fits the page WIDTH
            // (filling the screen, top-aligned) instead of letterboxing the
            // whole page with gray bands. Optional `-screenshotPDFZoom <f>`
            // magnifies (like a user pinch-zoom); the destination pins the
            // requested page's top-left to the top of the view either way.
            var zoom: CGFloat = 1
            if let zi = CommandLine.arguments.firstIndex(of: "-screenshotPDFZoom"),
               zi + 1 < CommandLine.arguments.count,
               let z = Double(CommandLine.arguments[zi + 1]) {
                zoom = CGFloat(z)
            }
            // `-screenshotPDFOffset <pts>` scrolls further down INTO the page
            // (PDF-space points from its top) — for framing a card that sits
            // mid-page or straddles a page boundary.
            var offset: CGFloat = 0
            if let oi = CommandLine.arguments.firstIndex(of: "-screenshotPDFOffset"),
               oi + 1 < CommandLine.arguments.count,
               let o = Double(CommandLine.arguments[oi + 1]) {
                offset = CGFloat(o)
            }
            if let page = doc.page(at: index) {
                DispatchQueue.main.async {
                    if zoom != 1 {
                        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * zoom
                    }
                    let top = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).height - offset))
                    pdfView.go(to: top)
                }
            }
        }
        #endif
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

