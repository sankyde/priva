import SwiftUI

/// Design tokens. Dark-first "midnight + aurora" palette; every token has a light-mode twin.
enum Theme {
    // Brand. Status colours are darker in light mode: as text they meet WCAG AA (4.5:1) on every surface, the
    // bright dark-mode tones were 1.6–2.7:1 on white.
    static let violet = Color(light: 0x5241E6, dark: 0x6C5CFF)
    static let violetLight = Color(hex: 0x8B7BFF)
    /// Violet as text and control tint: lighter in dark mode so it reads at 4.5:1 on dark surfaces (and white on it
    /// stays ≥ 3.8:1 for bold button labels).
    static let tint = Color(light: 0x5241E6, dark: 0x7B6CFF)
    /// Call buttons keep their deep tones in both modes: a white glyph on the bright dark-mode mint was 1.8:1.
    static let callAccept = Color(hex: 0x0A6F47)
    static let callDecline = Color(hex: 0xC8264A)
    static let cyan = Color(light: 0x006C9E, dark: 0x3EC6FF)
    static let mint = Color(light: 0x0A6F47, dark: 0x3DDC97)
    static let amber = Color(light: 0x935800, dark: 0xFFB547)
    static let rose = Color(light: 0xC8264A, dark: 0xFF5C7A)

    static let aurora = LinearGradient(colors: [violetLight, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let auroraSoft = LinearGradient(colors: [violet.opacity(0.9), Color(hex: 0x5145E5)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The primary button: violet into indigo, top to bottom. White text stays ≥ 3:1 (bold) at the lightest point.
    static let primaryFill = LinearGradient(colors: [Color(light: 0x6A4CF5, dark: 0x7C6BFF), Color(light: 0x4338CA, dark: 0x4F46E5)],
                                            startPoint: .top, endPoint: .bottom)

    // Surfaces: dark mode is layered (background < surface < surface2) rather than pure black,
    // so cards and rows keep their edges on OLED screens.
    static let background = Color(light: 0xF4F5FA, dark: 0x0A0B10)
    static let surface = Color(light: 0xFFFFFF, dark: 0x15171F)
    static let surface2 = Color(light: 0xECEEF5, dark: 0x1E212B)
    // Increase Contrast gets stronger secondary text and edges (the system parts change by themselves).
    static let hairline = Color(light: 0xE0E2EC, dark: 0x2A2E3B, highLight: 0xB9BDCC, highDark: 0x4A4F60)
    static let incomingBubble = Color(light: 0xE9EBF3, dark: 0x1F2230)
    static let textPrimary = Color(light: 0x0B0C16, dark: 0xF4F5FA)
    static let textSecondary = Color(light: 0x5A5F76, dark: 0x9EA3B8, highLight: 0x3F4459, highDark: 0xC3C7D6)
    static let textTertiary = Color(light: 0x646980, dark: 0x858BA0, highLight: 0x4A4F66, highDark: 0xAEB3C4)  // ≥ 4.5:1 on every surface

    // Motion: springs tuned to feel quick but physical. Looping effects and slide-ins check Reduce Motion where
    // they're used (MotionPulse, EmptyStateView, TypingBubble, chat and banner transitions).
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.86)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)

    // Geometry
    static let radius: CGFloat = 22
    static let bubbleRadius: CGFloat = 20
    static let gutter: CGFloat = 20
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    init(light: UInt32, dark: UInt32, highLight: UInt32? = nil, highDark: UInt32? = nil) {
        self.init(uiColor: adaptiveColor(light: light, dark: dark, highLight: highLight ?? light, highDark: highDark ?? dark))
    }
}

/// SwiftUI resolves dynamic colours on its render thread too, so the provider must not be main-actor
/// isolated (an isolated closure traps on the runtime isolation check mid-animation).
nonisolated private func adaptiveColor(light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32) -> UIColor {
    UIColor { @Sendable t in
        let high = t.accessibilityContrast == .high
        let hex = t.userInterfaceStyle == .dark ? (high ? highDark : dark) : (high ? highLight : light)
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    static let brandTitle = Font.system(size: 40, weight: .bold, design: .rounded)
    static let screenTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
}

/// The Priva mark, drawn from the same geometry as the app icon (1024-unit design space).
struct PrivaMark: View {
    var glow = true
    var monochrome: Color?

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 1024
            ZStack {
                stemAndBowl
                    .stroke(style: StrokeStyle(lineWidth: 132, lineCap: .round, lineJoin: .round))
                    .fill(monochrome.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.aurora))
                if monochrome == nil {
                    highlight.stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                }
                keyhole
                    .fill(monochrome.map { AnyShapeStyle($0.opacity(0.8)) } ?? AnyShapeStyle(Color(hex: 0xEFFFF8)))
                    .shadow(color: glow && monochrome == nil ? Theme.mint.opacity(0.9) : .clear, radius: 40)
            }
            .frame(width: 1024, height: 1024)
            .scaleEffect(s, anchor: .topLeading)
            .offset(x: -60 * s, y: -22 * s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var stemAndBowl: Path {
        Path { p in
            p.move(to: CGPoint(x: 392, y: 796))
            p.addLine(to: CGPoint(x: 392, y: 452))
            p.addArc(center: CGPoint(x: 572, y: 452), radius: 180, startAngle: .degrees(180), endAngle: .degrees(540), clockwise: false)
        }
    }

    private var highlight: Path {
        Path { p in
            p.addArc(center: CGPoint(x: 572, y: 452), radius: 222, startAngle: .radians(.pi * 1.12), endAngle: .radians(.pi * 1.62), clockwise: false)
        }
    }

    private var keyhole: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 524, y: 360, width: 96, height: 96))
            p.move(to: CGPoint(x: 548, y: 420))
            p.addLine(to: CGPoint(x: 596, y: 420))
            p.addLine(to: CGPoint(x: 612, y: 540))
            p.addQuadCurve(to: CGPoint(x: 532, y: 540), control: CGPoint(x: 572, y: 556))
            p.closeSubpath()
        }
    }
}

/// Deterministic, colourful avatar from a username (no photos are ever exchanged).
struct Avatar: View {
    let name: String
    var size: CGFloat = 48
    var online = false

    private var palette: (Color, Color) {
        let h = name.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        // Deep enough that the white initial reads (≥ 3:1, large text) on every pair.
        let pairs: [(UInt32, UInt32)] = [(0x5241E6, 0x2E8FD0), (0xD63F72, 0xE07A1F), (0x13895A, 0x1D7FB8), (0x7D46E0, 0xC23FA8),
                                         (0xD9572B, 0xC8264A), (0x3B6FD8, 0x5241E6), (0x10857A, 0x13895A), (0xC77A00, 0xD9572B)]
        let p = pairs[Int(h % UInt32(pairs.count))]
        return (Color(hex: p.0), Color(hex: p.1))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            if online {
                Circle()
                    .fill(Theme.mint)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(Theme.background, lineWidth: max(2, size * 0.05)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityLabel(online ? "\(name), online" : name)
    }
}


/// App appearance. Stored outside the vault so the lock screen follows it too.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "Automatic" : self == .light ? "Light" : "Dark" }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
    static let storageKey = "priva.appearance"
}
