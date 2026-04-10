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
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: AppColor.cardShadow, radius: 18, x: 0, y: 10)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppColor.heroGradient)
            )
            .shadow(color: AppColor.accent.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.accent, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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

            // Subtle blue tint top-left — adapts to both modes
            LinearGradient(
                colors: [
                    AppColor.accent.opacity(0.06),
                    AppColor.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Soft accent circle (top-right)
            Circle()
                .fill(AppColor.accent.opacity(0.06))
                .frame(width: 260, height: 260)
                .blur(radius: 30)
                .offset(x: 160, y: -290)
                .ignoresSafeArea()

            // Decorative hexagon outline
            HexagonShape()
                .stroke(AppColor.accent.opacity(0.06), lineWidth: 1)
                .frame(width: 320, height: 320)
                .rotationEffect(.degrees(8))
                .offset(x: 170, y: -250)
                .ignoresSafeArea()

            content
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            HexagonShape()
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(
                    HexagonShape()
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                )

            HexagonShape()
                .stroke(Color.white.opacity(0.60), lineWidth: size * 0.08)
                .frame(width: size * 0.94, height: size * 0.94)

            HexagonShape()
                .inset(by: size * 0.17)
                .stroke(Color.white.opacity(0.60), lineWidth: size * 0.08)
                .frame(width: size * 0.94, height: size * 0.94)

            Text("S")
                .font(.system(size: size * 0.70, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 5)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 6)
    }
}

struct BrandLockup: View {
    var title: String = "NexGenSpec"
    var subtitle: String? = "Field-ready inspection reports"
    var markSize: CGFloat = 60
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: Spacing.sm) {
            if UIImage(named: "NexGenSpecLogo") != nil {
                Image("NexGenSpecLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: logoMaxWidth)
                    .accessibilityLabel(title)
            } else {
                HStack(alignment: .center, spacing: Spacing.md) {
                    BrandMark(size: markSize)

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(title)
                            .font(AppFont.hero)
                            .foregroundStyle(.white)
                            .kerning(-1.2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        if let subtitle {
                            Text(subtitle)
                                .font(AppFont.subheadline)
                                .foregroundStyle(Color.white.opacity(0.80))
                        }
                    }
                }
            }

            if let subtitle, UIImage(named: "NexGenSpecLogo") != nil {
                Text(subtitle)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Color.white.opacity(0.80))
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(
            LinearGradient(
                colors: [AppColor.brandBlue, AppColor.brandBlue.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: AppColor.brandBlue.opacity(0.25), radius: 18, x: 0, y: 10)
    }

    private var logoMaxWidth: CGFloat {
        max(markSize * 3.6, 220)
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
