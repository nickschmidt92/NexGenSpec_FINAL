# App Icon

To clear the Xcode "AppIcon has no 1024×1024 image" warning and ship to the App Store:

1. Open the project in Xcode.
2. Go to **Assets.xcassets** → **AppIcon**.
3. Add a **1024×1024 px** image (PNG, no transparency) for the **Universal** slot.
4. Optionally add other sizes for older iOS versions; 1024×1024 is required for current App Store and device.

If you don’t have an icon yet, use any 1024×1024 placeholder (e.g. a solid color or your logo) so the project builds without the warning.
