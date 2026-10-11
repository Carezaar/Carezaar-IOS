import SwiftUI

/// Android shows one modal "Please wait…" card listing every in-flight operation
/// ("- Signing in", "- Getting list of chats - Page 1"), and errors as a red toast.
/// `run` reproduces that for every network call a screen makes.
@MainActor
final class Feedback: ObservableObject {
    struct Operation: Identifiable { let id = UUID(); let label: String }
    struct Toast: Identifiable, Equatable { let id = UUID(); let message: String }

    @Published private(set) var operations: [Operation] = []
    @Published private(set) var toasts: [Toast] = []

    private var running: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Any, Error>]] = [:]

    /// A second call from the same call site (or with the same explicit `key`) while
    /// the first is in flight waits for the first one's result instead of running
    /// again: a double tap sends one request. Different screens never share a key,
    /// even when their labels match. The first caller runs `work` itself, so
    /// cancellation still flows from the view's task as before.
    func run<T>(_ label: String, key: String? = nil, file: String = #fileID, line: Int = #line,
                _ work: () async throws -> T) async throws -> T {
        let key = key ?? "\(file):\(line)"
        if running.contains(key) {
            let shared = try await withCheckedThrowingContinuation { waiters[key, default: []].append($0) }
            if let value = shared as? T { return value }
            throw APIError.decoding("Unexpected result type.")
        }
        running.insert(key)
        let op = Operation(label: label)
        operations.append(op)
        defer {
            running.remove(key)
            operations.removeAll { $0.id == op.id }
        }
        do {
            let value = try await work()
            waiters.removeValue(forKey: key)?.forEach { $0.resume(returning: value) }
            return value
        } catch {
            waiters.removeValue(forKey: key)?.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    func toast(_ message: String) {
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
        let serverTrouble = translate("general_network_title", "Cannot communicate with server.")
        guard let api = error as? APIError else {
            return translate("error_unexpected", "Something went wrong. Please try again.")
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
            return translate("error_unavailable", "This isn't working right now. Please try again later.")
        case .network:
            return "\(serverTrouble) \(translate("error_check_connection", "Check your internet connection and try again."))"
        case .timeout:
            return "\(serverTrouble) \(translate("error_timeout", "Please try again."))"
        case .unauthenticated:
            return translate("error_session_expired", "Your session has expired. Please sign in again.")
        case .decoding:
            return translate("error_unexpected", "Something went wrong. Please try again.")
        case .server, .notFound, .unknown:
            return translate("error_unavailable", "This isn't working right now. Please try again later.")
        }
    }

    /// For actions the live server currently cannot complete: says so plainly and
    /// gives the support address instead of a misleading server message.
    static func unavailable(_ feature: String) -> String {
        "\(feature): \(translate("error_feature_unavailable", "this isn't available right now. Please contact")) \(supportEmail)."
    }
}

/// Overlays the busy card and toasts above the whole app.
struct FeedbackOverlay: ViewModifier {
    @EnvironmentObject private var feedback: Feedback
    @EnvironmentObject private var loc: Localization

    func body(content: Content) -> some View {
        content
            .overlay {
                if !feedback.operations.isEmpty {
                    ZStack {
                        Color.black.opacity(0.22).ignoresSafeArea()
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(loc.t("loading_please_wait", "Please wait..."))
                                    .font(Theme.Typography.title(17))
                            }
                            ForEach(feedback.operations) { op in
                                Text("- \(op.label)").font(Theme.Typography.body())
                            }
                        }
                        .padding(18)
                        .frame(minWidth: 260, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
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
