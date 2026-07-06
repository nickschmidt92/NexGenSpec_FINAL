//
//  BackupStatusView.swift
//  NexGenSpec
//
//  Settings card content for "Backup & Data". Shows:
//  • Free disk space on the device
//  • Active inspection count
//  • Multi-device note
//  • Plain-language guidance + a deep link to iOS Settings so the
//    inspector can verify iCloud Backup is on.
//

import SwiftUI
import UIKit

struct BackupStatusView: View {
    let metadataCount: Int

    @State private var freeSpaceLabel: String = "—"
    @State private var freeSpaceLow: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Local-first banner
            VStack(alignment: .leading, spacing: 6) {
                Label("Local-First — Your Evidence, Your Control", systemImage: "internaldrive")
                    .font(AppFont.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.brandBlue)
                Text(SyncFeature.localFirstBannerText)
                    .font(AppFont.footnote)
                    .foregroundStyle(.primary)
            }
            .padding(Spacing.md)
            .background(AppColor.brandBlue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Status rows
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: freeSpaceLow ? "exclamationmark.triangle.fill" : "internaldrive.fill",
                    color: freeSpaceLow ? AppColor.critical : AppColor.success,
                    title: "Free device storage: \(freeSpaceLabel)",
                    subtitle: freeSpaceLow
                        ? "Free space is getting low. Export and archive older inspections to your Files app / iCloud Drive before the device runs out of room."
                        : "Inspections grow over time (photos, video, LiDAR scans). Manage device storage proactively by exporting and archiving older records."
                )

                statusRow(
                    icon: "ipad",
                    color: AppColor.brandBlue,
                    title: "\(metadataCount) inspection\(metadataCount == 1 ? "" : "s") on this device",
                    subtitle: SyncFeature.multiDeviceBackupSubtitle
                )

                statusRow(
                    icon: "envelope.badge.shield.half.filled",
                    color: AppColor.brandBlue,
                    title: "Email-delivered reports",
                    subtitle: "Once a PDF report is emailed to a client, retention of that copy is governed by the email providers — not by NexGenSpec. Always keep a separate backup."
                )
            }

            // Action buttons
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open iOS Settings to verify iCloud Backup", systemImage: "gearshape.fill")
                }
                .buttonStyle(AppSecondaryButtonStyle())
                .appPencilHover()

                Text("Recommended path: iOS Settings → [your name] → iCloud → iCloud Backup → ON.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            refreshStatus()
        }
    }

    @ViewBuilder
    private func statusRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.subheadline.weight(.semibold))
                Text(subtitle).font(AppFont.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func refreshStatus() {
        // Free space on the volume containing the app's Documents directory.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let bytes = attrs[.systemFreeSize] as? NSNumber {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            freeSpaceLabel = formatter.string(fromByteCount: bytes.int64Value)
            // Warn if free space drops below 2 GB.
            freeSpaceLow = bytes.int64Value < 2_000_000_000
        }
    }
}

#if DEBUG
#Preview {
    AppScreenBackground {
        BackupStatusView(metadataCount: 7)
            .padding()
    }
}
#endif
