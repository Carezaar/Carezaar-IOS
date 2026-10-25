import SwiftUI

/// A second attempt at an action that is still unresolved (see ActionGuard).
struct DuplicateActionError: Error, Equatable { let key: String }

/// Duplicate-action protection (client request, 25 Oct 2026): one shared guard for every
/// action that changes data. It is taken before the request starts (on the main actor, so the
/// check and the claim can't interleave), and a second attempt while the first is unresolved
/// (a double tap, a rebuilt view, the same screen opened again, another view) is rejected at
/// once, not queued. It is released when the action ends: success, failure or cancellation.
///
/// Keys are the signed-in account plus the resource, e.g. `match:<partner id>`: every action
/// on one match (request, accept, reject, withdraw, end) shares a guard, while other matches
/// and other operations stay usable. Views observe it to disable their control and show
/// progress on it.
@MainActor
final class ActionGuard: ObservableObject {
    static let shared = ActionGuard()
    @Published private(set) var running: Set<String> = []
    /// The signed-in account guards are scoped to (set by the session).
    var account = "signed-out" { didSet { objectWillChange.send() } }

    func key(_ resource: String) -> String { "\(account)|\(resource)" }
    func isBusy(_ resource: String) -> Bool { running.contains(key(resource)) }

    func run<T>(_ resource: String, _ work: () async throws -> T) async throws -> T {
        let key = key(resource)
        guard !running.contains(key) else { throw DuplicateActionError(key: key) }
        running.insert(key)
        defer { running.remove(key) }
        return try await work()
    }

    /// Test hook.
    func reset() { running = [] }
}

/// Errors as the red toast Android uses. There is no blocking "Please wait…" window any more
/// (client request, 25 Oct 2026): a first load shows a skeleton where its content goes, and an
/// action shows progress on its own control.
@MainActor
final class Feedback: ObservableObject {
    struct Toast: Identifiable, Equatable { let id = UUID(); let message: String }

    @Published private(set) var toasts: [Toast] = []

    func toast(_ message: String) {
        guard !message.isEmpty else { return }
        let toast = Toast(message: message)
        toasts.append(toast)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismiss(_ toast: Toast) { toasts.removeAll { $0.id == toast.id } }

    static let supportEmail = "support@carezaar.com"
    /// Server-driven copy lookup, installed by the app once `Localization` exists.
    static var translate: (String, String) -> String = { _, fallback in fallback }

    /// Inline reset-code presentation is separate from common/global failures.
    static func otpInlineMessage(_ error: Error) -> String? {
        guard let api = error as? APIError, !api.isServiceFault else { return nil }
        let text: String
        let fieldSpecific: Bool
        switch api {
        case .validation(let message, let fields):
            if let field = fields["otp"]?.first, !field.isEmpty {
                guard !APIError.unknown(field).isTechnical else { return nil }
                text = field
                fieldSpecific = true
            } else {
                guard message.localizedCaseInsensitiveContains("otp") else { return nil }
                text = message
                fieldSpecific = false
            }
        case .unknown(let message):
            guard message.localizedCaseInsensitiveContains("otp") else { return nil }
            text = message
            fieldSpecific = false
        default:
            // A service, authorization or transport error mentioning OTP is not
            // evidence that the user's code was rejected.
            return nil
        }
        if !fieldSpecific {
            // Match only recognizable code-rejection sentences, not arbitrary
            // diagnostics that happen to contain "OTP" and "invalid".
            let patterns = [
                #"^(?:(?:the|your|provided|the provided) )?(?:otp(?: code)?|code) (?:is |has |was )?(?:invalid|incorrect|wrong|expired|not valid)[.!]*$"#,
                #"^(?:invalid|incorrect|wrong|expired) (?:otp(?: code)?|code)[.!]*$"#
            ]
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard patterns.contains(where: { normalized.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
        }
        // Current CMS contents has no invalid/expired-code row. Keep safe inline
        // fallback copy; never display arbitrary raw service/error wording here.
        if text.localizedCaseInsensitiveContains("expired") {
            return "Your code has expired. Request a new code."
        }
        if ["invalid", "incorrect", "wrong", "not valid"].contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return "The code is invalid. Check it and try again."
        }
        return nil
    }

    /// Common/global failures use managed general copy. Useful field-specific
    /// validation remains server authored; technical field text is suppressed.
    static func message(_ error: Error) -> String {
        if error is DuplicateActionError || error is CancellationError { return "" }
        if let rejected = error as? AuthorizationRejectedMutationError { return message(rejected.cause) }
        let serverTrouble = translate("general_network_title", "Cannot communicate with server.")
        guard let api = error as? APIError else {
            return translate("general_error_general", "Something went wrong. Please try again.")
        }
        switch api {
        case .validation(_, let fields):
            // Deterministic field order, preserving useful validation without
            // exposing global/internal server wording as a common failure.
            // Route/account references are not editable inputs on these screens.
            let referenceFields: Set<String> = ["id", "partner_id", "chat_id", "match_id", "user_id"]
            if let value = fields.keys.sorted().filter({ !referenceFields.contains($0) })
                .flatMap({ fields[$0] ?? [] })
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !APIError.unknown($0).isTechnical }) {
                return value
            }
            return translate("general_error_general", "Something went wrong. Please try again.")
        case .connectionUnavailable, .network:
            return serverTrouble
        case .timeout:
            return serverTrouble
        case .unauthenticated, .forbidden:
            return translate("general_error_forbidden", "You can't do this right now.")
        case .decoding:
            return translate("general_error_general", "Something went wrong. Please try again.")
        case .notFound:
            return translate("general_error_not_found", "This item is no longer available.")
        case .server, .unknown:
            return translate("general_error_general", "Something went wrong. Please try again.")
        }
    }

    /// A known unavailable action uses the same managed permission/action copy as
    /// other rejected actions. The feature name is context, not an English suffix.
    static func unavailable(_ feature: String) -> String {
        translate("general_error_forbidden", "You can't do this right now.")
    }

}

/// Overlays the toasts above the whole app.
struct FeedbackOverlay: ViewModifier {
    @EnvironmentObject private var feedback: Feedback

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    ForEach(feedback.toasts) { toast in
                        HStack(spacing: 12) {
                            AppIcon(name: "ic_clear_circle", size: 28, tint: Theme.Palette.error)
                            Text(toast.message)
                                .font(Theme.Typography.control(14))
                                .foregroundStyle(Theme.Palette.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { feedback.dismiss(toast) } label: {
                                AppIcon(name: "ic_clear", size: 16, tint: Theme.Palette.error)
                            }
                            .accessibilityLabel("Dismiss")
                        }
                        .padding(14)
                        .background(Theme.Palette.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.Palette.error, lineWidth: 1.5))
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isStaticText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .animation(.default, value: feedback.toasts)
            }
    }
}

extension View {
    func feedbackOverlay() -> some View { modifier(FeedbackOverlay()) }
}
