#!/bin/bash
#
#  upload-crashlytics-dsyms.sh
#  NexGenSpec
#
#  Crashlytics dSYM upload script.
#
#  HOW TO ADD TO XCODE:
#  1. Open NexGenSpec.xcodeproj
#  2. Select the NexGenSpec target → Build Phases
#  3. Click "+" → "New Run Script Phase"
#  4. Rename it to "Upload Crashlytics dSYMs"
#  5. Paste the script below into the shell text area
#  6. Add these input files:
#       ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}
#       ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}
#       ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
#       $(SRCROOT)/$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)
#  7. Check "Run script: Based on dependency analysis" (for faster incremental builds)
#

# Find the Crashlytics upload binary from SPM build artifacts
UPLOAD_SYMBOLS=$(find "${BUILD_DIR%/Build/*}" -name "upload-symbols" -type f | head -1)

if [ -z "$UPLOAD_SYMBOLS" ]; then
    echo "warning: Crashlytics upload-symbols not found. dSYMs not uploaded."
    exit 0
fi

"${UPLOAD_SYMBOLS}" -gsp "${SRCROOT}/NexGenSpec/GoogleService-Info.plist" -p ios "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}"
