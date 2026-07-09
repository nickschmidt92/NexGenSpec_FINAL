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
    /// Uppercase section/eyebrow label — pair with `.textCase(.uppercase).tracking(0.9)`.
    static let eyebrow = Font.system(.caption, design: .rounded).weight(.semibold)
    /// Instrument readouts (measurements, IDs, serials, timestamps). Add `.monospacedDigit()` on numeric values.
    static let mono = Font.system(.callout, design: .monospaced).weight(.medium)
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
}

/// Semantic colors. Adapts to light/dark; high contrast when enabled.
enum AppColor {
    // MARK: Brand colors (fixed, not adaptive)
    static let brandNavy = Color(red: 0.06, green: 0.08, blue: 0.15)      // #0F1426
    static let brandNavyHi = Color(red: 0.10, green: 0.13, blue: 0.24)    // #1A213D — gradient top step
    static let brandBlue = Color(red: 0.04, green: 0.29, blue: 0.78)      // #0A4AC7 — deep cobalt hero (white text ~6:1, AA)
    static let brandBlueDeep = Color(red: 0.03, green: 0.16, blue: 0.45)  // #082873 — button bottom stop / dark canvas
    static let brandBlueOnDark = Color(red: 0.30, green: 0.55, blue: 1.0) // #4D8CFF — cobalt text/icons on navy
    static let brandCyan = Color(red: 0.16, green: 0.78, blue: 0.92)      // #29C7EB

    // MARK: Semantic surface colors (adaptive light/dark)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .systemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    /// Hairline "machined" edge — faint cobalt in light, faint white in dark.
    static let border = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.08)
            : UIColor(red: 0.04, green: 0.29, blue: 0.78, alpha: 0.10)
    })
    static let cardBackground = elevatedSurface
    static let cardShadow = Color.black.opacity(0.06)
    /// Atmospheric canvas top stop (cobalt-tinted); paired with `background` at the bottom.
    static let canvasTop = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.043, green: 0.059, blue: 0.110, alpha: 1) // #0B0F1C
            : UIColor(red: 0.957, green: 0.965, blue: 0.984, alpha: 1) // #F4F6FB
    })

    // MARK: Accent and status colors
    /// Cobalt action color, legible in BOTH modes: #0A4AC7 light, #2E6BFF dark.
    /// Dynamic provider (NOT `.opacity`) so text/icon tints adapt instead of going muddy.
    static let actionBlue = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.42, blue: 1.0, alpha: 1)   // #2E6BFF
            : UIColor(red: 0.04, green: 0.29, blue: 0.78, alpha: 1)  // #0A4AC7
    })
    static let accent = actionBlue
    static let accentDeep = actionBlue
    /// Soft tint for pills/chips — dynamic alpha so it never goes muddy gray on navy.
    static let accentSoft = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.42, blue: 1.0, alpha: 0.22)
            : UIColor(red: 0.04, green: 0.29, blue: 0.78, alpha: 0.12)
    })
    static let highlight = Color(red: 0.95, green: 0.78, blue: 0.20)  // #F2C733 gold — near-black text only
    static let success = Color(red: 0.16, green: 0.50, blue: 0.33)    // #298054
    static let warning = Color(red: 0.90, green: 0.45, blue: 0.10)    // #E6731A construction orange
    static let critical = Color(red: 0.74, green: 0.18, blue: 0.20)   // #BD2E33

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
            colors: [brandNavy, brandBlueDeep],
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
            .background(
                LinearGradient(colors: [AppColor.brandBlue.opacity(0.04), AppColor.elevatedSurface],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppColor.border, lineWidth: 1)   // machined edge
            )
            .shadow(color: AppColor.cardShadow, radius: 10, x: 0, y: 4)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [AppColor.brandBlue, AppColor.brandBlueDeep],
                                             startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            )
            .shadow(color: AppColor.brandBlue.opacity(0.35), radius: 8, x: 0, y: 3)  // backlit-key glow
            .opacity(configuration.isPressed ? 0.90 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.lift)   // Apple Pencil hover preview on iPad
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.headline)
            .foregroundStyle(AppColor.actionBlue)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minHeight)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AppColor.actionBlue.opacity(0.30), lineWidth: 1)
                    )
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
            LinearGradient(colors: [AppColor.canvasTop, AppColor.background],
                           startPoint: .top, endPoint: .bottom)
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

/// Lightweight haptic feedback for key moments. No-ops gracefully off-device.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

/// Large, faint hexagon watermark echoing the logo — a decorative brand
/// signature for navy panels (onboarding, headers). Never over body text;
/// non-interactive and hidden from accessibility.
struct HexWatermark: View {
    var tint: Color = AppColor.brandCyan
    var opacity: Double = 0.07
    var lineWidth: CGFloat = 2

    var body: some View {
        HexagonShape()
            .stroke(tint.opacity(opacity), lineWidth: lineWidth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct HexagonShape: InsettableShape {
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
///
/// Separators are emitted BEFORE the digit that follows them, never after the
/// digit that precedes them, so the result never ends in a separator. This is
/// load-bearing: the onChange rewrite reformats on every keystroke, and a
/// trailing separator reformats to the identical string — backspace then
/// re-inserts what was just deleted and the field hard-locks (found in the
/// build-29 device smoke, 2026-07-09).
func formatPhoneNumber(_ value: String) -> String {
    let digits = value.filter(\.isWholeNumber)
    let limited = String(digits.prefix(10))
    var result = ""
    for (i, ch) in limited.enumerated() {
        switch i {
        case 0: result.append("(")
        case 3: result.append(") ")
        case 6: result.append("-")
        default: break
        }
        result.append(ch)
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
func filterDecimal(_ value: String,
                   decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String {
    // Keep the user's LOCALE decimal separator (e.g. "," in de_DE / fr_FR). The
    // previous code only accepted "." and silently stripped ",", so "49,50"
    // became "4950" — a 100x billing bug in comma-decimal locales (T-01449). The
    // other separator (the locale's thousands separator) and any stray character
    // are dropped. The separator is preserved verbatim so on-keypad editing
    // round-trips (canonicalizing to "." would make the next keystroke's "." get
    // stripped in a comma locale).
    var sawSeparator = false
    var out = ""
    for ch in value {
        if ch.isASCII && ch.isNumber {
            out.append(ch)
        } else if String(ch) == decimalSeparator && !sawSeparator {
            sawSeparator = true
            out.append(contentsOf: decimalSeparator)
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
