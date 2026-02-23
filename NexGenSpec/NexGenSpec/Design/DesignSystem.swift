//
//  DesignSystem.swift
//  NexGenSpec
//
//  Central design tokens: spacing, colors, typography. Dark mode + accessibility.
//

import SwiftUI
import UIKit

/// Spacing scale (4pt base). Use for padding and gaps.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

/// Typography with Dynamic Type. Use for consistent, accessible text.
enum AppFont {
    static let title = Font.title
    static let title2 = Font.title2
    static let title3 = Font.title3
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
}

/// Semantic colors. Adapts to light/dark; high contrast when enabled.
enum AppColor {
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardShadow = Color.black.opacity(0.06)
    static let accent = Color.accentColor
    static let safety = Color.red
    static let major = Color.orange
    static let marginal = Color.yellow
    static let minor = Color.green

    /// Use when UIAccessibility.isReduceTransparencyEnabled or increased contrast.
    static var useHighContrast: Bool {
        UIAccessibility.isReduceTransparencyEnabled
    }

    static var safetyAccessible: Color {
        useHighContrast ? Color(uiColor: .systemRed) : safety
    }
    static var majorAccessible: Color {
        useHighContrast ? Color(uiColor: .systemOrange) : major
    }
    static var marginalAccessible: Color {
        useHighContrast ? Color(uiColor: .systemYellow) : marginal
    }
    static var minorAccessible: Color {
        useHighContrast ? Color(uiColor: .systemGreen) : minor
    }

    /// High-contrast–friendly color for a severity badge.
    static func forSeverity(_ severity: Severity) -> Color {
        switch severity {
        case .safety: return safetyAccessible
        case .major: return majorAccessible
        case .marginal: return marginalAccessible
        case .minor: return minorAccessible
        }
    }
}

/// Minimum touch target for buttons and list rows (accessibility + gloved use).
enum TouchTarget {
    static let minHeight: CGFloat = 44
}

/// Card style: rounded, subtle shadow, consistent padding.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Spacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: AppColor.cardShadow, radius: 2, x: 0, y: 2)
    }
}

extension View {
    func inspectionCard() -> some View {
        modifier(CardStyle())
    }
}

/// Scaled metric for layout that respects Dynamic Type.
typealias AppScaled = ScaledMetric
