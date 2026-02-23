# LiDAR (RoomPlan) and Video Setup

## RoomPlan / LiDAR

The app uses Apple’s **RoomPlan** framework for LiDAR room capture on supported devices (e.g. iPhone 12 Pro+, iPad Pro with LiDAR).

### Xcode setup

1. Open the project in Xcode.
2. Select the **NexGenSpec** target → **General** → **Frameworks, Libraries, and Embedded Content**.
3. Click **+** and add **RoomPlan.framework** (system framework).
4. Ensure **Deployment Target** is **iOS 16.0** or later (RoomPlan requires iOS 16+).

If RoomPlan is not linked, the capture screen will show “RoomPlan is not linked” and the placeholder flow will still work.

### Behavior

- **Capture Room** (Overview toolbar) opens the RoomPlan capture UI on LiDAR devices (iOS 16+).
- The user scans the room; when done, the app exports a **USDZ** file to the inspection’s `lidar/` folder and saves metadata via `LiDARScanStore`.
- Saved scans are listed in the same sheet; they are included in the report (HTML/PDF and plain text).

---

## Video (drone / footage)

- **Overview** has a **Drone / Video** section. When the inspection is editable, **Add video** uses the system photo picker (videos).
- Selected videos are copied into the inspection’s `videos/` folder and appended to `Inspection.videos`.
- Exported reports (HTML/PDF) include a “Videos (drone / footage)” section; video files are copied into the report package and linked from the HTML.

No extra Xcode setup is required for video.
