# NexGenSpec Architecture Plan

**Version:** 1.0  
**Last Updated:** February 17, 2026

---

## Overview

NexGenSpec is an offline-first inspection reporting app for iPad (primary) and iPhone (secondary). It is reporting software only—no marketplace, booking, or payment processing.

---

## Architectural Pattern

**MVVM + Services**

- **Views**: SwiftUI, presentation only
- **ViewModels**: @MainActor, hold UI state, coordinate with services
- **Services**: Business logic, storage, network, LiDAR
- **Models**: Codable structs, no logic

---

## Project Structure

```
NexGenSpec/
├── App/
│   ├── NexGenSpecApp.swift          # @main entry
│   └── RootView.swift               # Auth / main content gate
├── Core/
│   ├── FilePaths.swift              # Document directory, inspection paths
│   └── DateFormatters.swift         # Shared formatters
├── Models/
│   ├── Inspection.swift             # Inspection, Version, Section, Item
│   ├── Media.swift                  # Photo, Annotation, LiDAR assets
│   ├── Enums.swift                  # Status, Severity, VersionStatus
│   └── Template.swift               # Template import models
├── Services/
│   ├── InspectionStore.swift        # CRUD, persistence, template loading
│   ├── MediaStorageService.swift    # Photos on disk, thumbnails
│   ├── ReportService.swift          # HTML/PDF generation
│   ├── AuthService.swift            # Subscription / demo auth
│   └── LiDARService.swift           # RoomPlan/ARKit (iPad Pro)
├── ViewModels/
│   ├── DashboardViewModel.swift
│   ├── InspectionViewModel.swift    # Single inspection editing
│   └── ItemDetailViewModel.swift
├── Views/
│   ├── Dashboard/
│   │   ├── DashboardView.swift
│   │   └── NewInspectionSheet.swift
│   ├── Inspection/
│   │   ├── InspectionRootView.swift
│   │   ├── InspectionView.swift     # Split: Sidebar | Detail
│   │   ├── SectionSidebarView.swift
│   │   ├── SectionDetailView.swift
│   │   ├── ItemDetailView.swift
│   │   ├── SummaryView.swift
│   │   └── InspectionOverviewView.swift
│   ├── Media/
│   │   ├── PhotoPickerView.swift
│   │   └── PhotoAnnotationView.swift
│   ├── Signatures/
│   │   ├── SignatureView.swift
│   │   └── SignaturePad.swift
│   ├── Finalize/
│   │   └── FinalizeView.swift
│   ├── Legal/
│   │   ├── TermsAndConditionsView.swift
│   │   └── InspectorConfirmationView.swift
│   └── Report/
│       └── ShareReportView.swift
├── ReportRendering/
│   ├── HTMLReportRenderer.swift
│   └── PDFReportRenderer.swift
└── Templates/
    └── NexGenSpec_Template_v1.json  # Generic template (no DIA branding)
```

---

## Data Model Summary

### Item Status (per brief)
- `inspected`
- `notInspected`
- `notPresent`

### Severity
- `safety`, `major`, `marginal`, `minor`

### Version Status
- `draft` (editable)
- `final` (locked, immutable)

### Inspection Flow
1. Create inspection from template
2. Edit sections/items (draft)
3. Add photos (on disk, thumbnails)
4. Add annotations (vector overlay; bake at export)
5. Capture LiDAR (iPad Pro only)
6. Customer signs → Inspector signs → Finalize
7. On finalize: generate HTML/PDF, upload, email, purge local full-res

---

## Storage Layout

```
Documents/
├── NexGenSpec/
│   ├── inspections.json             # Metadata index
│   ├── Inspections/
│   │   └── {jobId}/
│   │       ├── inspection.json      # Full inspection data
│   │       ├── photos/              # Full-res (purged after upload)
│   │       │   └── {uuid}.png
│   │       ├── thumbnails/
│   │       │   └── {uuid}.jpg
│   │       ├── annotations/         # Vector overlay JSON
│   │       │   └── {photoId}.json
│   │       └── lidar/               # iPad Pro
│   │           ├── floorplan.png
│   │           ├── model.usdz
│   │           └── measurements.json
│   └── audit_log.txt                # T&C acceptance, etc.
```

---

## Key Design Decisions

1. **Photos on disk**: Never hold full-res in memory for list views. Use thumbnails. Purge full-res after upload.
2. **Annotation vectors**: Store arrow/circle as JSON; bake into image only at report generation.
3. **LiDAR graceful fallback**: Detect capability; hide UI on non-LiDAR devices.
4. **Single source of truth**: `InspectionStore` owns versions; ViewModels observe or receive updates.
5. **Mandatory inspector confirmation**: Checkbox before creating inspection; audit logged.
6. **No D.I.A. branding**: Template and UI use NexGenSpec / generic inspection terminology.

---

## Phase 1 MVP Scope

| Component | Status |
|-----------|--------|
| Template engine | In progress |
| Offline storage | In progress |
| Photo annotation (arrow, circle; green/yellow/red) | Planned |
| Dual signature + lock | Planned |
| HTML + PDF reports | Planned |
| LiDAR (iPad Pro) | Planned |
| Backend (upload, email) | Phase 1g |
| Legal (T&C, disclaimer, checkbox) | Planned |

---

## Dependencies

- SwiftUI
- PhotosUI (photo picker)
- ARKit / RoomPlan (LiDAR; iPad Pro)
- UIKit (PDF, share sheet)
