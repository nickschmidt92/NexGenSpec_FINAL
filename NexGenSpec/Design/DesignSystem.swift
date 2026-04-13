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
    static let xxl: CGFloat = 40
}

/// Typography with Dynamic Type. Use for consistent, accessible text.
enum AppFont {
    static let hero = Font.system(.largeTitle, design: .rounded).weight(.black)
    static let title = Font.system(.title, design: .rounded).weight(.bold)
    static let title2 = Font.system(.title2, design: .rounded).weight(.bold)
    static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
}

/// Semantic colors. Adapts to light/dark; high contrast when enabled.
enum AppColor {
    static let brandNavy = Color(red: 0.08, green: 0.09, blue: 0.17)
    static let brandBlue = Color(red: 0.12, green: 0.43, blue: 0.96)
    static let brandCyan = Color(red: 0.15, green: 0.82, blue: 0.93)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .systemBackground)
    static let border = Color.primary.opacity(0.12)
    static let cardBackground = elevatedSurface
    static let cardShadow = Color.black.opacity(0.08)

    static let accent = brandBlue
    /// Deep accent for text/icons — adapts to light/dark automatically.
    static let accentDeep = accent
    /// Soft accent for tinted backgrounds — adapts via system tint.
    static let accentSoft = accent.opacity(0.15)
    static let highlight = Color(red: 0.95, green: 0.73, blue: 0.29)
    static let success = Color(red: 0.19, green: 0.53, blue: 0.35)
    static let warning = Color(red: 0.86, green: 0.57, blue: 0.18)
    static let critical = Color(red: 0.72, green: 0.23, blue: 0.26)

    static let safety = critical
    static let major = warning
    static let marginal = highlight
    static let minor = success

    /// Use when reduced transparency or darker system colors are enabled.
    static var useHighContrast: Bool {
        UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled
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

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [brandBlue, brandCyan],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    static var softPanelGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.08), elevatedSurface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var brandPanelGradient: LinearGradient {
        LinearGradient(
            colors: [brandNavy, Color(red: 0.11, green: 0.12, blue: 0.23)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// High-contrast-friendly color for a severity badge.
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
            .background(AppColor.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: AppColor.cardShadow, radius: 6, x: 0, y: 2)
    }
}

struct ElevatedCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(CardStyle())
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minHeight)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.brandBlue)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.headline)
            .foregroundStyle(AppColor.accent)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minHeight)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.accent.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppScreenBackground<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppColor.background
                .ignoresSafeArea()

            content
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("NexGenSpecLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityLabel("NexGenSpec")
    }
}

struct BrandLockup: View {
    var title: String = "NexGenSpec"
    var subtitle: String? = "Field-ready inspection reports"
    var markSize: CGFloat = 48
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                BrandMark(size: markSize)

                Text(title)
                    .font(AppFont.title2)
                    .foregroundStyle(.primary)
                    .kerning(-0.5)
            }
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)

            if let subtitle {
                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

private struct HexagonShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let height = rect.height

        let points = [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + height * 0.25),
            CGPoint(x: rect.maxX, y: rect.minY + height * 0.75),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY + height * 0.75),
            CGPoint(x: rect.minX, y: rect.minY + height * 0.25)
        ]

        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

extension View {
    func inspectionCard() -> some View {
        modifier(CardStyle())
    }

    func elevatedCard() -> some View {
        modifier(ElevatedCardStyle())
    }
}

/// Scaled metric for layout that respects Dynamic Type.
typealias AppScaled = ScaledMetric
