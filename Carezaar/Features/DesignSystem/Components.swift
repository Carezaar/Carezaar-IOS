import SwiftUI

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(.white) }
            }
            .font(Theme.Typography.filledLabel())
            .foregroundStyle(isEnabled ? Color.white : Theme.Palette.disabledForeground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? Theme.Palette.primaryFill : Theme.Palette.disabledBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .disabled(!isEnabled || isLoading)
    }
}

struct OutlineButton: View {
    let title: String
    var tint: Color = Theme.Palette.primaryText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.control())
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .stroke(tint, lineWidth: 1))
        }
    }
}

// MARK: - Fields

struct LabeledField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var isSecure = false
    var error: String?

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Palette.textSecondary)

            HStack {
                Group {
                    if isSecure {
                        // UITextField's native placeholder is always one line. Keep
                        // the complete instruction visible when it needs to wrap.
                        ZStack(alignment: .leading) {
                            if text.isEmpty {
                                Text(placeholder)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            Group {
                                if isRevealed { TextField("", text: $text) }
                                else { SecureField("", text: $text) }
                            }
                            .frame(minHeight: 44)
                            .accessibilityLabel(label)
                            .accessibilityHint(placeholder)
                            .accessibilityIdentifier(placeholder)
                        }
                    } else {
                        TextField(placeholder, text: $text)
                            .accessibilityLabel(label)
                            .accessibilityHint(placeholder)
                            .accessibilityIdentifier(placeholder)
                    }
                }
                .font(Theme.Typography.control())
                .keyboardType(keyboard)
                .textContentType(contentType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)

                if isSecure {
                    Button { isRevealed.toggle() } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: 52)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .stroke(error == nil ? Theme.Palette.separator : Theme.Palette.error, lineWidth: 1))

            if let error {
                Text(error)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Palette.error)
            }
        }
    }
}

/// The live password checklist the Android app shows while typing.
struct PasswordRulesView: View {
    let password: String
    /// Content slug prefix, e.g. `settings_change_password` →
    /// `settings_change_password_password_validation_8_letters`.
    var prefix = "signup_credentials"
    @EnvironmentObject private var loc: Localization

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(PasswordValidator.rules(for: password)) { rule in
                HStack(spacing: 6) {
                    AppIcon(name: rule.isSatisfied ? "ic_check_circle" : "ic_clear_circle", size: 16,
                            tint: rule.isSatisfied ? Theme.Palette.success : Theme.Palette.textSecondary)
                    Text(loc.t("\(prefix)_password_validation_\(rule.id)", rule.label))
                        .font(Theme.Typography.caption(12))
                        .foregroundStyle(rule.isSatisfied ? Theme.Palette.successText : Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(rule.isSatisfied ? Color(hex: 0xE9F8F3) : Color(hex: 0xF3F4F6), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rule.label), \(rule.isSatisfied ? "met" : "not met")")
            }
        }
    }
}

/// The five compact rule chips of the sign-up frame (8+, A, a, 1, @), live.
struct RuleGlyphChips: View {
    let password: String
    private static let order = ["8_letters", "1_uppercase", "1_lowercase", "1_number", "1_special_symbol"]
    private static let glyph = ["8_letters": "8+", "1_uppercase": "A", "1_lowercase": "a", "1_number": "1", "1_special_symbol": "@"]

    var body: some View {
        HStack(spacing: 8) {
            // The frames order the chips 8+, A, a, 1, @.
            ForEach(PasswordValidator.rules(for: password).sorted { Self.order.firstIndex(of: $0.id) ?? 0 < Self.order.firstIndex(of: $1.id) ?? 0 }) { rule in
                HStack(spacing: 6) {
                    AppIcon(name: rule.isSatisfied ? "ic_check_circle" : "ic_radiobutton_off", size: 14,
                            tint: rule.isSatisfied ? Theme.Palette.success : Theme.Palette.textSecondary)
                    Text(Self.glyph[rule.id] ?? "").font(Theme.Typography.control(14))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(rule.isSatisfied ? Color(hex: 0xE9F8F3) : .white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(rule.isSatisfied ? Color(hex: 0xBFE9DA) : Theme.Palette.textSecondary.opacity(0.3)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rule.label), \(rule.isSatisfied ? "met" : "not met")")
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - State views

/// Full-screen states shared by every list and detail screen, so loading, empty and
/// error behaviour is identical across the app the way it is on Android.
struct LoadingState: View {
    var message: String?
    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
            if let message {
                Text(message)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyState: View {
    let title: String
    var message: String?
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(title)
                .font(Theme.Typography.title())
            if let message {
                Text(message)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    /// `general_try_again`
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Palette.error)
            Text(message)
                .font(Theme.Typography.body())
                .multilineTextAlignment(.center)
            if let retry {
                OutlineButton(title: "Try again", action: retry)
                    .frame(maxWidth: 200)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline banner for action failures that should not replace the whole screen.
struct ErrorBanner: View {
    let message: String
    var body: some View {
        Text(message)
            .font(Theme.Typography.body())
            .foregroundStyle(Theme.Palette.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xs)
            .background(Theme.Palette.error.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
    }
}

/// Remote avatar with a neutral placeholder. No human faces are generated — the
/// placeholder is a glyph.
struct Avatar: View {
    let url: String?
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    Theme.Palette.clientPanel
                    Image(systemName: "person.fill").foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Step indicator for the multi-step signup (`step_wizard_step`, `step_wizard_of`).
struct StepIndicator: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.Palette.primary : Theme.Palette.separator)
                    .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step) of \(total)")
    }
}

// MARK: - Bottom action

/// Tracks the software keyboard so a pinned bottom button can step aside while typing.
@MainActor
final class KeyboardState: ObservableObject {
    @Published private(set) var isVisible = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = true }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = false }
            },
        ]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private struct BottomAction<Bar: View>: ViewModifier {
    @StateObject private var keyboard = KeyboardState()
    @EnvironmentObject private var loc: Localization
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        // A bar pinned above the keyboard covers the field being typed into on smaller
        // phones; while the keyboard is up the form gets the space and scrolls the
        // focused field into view. The keyboard's own OK puts it away and brings the
        // action back.
        content
            .safeAreaInset(edge: .bottom) {
                if !keyboard.isVisible { bar() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(loc.t("general_ok", "OK")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .font(Theme.Typography.control(16))
                }
            }
    }
}

extension View {
    /// The screen's main action, pinned to the bottom except while typing.
    func bottomAction<Bar: View>(@ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        modifier(BottomAction(bar: bar))
    }
}
