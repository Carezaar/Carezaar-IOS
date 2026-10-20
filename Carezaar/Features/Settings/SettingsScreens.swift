import SwiftUI

// MARK: - Help center

struct HelpCenterView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var loc: Localization
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppIcon(name: "ic_message", size: 96, tint: Theme.Palette.primaryDark).padding(.top, 16)
                Text(loc.t("contact_support_subtitle", "We are here to help")).font(Theme.Typography.heading(22))
                Text(loc.t("contact_support_description", "")).font(Theme.Typography.body(14))
                    .foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    MenuRow(icon: "ic_email", title: loc.t("contact_support_email_title", "Email Us"),
                            description: "support@carezaar.com · \(loc.t("contact_support_email_description", "We will respond within 24 hours."))",
                            tint: Theme.Palette.primaryDark) {
                        if let url = URL(string: "mailto:support@carezaar.com") { openURL(url) }
                    }
                }
                .card(padding: 0)
                // Report an Issue lives only on the Profile tab (client request,
                // October 2026); Delete Account lives here, as in Android's design.
            }
            .padding(20).padding(.bottom, 70)
        }
        .bottomAction {
            Button(role: .destructive) { router.push(.deleteAccount) } label: {
                Label(loc.t("profile_delete_account_title", "Delete Account"), systemImage: "trash")
                    .font(Theme.Typography.control(15)).foregroundStyle(Theme.Palette.error)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.vertical, 8).background(.white)
        }
        .backHeader(loc.t("contact_support_title", "Help Center"))
    }
}

typealias ContactSupportView = HelpCenterView

// MARK: - FAQ

struct FAQView: View {
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    private var faqs: [Faq] { baseData.faqs }
    private var categories: [FaqCategory] { baseData.faqCategories }
    @State private var active: Int?
    @State private var expanded: Set<Int> = []
    private static let allChip = "faq-category-all"

    var body: some View {
        ScrollView {
            if baseData.isReady {
                VStack(alignment: .leading, spacing: 12) {
                    // In right-to-left languages a strip wider than the screen can open at its
                    // far end, leaving the selected "All" chip off-screen (seen in Farsi), so
                    // bring the first chip into view on appear and on language change.
                    ScrollViewReader { strip in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip(loc.t("general_all", "All"), on: active == nil) { active = nil }
                                    .id(Self.allChip)
                                ForEach(categories) { c in
                                    chip(pick(c.translations.map { ($0.languageId, $0.title) }) ?? "", on: active == c.id) { active = c.id }
                                }
                            }
                        }
                        .onAppear { strip.scrollTo(Self.allChip) }
                        .onChange(of: loc.languageId) { strip.scrollTo(Self.allChip) }
                    }
                    ForEach(faqs.filter { active == nil || $0.faqCategoryId == active }) { f in
                        let question = pick(f.translations.map { ($0.languageId, $0.question ?? "") }) ?? ""
                        let answer = pick(f.translations.map { ($0.languageId, $0.answer ?? "") }) ?? ""
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                if expanded.contains(f.id) { expanded.remove(f.id) } else { expanded.insert(f.id) }
                            } label: {
                                HStack {
                                    Text(question).font(Theme.Typography.title(15)).foregroundStyle(.black).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: expanded.contains(f.id) ? "chevron.up" : "chevron.down").foregroundStyle(Theme.Palette.primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(expanded.contains(f.id) ? [.isSelected] : [])
                            if expanded.contains(f.id) {
                                Text(Self.html(answer)).font(Theme.Typography.body(14)).foregroundStyle(Color(hex: 0x333333))
                            }
                        }
                        .card(padding: 14)
                    }
                }
                .padding(20)
            } else {
                ProgressView().padding(40)
            }
        }
        .backHeader(loc.t("profile_faq_title", "FAQ"))
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.Typography.control(14)).foregroundStyle(on ? .white : Theme.Palette.primaryDark)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Theme.Palette.primary : Theme.Palette.clientPanel, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func pick(_ values: [(Int, String)]) -> String? {
        values.first { $0.0 == loc.languageId }?.1 ?? values.first { $0.0 == 1 }?.1 ?? values.first?.1
    }

    /// Answers are authored HTML from the Carezaar admin. Block tags become line
    /// breaks, other tags are dropped and the common entities decoded — enough for
    /// the paragraphs and lists the admin produces, without WebKit in `body`.
    static func html(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(p|div|li|h[1-6])>|<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


}

// MARK: - Report an issue

struct ReportAnIssueView: View {
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var issues: [Issue]?
    @State private var error: Error?
    @State private var composing = false
    @StateObject private var issueSubmission = IssueSubmissionCoordinator()

    var body: some View {
        ScrollView {
            if let error {
                ErrorState(message: Feedback.message(error)) { Task { await load() } }
            } else if let issues, issues.isEmpty {
                VStack(spacing: 10) {
                    AppIcon(name: "illus_report", size: 160)
                    Text(loc.t("report_an_issue_no_issues_found", "No issues found")).font(Theme.Typography.title(18))
                    Text(loc.t("report_an_issue_empty_description", "")).font(Theme.Typography.body(14))
                        .foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
                }
                .padding(40)
            } else if let issues {
                LazyVStack(spacing: 14) { ForEach(issues) { card($0) } }.padding(20).padding(.bottom, 80)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { composing = true } label: {
                AppIcon(name: "ic_add_circle", size: 34, tint: .white)
                    .frame(width: 62, height: 62).background(Theme.Palette.primary, in: Circle()).shadow(radius: 4, y: 2)
            }
            .padding(24)
            .accessibilityLabel(loc.t("report_an_issue_title", "Report An Issue"))
        }
        .backHeader(loc.t("report_an_issue_title", "Report An Issue"))
        .task { await load() }
        .sheet(isPresented: $composing) {
            IssueComposer(submission: issueSubmission, existingIssues: issues) {
                composing = false; Task { await load() }
            }
                .presentationDetents([.large])
        }
    }

    private func card(_ i: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(i.issuetypeId.map { id in loc.label(baseData.items(.issuetypes).first { $0.id == id }) } ?? (i.title ?? ""))
                    .font(Theme.Typography.title(16))
                Spacer()
                HStack(spacing: 4) {
                    AppIcon(name: i.isReplied ? "ic_check_circle" : "ic_timer", size: 16, tint: i.isReplied ? Theme.Palette.success : Theme.Palette.primary)
                    Text(i.isReplied ? loc.t("report_an_issue_status_resolved", "Resolved") : loc.t("report_an_issue_status_pending", "Pending"))
                        .font(Theme.Typography.control(12))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(i.isReplied ? Color(hex: 0xE9F8F3) : Theme.Palette.primarySoft, in: Capsule())
            }
            if i.issuetypeId != nil, let title = i.title, !title.isEmpty { Text(title).font(Theme.Typography.control(14)) }
            Text(i.description ?? "").font(Theme.Typography.body(14))
            Text(ServerTime.local(i.createdAt)).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let reply = i.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("report_an_issue_admin", "Administrator")).font(Theme.Typography.title(14))
                    Text(reply).font(Theme.Typography.body(14))
                    Text(i.repliedAt ?? "").font(Theme.Typography.caption()).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(12).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .card(padding: 14)
    }

    private func load() async {
        error = nil
        do {
            issues = try await feedback.run(loc.t("loading_user_issues_get", "Getting reported issues")) { try await UserService().issues() }
        } catch { self.error = error }
    }
}

/// Issue type from `base/issuetypes`, or "Other" with a free subject — the backend
/// takes either `issuetype_id` or `title`, never both.
private struct IssueComposer: View {
    @ObservedObject var submission: IssueSubmissionCoordinator
    let existingIssues: [Issue]?
    let onDone: () -> Void
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var typeId: Int?
    @State private var subject = ""
    @State private var description = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    AppIcon(name: "ic_upload", size: 20, tint: .black)
                    Text(loc.t("report_an_issue_title", "Report An Issue")).font(Theme.Typography.title(20))
                }
                Text(loc.t("report_an_issue_type_label", "Issue type")).font(Theme.Typography.control(15))
                Menu {
                    ForEach(baseData.items(.issuetypes)) { it in Button(loc.label(it)) { typeId = it.id } }
                    Button(loc.t("report_an_issue_type_other", "Other")) { typeId = nil }
                } label: {
                    HStack {
                        Text(typeId.map { id in loc.label(baseData.items(.issuetypes).first { $0.id == id }) } ?? loc.t("report_an_issue_type_other", "Other"))
                            .foregroundStyle(.black)
                        Spacer()
                        Image(systemName: "chevron.down").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(14).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.line))
                }
                if typeId == nil {
                    LabeledField(label: loc.t("report_an_issue_subject_label", "Subject"),
                                 placeholder: loc.t("report_an_issue_subject_placeholder", "Enter your issue subject..."), text: $subject)
                }
                Text(loc.t("report_an_issue_description_label", "Description")).font(Theme.Typography.control(15))
                TextField(loc.t("report_an_issue_description_placeholder", "Write your issue here..."), text: $description, axis: .vertical)
                    .lineLimit(4...8).padding(14).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.line))
                PrimaryButton(title: loc.t("report_an_issue_submit_button", "Submit")) { Task { await submit() } }
                    .disabled(submission.submitting)
            }
            .padding(20)
        }
        .feedbackOverlay()
    }

    private func submit() async {
        let required = loc.t("general_required", "This field is required.")
        if typeId == nil && subject.trimmingCharacters(in: .whitespaces).isEmpty {
            feedback.toast("\(loc.t("report_an_issue_subject_label", "Subject")): \(required)"); return
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            feedback.toast("\(loc.t("report_an_issue_description_label", "Description")): \(required)"); return
        }
        let owner = session.state.user?.id, generation = TokenStore.shared.generation
        guard owner != nil else { return }
        do {
            _ = try await feedback.run(loc.t("loading_user_issues_create", "Reporting a new issue")) {
                try await submission.submit(IssueSubmissionDraft(issuetypeId: typeId,
                    title: typeId == nil ? subject.trimmingCharacters(in: .whitespaces) : nil,
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines)), baseline: existingIssues, generation: generation)
            }
            guard owner == session.state.user?.id, generation == TokenStore.shared.generation else { return }
            onDone()
        } catch is CancellationError { }
        catch let error as APIError where error.isServiceFault {
            feedback.toast(Feedback.unavailable(loc.t("report_an_issue_title", "Report An Issue")))
        } catch { feedback.toast(Feedback.message(error)) }
    }
}

/// Exact issue fields submitted by the native composer, not server diagnostic copy.
struct IssueSubmissionDraft: Hashable, Sendable {
    let issuetypeId: Int?
    let title: String?
    let description: String
}

/// Public workflow seam wired to the real native issue composer.
@MainActor
final class IssueSubmissionCoordinator: ObservableObject {
    private let service: UserService
    init(service: UserService = UserService()) { self.service = service }

    @Published private(set) var submitting = false
    private struct Pending {
        let existingIDs: Set<Int>
        let error: Error
    }
    private struct Key: Hashable { let generation: UUID; let draft: IssueSubmissionDraft }
    private var pending: [Key: Pending] = [:]

    func submit(_ draft: IssueSubmissionDraft, baseline: [Issue]?, generation: UUID? = nil) async throws -> Issue {
        guard !submitting else { throw APIError.unknown("") }
        submitting = true
        defer { submitting = false }
        let owner = await service.client.credentialGeneration()
        guard generation == nil || generation == owner else { throw CancellationError() }
        let key = Key(generation: owner, draft: draft)
        if let unresolved = pending[key] { return try await reconcile(key, pending: unresolved) }
        let existing: [Issue]
        if let baseline { existing = baseline } else { existing = try await service.issues(ifGeneration: owner) }
        do {
            return try await service.createIssue(issuetypeId: draft.issuetypeId,
                                                  title: draft.title, description: draft.description, ifGeneration: owner)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard MutationOutcome.mayHaveCommitted(error) else { throw error }
            let unresolved = Pending(existingIDs: Set(existing.map(\.id)), error: error)
            pending[key] = unresolved
            return try await reconcile(key, pending: unresolved)
        }
    }

    private func reconcile(_ key: Key, pending unresolved: Pending) async throws -> Issue {
        let draft = key.draft
        let issues: [Issue]
        do { issues = try await service.issues(ifGeneration: key.generation) }
        catch is CancellationError { throw CancellationError() }
        catch { throw unresolved.error }
        guard let saved = issues.first(where: {
            !unresolved.existingIDs.contains($0.id) && $0.issuetypeId == draft.issuetypeId
                && (draft.issuetypeId != nil || $0.title == draft.title) && $0.description == draft.description
        }) else { throw unresolved.error }
        pending.removeValue(forKey: key)
        return saved
    }
}

// MARK: - Change language

struct ChangeLanguageView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var language: AppLanguage
    @EnvironmentObject private var loc: Localization
    @State private var choice: Int?

    static let flags = ["en": "ic_flag_us", "sp": "ic_flag_es", "ar": "ic_flag_sa", "fr": "ic_flag_fr",
                        "fa": "ic_flag_ir", "cn": "ic_flag_cn", "in": "ic_flag_in", "ru": "ic_flag_ru"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AppIcon(name: "ic_language", size: 34, tint: Theme.Palette.primaryDark)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("settings_change_language_app_title", "App Language")).font(Theme.Typography.title(16))
                        Text(loc.t("settings_change_language_app_description", "")).font(Theme.Typography.caption(13))
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 14))
                Text(loc.t("settings_change_language_available", "Available Languages")).font(Theme.Typography.title(17))
                VStack(spacing: 0) {
                    ForEach(baseData.languages) { l in
                        let on = (choice ?? language.id) == l.id
                        Button { choice = l.id } label: {
                            HStack(spacing: 14) {
                                AppIcon(name: Self.flags[l.code], size: 30)
                                Text(l.name).font(Theme.Typography.title(16)).foregroundStyle(.black)
                                Spacer()
                                AppIcon(name: on ? "ic_radiobutton_on" : "ic_radiobutton_off", size: 24, tint: Theme.Palette.primary)
                            }
                            .padding(16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                        Divider()
                    }
                }
                .card(padding: 0)
            }
            .padding(20).padding(.bottom, 80)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: loc.t("settings_change_language_save", "Save Changes")) {
                if let id = choice, let next = baseData.languages.first(where: { $0.id == id }) { language.select(next) }
                router.pop()
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
        .backHeader(loc.t("settings_change_language_title", "Change Language"))
    }
}

// MARK: - Change password

/// Calls `users/password/change` as Android does; the server's answer is shown.
struct ChangePasswordView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var current = ""
    @State private var updated = ""
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var submitting = false

    private var valid: Bool { !current.isEmpty && PasswordValidator.isValid(updated) && updated == confirmation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledField(label: loc.t("settings_change_password_current_password", "Current Password"),
                             placeholder: loc.t("settings_change_password_current_password_placeholder", "Enter your current password..."),
                             text: $current, contentType: .password, isSecure: true)
                LabeledField(label: loc.t("settings_change_password_new_password", "New Password"),
                             placeholder: loc.t("settings_change_password_new_password_placeholder", "Enter your new password..."),
                             text: $updated, contentType: .newPassword, isSecure: true)
                PasswordRulesView(password: updated, prefix: "settings_change_password")
                LabeledField(label: loc.t("settings_change_password_confirm_password", "Confirm Password"),
                             placeholder: loc.t("settings_change_password_confirm_password_placeholder", "Confirm your new password..."),
                             text: $confirmation, contentType: .newPassword, isSecure: true,
                             error: !confirmation.isEmpty && confirmation != updated ? loc.t("signup_credentials_password_match", "Passwords do not match.") : nil)
            }
            .padding(20)
        }
        // On smaller phones the keyboard covers the last field; dragging the form down
        // puts the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .bottomAction {
            PrimaryButton(title: loc.t("settings_change_password_change_password", "Change Password"), isEnabled: valid && !submitting) { confirming = true }
                .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
        .backHeader(loc.t("settings_change_password_title", "Change Password"))
        .alert(loc.t("settings_change_password_dialog_title", "Are you sure?"), isPresented: $confirming) {
            Button(loc.t("settings_change_password_dialog_deny", "Cancel"), role: .cancel) {}
            Button(loc.t("settings_change_password_dialog_confirm", "Confirm")) { Task { await submit() } }
        } message: {
            Text(loc.t("settings_change_password_dialog_message", "You are going to change your password."))
        }
    }

    private func submit() async {
        guard valid, !submitting else { return }
        submitting = true
        defer { submitting = false }
        do {
            try await feedback.run(loc.t("loading_user_password_change", "Changing password")) {
                try await session.changePassword(current: current, new: updated)
            }
            current = ""
            updated = ""
            confirmation = ""
        } catch let error as APIError where error.isServiceFault {
            feedback.toast(Feedback.unavailable(loc.t("settings_change_password_title", "Change Password")))
        } catch { feedback.toast(Feedback.message(error)) }
    }
}

// MARK: - Delete account

struct DeleteAccountView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var reasonId: Int?
    @State private var aware = false

    /// Reason codes are role-prefixed (`client_…`, `caregiver_…`); show the user's own.
    private var reasons: [BaseItem] {
        let prefix = "\((session.role ?? .client).rawValue)_"
        let own = baseData.items(.reasons).filter { $0.code?.hasPrefix(prefix) == true }
        return own.isEmpty ? baseData.items(.reasons) : own
    }

    private let lose = ["delete_account_data_profile", "delete_account_data_matches", "delete_account_data_messages",
                        "delete_account_data_favorites", "delete_account_data_settings"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    AppIcon(name: "ic_trash", size: 72, tint: Theme.Palette.danger)
                    Text(loc.t("delete_account_subtitle", "Delete Your Account?")).font(Theme.Typography.heading(22))
                    Text(loc.t("delete_account_description", "")).font(Theme.Typography.body(14))
                        .foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 12) {
                    AppIcon(name: "ic_alert", size: 28, tint: Theme.Palette.danger)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("delete_account_alert_title", "This action cannot be undone")).font(Theme.Typography.title(15))
                        Text(loc.t("delete_account_alert_description", "")).font(Theme.Typography.caption(13))
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 10) {
                    Text(loc.t("delete_account_data_title", "What you will lose")).font(Theme.Typography.title(16))
                    ForEach(lose, id: \.self) { slug in
                        HStack(spacing: 8) {
                            AppIcon(name: "ic_clear_circle", size: 18, tint: Theme.Palette.danger)
                            Text(loc.t(slug, "")).font(Theme.Typography.body(14))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
                // Android's screen says "Optional", but its delete call takes a non-optional
                // reason id; the reason is required here, as on the web.
                (Text(loc.t("delete_account_reason_title", "Why are you deleting your account?"))
                 + Text(" *").foregroundColor(Theme.Palette.error))
                    .font(Theme.Typography.control(15))
                Menu {
                    ForEach(reasons) { r in Button(loc.label(r)) { reasonId = r.id } }
                } label: {
                    HStack {
                        Text(reasonId.map { id in loc.label(baseData.items(.reasons).first { $0.id == id }) }
                             ?? loc.t("delete_account_reason_placeholder", "Select a reason"))
                            .foregroundStyle(reasonId == nil ? Theme.Palette.textSecondary : .black)
                        Spacer()
                        Image(systemName: "chevron.down").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(14).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.line))
                }
                Button { aware.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        AppIcon(name: aware ? "ic_checkbox_on" : "ic_checkbox_off", size: 22, tint: aware ? Theme.Palette.primary : Theme.Palette.textSecondary)
                        Text(loc.t("delete_account_confirm", "I am aware of the consequences of this decision."))
                            .font(Theme.Typography.body(14)).foregroundStyle(.black).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(aware ? [.isSelected] : [])
            }
            .padding(20).padding(.bottom, 80)
        }
        .safeAreaInset(edge: .bottom) {
            AdaptiveStack(alignment: .center, spacing: 12, stackedSpacing: 8) {
                WideButton(title: loc.t("delete_account_action_cancel", "Cancel"), style: .outline) { router.pop() }
                WideButton(title: loc.t("delete_account_action_delete", "Delete Account"), style: .danger,
                           enabled: aware && reasonId != nil) { Task { await submit() } }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
        .backHeader(loc.t("delete_account_title", "Delete Account"))
    }

    private func submit() async {
        guard let reasonId else { return }
        do {
            try await feedback.run(loc.t("loading_deleting_user_account", "Deleting user account")) {
                try await session.deleteAccount(reasonId: reasonId)
            }
        } catch let error as APIError where error.isServiceFault {
            feedback.toast(Feedback.unavailable(loc.t("delete_account_title", "Delete Account")))
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
