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
    // MARK: Brand colors (fixed, not adaptive)
    static let brandNavy = Color(red: 0.08, green: 0.09, blue: 0.17)
    static let brandBlue = Color(red: 0.12, green: 0.43, blue: 0.96)
    static let brandCyan = Color(red: 0.15, green: 0.82, blue: 0.93)

    // MARK: Semantic surface colors (adaptive light/dark)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .systemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let border = Color.primary.opacity(0.12)
    static let cardBackground = elevatedSurface
    static let cardShadow = Color.black.opacity(0.08)

    // MARK: Accent and status colors
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

    /// Adaptive dark-mode–aware brand panel: uses brandNavy in light, a subtle elevated surface in dark.
    static var adaptiveBrandPanelGradient: LinearGradient {
        // This returns the same gradient; the adaptive behavior comes from
        // pairing it with semantic foreground colors in context.
        brandPanelGradient
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

/// Glass card style: translucent material with iOS 26 glassEffect on cards/floating elements.
struct GlassCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .padding(Spacing.md)
                .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                .shadow(color: AppColor.cardShadow, radius: 4, x: 0, y: 1)
        } else {
            content
                .padding(Spacing.md)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: AppColor.cardShadow, radius: 4, x: 0, y: 1)
        }
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.lift)   // Apple Pencil hover preview on iPad
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.lift)   // Apple Pencil hover preview on iPad
    }
}

/// Adds Apple Pencil hover support to any clickable element.
/// Use on Buttons / NavigationLinks that don't go through the
/// AppPrimary/AppSecondary button styles. Beta feedback 2026-04-27:
/// "hover feature with iPencil doesn't work with buttons in the app."
extension View {
    /// Apple-recommended `.hoverEffect(.automatic)` so iPad / iPad Pro
    /// users with an Apple Pencil get a visual preview when the pencil
    /// tip is near the screen but not yet touching. Required because
    /// stock SwiftUI Buttons don't get hover effects for free — the
    /// modifier has to be applied explicitly.
    func appPencilHover() -> some View {
        self
            .contentShape(Rectangle())
            .hoverEffect(.automatic)
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

    /// Glass-effect card for translucent floating elements (iOS 26+, falls back to thin material).
    func glassCard() -> some View {
        modifier(GlassCardStyle())
    }

    /// Applies iOS 26 glass effect to a shape, falling back to thin material on older versions.
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Scaled metric for layout that respects Dynamic Type.
typealias AppScaled = ScaledMetric

// MARK: - Phone Number Formatting

/// Formats a raw digit string into (###) ###-#### as the user types.
func formatPhoneNumber(_ value: String) -> String {
    let digits = value.filter(\.isWholeNumber)
    let limited = String(digits.prefix(10))
    var result = ""
    for (i, ch) in limited.enumerated() {
        switch i {
        case 0: result.append("(")
            result.append(ch)
        case 2: result.append(ch)
            result.append(") ")
        case 5: result.append(ch)
            result.append("-")
        default: result.append(ch)
        }
    }
    return result
}

/// A `ViewModifier` that auto-formats a phone text binding to (###) ###-####.
struct PhoneNumberFormatter: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, newValue in
                let formatted = formatPhoneNumber(newValue)
                if formatted != newValue {
                    text = formatted
                }
            }
    }
}

extension View {
    func phoneFormatted(_ text: Binding<String>) -> some View {
        modifier(PhoneNumberFormatter(text: text))
    }
}

// MARK: - Decimal-Only Input Filter

/// Strips anything that isn't a digit or a single decimal point. `.keyboardType(.decimalPad)`
/// already covers the on-screen keypad, but doesn't catch paste, hardware keyboards, or
/// dictation — this binding wrapper does (T-01385).
func filterDecimal(_ value: String) -> String {
    var sawDot = false
    var out = ""
    for ch in value {
        if ch.isASCII && ch.isNumber {
            out.append(ch)
        } else if ch == "." && !sawDot {
            sawDot = true
            out.append(ch)
        }
    }
    return out
}

struct DecimalOnlyFilter: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, newValue in
                let filtered = filterDecimal(newValue)
                if filtered != newValue {
                    text = filtered
                }
            }
    }
}

extension View {
    func decimalFiltered(_ text: Binding<String>) -> some View {
        modifier(DecimalOnlyFilter(text: text))
    }
}
