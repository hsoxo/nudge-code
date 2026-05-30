import SwiftUI

// MARK: - Design tokens (mirrors apps/landing/app/globals.css @theme)

extension Color {
    // Backgrounds
    static let appBg        = Color(hex: "#080b0f")
    static let surface      = Color(hex: "#0d1117")
    static let surface2     = Color(hex: "#161b22")

    // Borders
    static let border       = Color(hex: "#21262d")
    static let borderBright = Color(hex: "#30363d")

    // Text
    static let textPrimary  = Color(hex: "#e6edf3")
    static let textMuted    = Color(hex: "#8b949e")
    static let textSubtle   = Color(hex: "#484f58")

    // Accent — emerald
    static let accent       = Color(hex: "#00e5a0")
    static let accentDim    = Color(hex: "#00b37d")
    static let accentGlow   = Color(hex: "#00e5a0").opacity(0.15)
    static let accentGlowSm = Color(hex: "#00e5a0").opacity(0.08)

    // Danger (red)
    static let danger       = Color(hex: "#f85149")
    static let dangerDim    = Color(hex: "#f85149").opacity(0.16)
    static let dangerBorder = Color(hex: "#f85149").opacity(0.40)

    // Convenience init from hex string (#RRGGBB or #RRGGBBAA)
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let int = UInt64(hex, radix: 16) ?? 0
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >>  8) & 0xFF) / 255
            b = Double( int        & 0xFF) / 255
            a = 1
        case 8:
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >>  8) & 0xFF) / 255
            a = Double( int        & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Reusable view modifiers

extension View {
    /// Dark card with surface bg, border, corner radius, and a hairline glow.
    func surfaceCard(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(SurfaceCardModifier(cornerRadius: cornerRadius))
    }

    /// Accent-bordered card (glow-border-accent from the landing).
    func accentCard(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(AccentCardModifier(cornerRadius: cornerRadius))
    }
}

private struct SurfaceCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
            // Subtle inner glow matching .glow-border
            .shadow(color: Color.accent.opacity(0.04), radius: 0, x: 0, y: 0)
    }
}

private struct AccentCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accent.opacity(0.30), lineWidth: 1)
            )
            .shadow(color: Color.accentGlow, radius: 20, x: 0, y: 0)
    }
}

// MARK: - Grid + radial-glow background (hero aesthetic)

/// Full-bleed background that reproduces the landing hero:
/// near-black base + faint emerald grid + radial glow at top.
struct HeroBackground: View {
    var body: some View {
        ZStack {
            Color.appBg
                .ignoresSafeArea()
            // Faint emerald grid (landing .bg-grid)
            GridOverlay()
                .ignoresSafeArea()
            // Radial glow from top (landing .hero-glow)
            RadialGlowOverlay()
                .ignoresSafeArea()
        }
    }
}

private struct GridOverlay: View {
    private let spacing: CGFloat = 40
    private let lineOpacity: Double = 0.03

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x <= size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(Color.accent.opacity(lineOpacity)), lineWidth: 1)
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color.accent.opacity(lineOpacity)), lineWidth: 1)
                y += spacing
            }
        }
    }
}

private struct RadialGlowOverlay: View {
    var body: some View {
        GeometryReader { geo in
            // Elliptical gradient from the top-centre, matching
            // radial-gradient(ellipse 80% 50% at 50% -10%, rgba(0,229,160,0.12), transparent)
            EllipticalGradient(
                gradient: Gradient(colors: [
                    Color.accent.opacity(0.12),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadiusFraction: 0,
                endRadiusFraction: 0.65
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Pill badge (mono, emerald, like the landing hero badge)

struct PillBadge: View {
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentGlowSm)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.border, lineWidth: 1)
        )
    }
}
