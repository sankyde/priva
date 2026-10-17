import SwiftUI

// MARK: - Buttons

/// The primary capsule: gradient fill, a glassy rim, a soft glow that tightens when pressed.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.primaryFill, in: .capsule)
            .overlay {
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                                       lineWidth: 1)
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .shadow(color: Theme.violet.opacity(configuration.isPressed ? 0.18 : 0.35), radius: configuration.isPressed ? 6 : 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Primary call to action.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if loading {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.body.weight(.semibold))
                }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(.white)
            .contentTransition(.opacity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!enabled || loading)
        .opacity(enabled ? 1 : 0.5)
        .animation(Theme.snappy, value: loading)
        .sensoryFeedback(.impact(weight: .light), trigger: loading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title).font(.headline) } icon: { if let systemImage { Image(systemName: systemImage) } }
                .frame(maxWidth: .infinity, minHeight: 44)       // + the glass padding = the primary button's 56
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

/// Round glass icon button (call controls, composer actions).
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 58
    var tint: Color?
    var active = false
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Color.black : Color.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { .regular.tint($0).interactive() } ?? (active ? .regular.tint(.white).interactive() : .regular.interactive()), in: .circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: active)
    }
}

// MARK: - Badges & chips

struct SecureChip: View {
    var text = "End-to-end encrypted"
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill").symbolRenderingMode(.hierarchical)
            Text(text).lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(Theme.mint)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 4 : 6)
        .background(Theme.mint.opacity(0.12), in: .rect(cornerRadius: compact ? 10 : 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct StatusGlyph: View {
    let status: Message.Status
    var onGradient = true

    var body: some View {
        Group {
            switch status {
            case .queued: Image(systemName: "clock")
            case .sending: Image(systemName: "arrow.up.circle")
            case .delivered: Image(systemName: "checkmark.circle")
            case .read: Image(systemName: "checkmark.circle.fill")
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.rose)
            case .received: EmptyView()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(onGradient ? .white.opacity(0.85) : Theme.textSecondary)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(status.accessibility)
    }
}

extension Message.Status {
    var accessibility: String {
        switch self {
        case .queued: return "Waiting on this iPhone until your friend is online"
        case .sending: return "Sending"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Failed"
        case .received: return ""
        }
    }
}

// MARK: - Containers

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Theme.violet

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Scrolls when large text doesn't fit, instead of cutting the words.
        ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content.frame(maxWidth: .infinity) }
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.aurora)
                .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glassProminent).tint(Theme.tint).padding(.top, 6)
            }
        }
        .padding(32)
    }
}

/// A slow repeating "breathe" (logo, incoming call). Off with Reduce Motion.
struct MotionPulse: ViewModifier {
    let to: CGFloat
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion { content } else {
            content.phaseAnimator([1.0, to]) { v, s in v.scaleEffect(s) } animation: { _ in .easeInOut(duration: duration) }
        }
    }
}

extension View {
    func motionPulse(to scale: CGFloat, duration: Double) -> some View { modifier(MotionPulse(to: scale, duration: duration)) }
}

struct OnboardingScaffold<Content: View, Footer: View>: View {
    var step: Int?
    var total = 5
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // At accessibility text sizes the buttons scroll with the content: pinned, they'd cover most of the screen.
        let inline = size.isAccessibilitySize
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let step {
                        HStack(spacing: 6) {
                            ForEach(0..<total, id: \.self) { i in
                                Capsule().fill(i <= step ? AnyShapeStyle(Theme.aurora) : AnyShapeStyle(Theme.hairline))
                                    .frame(width: i == step ? 26 : 8, height: 8)
                            }
                        }
                        .animation(Theme.snappy, value: step)
                        .accessibilityLabel("Step \(step + 1) of \(total)")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.screenTitle).foregroundStyle(Theme.textPrimary)
                        Text(subtitle).font(.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    content
                    if inline { VStack(spacing: 10) { footer }.padding(.top, 8) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            if !inline {
                VStack(spacing: 10) { footer }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 12)
                    .background(alignment: .top) {
                        // Content scrolling under the footer fades out instead of being cut mid-line.
                        LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28).offset(y: -28).allowsHitTesting(false)
                    }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - Inputs

struct PasswordField: View {
    let title: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var submit: (() -> Void)?
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Theme.textTertiary)
            Group {
                if reveal {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            // Priva's password must never go to iCloud Keychain. With no content type, iOS still guesses "new
            // password" from two secure fields and offers "Use Strong Password… saved in Passwords" (seen on a real
            // iPhone). The one-time-code type turns off strong-password offers, saved-password
            // suggestions and "Save Password?".
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(focused)
            .submitLabel(.go)
            .onSubmit { submit?() }
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
            }
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.surface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused.wrappedValue ? Theme.violet : Theme.hairline, lineWidth: focused.wrappedValue ? 1.5 : 0.5))
        .animation(Theme.snappy, value: focused.wrappedValue)
    }
}

struct StrengthMeter: View {
    let assessment: PasswordPolicy.Assessment
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(i <= assessment.score && !assessment.label.isEmpty ? color : Theme.hairline).frame(height: 5)
                }
            }
            Text(assessment.label).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .animation(Theme.snappy, value: assessment.score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(assessment.label)")
    }

    private var color: Color {
        switch assessment.score {
        case 0: return Theme.rose
        case 1: return Theme.amber
        case 2: return Theme.cyan
        default: return Theme.mint
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let title: String
    let message: String
    var body: some View {
        HStack(spacing: 12) {
            PrivaMark(glow: false).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shake animation for invalid input.
    func shake(_ trigger: Int) -> some View { modifier(ShakeEffect(animatableData: CGFloat(trigger))) }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

enum Format {
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.doesRelativeDateFormatting = true; f.dateStyle = .medium; f.timeStyle = .none; return f }()

    static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    static func bytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false      // "0 KB", not "Zero KB"
        return f.string(fromByteCount: Int64(n))
    }
}


// MARK: - Settings building blocks

/// Rounded, tinted icon tile (the leading glyph of a settings row).
struct IconTile: View {
    let systemImage: String
    var color: Color = Theme.violet
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A navigation row: tile, title, optional value on the right.
struct SettingsRow: View {
    let title: String
    let systemImage: String
    var color: Color = Theme.violet
    var value: String? = nil
    var valueColor: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: systemImage, color: color)
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(valueColor).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One short line of caution: a risk worth knowing about, not an error.
struct WarningNote: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = Theme.amber

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.textSecondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

/// Numbered word grid for recovery phrases and backup keys.
struct WordGrid: View {
    let words: [String]
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        // A secret word is never cut short: one column at large text sizes, and cells grow instead of truncating.
        let columns = size >= .xxxLarge ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(w).font(.system(.body, design: .monospaced).weight(.medium)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 44)
                .background(Theme.surface, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: ", "))
    }
}

/// Large circular status glyph used at the top of setup/result screens.
struct HeroGlyph: View {
    let systemImage: String
    var color: Color = Theme.violet
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.14)).frame(width: 112, height: 112)
            Circle().stroke(color.opacity(0.25), lineWidth: 1).frame(width: 112, height: 112)
            Image(systemName: systemImage).font(.system(size: 44, weight: .semibold)).foregroundStyle(color.gradient)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
    }
}


// MARK: - Screen capture shield

/// Covers content while the screen is recorded, mirrored (AirPlay) or captured over a cable. Applied to the whole app
/// and again to every separately presented screen (sheets and full-screen covers sit above the app's own views).
struct CaptureShield: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.overlay { if model.screenCaptured { CaptureCoverView().transition(.opacity) } }
            .animation(.easeOut(duration: 0.15), value: model.screenCaptured)
    }
}

struct CaptureCoverView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "eye.slash.circle.fill").font(.system(size: 54)).foregroundStyle(Theme.aurora)
                Text("Hidden while your screen is shared").font(.headline).foregroundStyle(Theme.textPrimary)
                Text("Priva hides everything while the screen is recorded or mirrored. Stop sharing to continue.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func hiddenWhileCaptured() -> some View { modifier(CaptureShield()) }
}
