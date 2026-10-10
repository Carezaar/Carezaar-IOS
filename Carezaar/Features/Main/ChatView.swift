import SwiftUI

/// `Chat/{chatId}`. The API returns messages newest-first with minute-precision
/// timestamps; the transcript reads oldest-at-top, ordered by id. Sending returns the
/// whole updated chat, so the transcript is replaced from the response.
///
/// Android refreshes an open chat when an FCM push arrives. The backend has no push
/// channel for iOS, so an open chat re-checks every 10 s while it is on screen and
/// whenever the app returns to the foreground.
struct ChatView: View {
    let chatId: Int

    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var chat: ChatFull?
    @State private var messages: [ChatMessage] = []
    @State private var error: Error?
    @State private var replyTo: ChatMessage?
    @State private var focusRequest = 0
    /// Bumped by every load or send; a background check that started before one of
    /// them must not overwrite its newer result.
    @State private var revision = 0
    @State private var sending = false
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    private static let pollInterval: Duration = .seconds(10)

    private var role: UserRole { session.role ?? .client }

    var body: some View {
        VStack(spacing: 0) {
            partnerBar
            Divider()
            if let error, chat == nil {
                ErrorState(message: Self.message(error, loc: loc)) { Task { await load() } }
            } else if chat == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 10) {
                    EmptyArt(name: "illus_chat")
                    Text(loc.t("chat_screen_no_messages_yet", "No Messages Yet")).font(Theme.Typography.title(18))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
            // The draft lives in its own view: typing re-renders only the composer, not
            // the transcript (a long message there made every keystroke re-lay it out).
            ChatComposer(replyTo: $replyTo, focusRequest: focusRequest, send: send)
        }
        .backHeader(loc.t("chat_screen_messages_title", "Chat Messages"))
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if !Task.isCancelled, visible, scenePhase == .active { await refreshQuietly() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, visible { Task { await refreshQuietly() } }
        }
    }

    private var partnerBar: some View {
        let partner = chat?.partner(for: role)
        return HStack(spacing: 12) {
            Avatar(url: partner?.photo, size: 44)
            Text(partner?.fullName ?? "").font(Theme.Typography.title(16))
            Spacer()
            Button { Task { await load() } } label: {
                AppIcon(name: "ic_refresh", size: 24, tint: Theme.Palette.primary).frame(width: 44, height: 44)
            }
            .accessibilityLabel(loc.t("chat_screen_refresh", "Refresh"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { bubble($0).id($0.id) }
                }
                .padding(16)
            }
            // Open at the newest message, as Android does.
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.isMine(role: role)
        return HStack(alignment: .top, spacing: 4) {
            if mine { Spacer(minLength: 48) }
            if mine { menu(m) }
            VStack(alignment: .leading, spacing: 4) {
                if let parent = m.parent?.value {
                    Text(parent.message).font(Theme.Typography.caption(12)).lineLimit(2)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background((mine ? Color.white : Theme.Palette.primary).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(m.message).font(Theme.Typography.body(15))
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(ServerTime.local(m.createdAt)).font(Theme.Typography.caption(11))
                    if mine {
                        AppIcon(name: m.seenAt == nil ? "ic_check" : "ic_check_double", size: 16, tint: .white.opacity(0.85))
                            .accessibilityLabel(m.seenAt.map { "\(loc.t("chat_screen_seen_at", "Seen at")) \(ServerTime.local($0))" } ?? "Sent")
                    }
                }
                .opacity(0.85)
            }
            .foregroundStyle(mine ? .white : .black)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(mine ? Theme.Palette.primary : Color(hex: 0xF1F3F6),
                        in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mine ? 16 : 4,
                                                   bottomTrailingRadius: mine ? 4 : 16, topTrailingRadius: 16))
            .contextMenu { menuItems(m) }
            if !mine { menu(m) }
            if !mine { Spacer(minLength: 48) }
        }
    }

    private func menu(_ m: ChatMessage) -> some View {
        Menu { menuItems(m) } label: {
            AppIcon(name: "ic_more", size: 20, tint: Theme.Palette.textSecondary).frame(width: 28, height: 36)
        }
        .accessibilityLabel("Message options")
    }

    @ViewBuilder private func menuItems(_ m: ChatMessage) -> some View {
        Button(loc.t("chat_screen_reply", "Reply")) { replyTo = m; focusRequest += 1 }
        Button(loc.t("chat_screen_copy", "Copy")) { UIPasteboard.general.string = m.message }
    }

    private func load() async {
        error = nil
        do {
            let full = try await feedback.run(loc.t("loading_chat_get_one", "Getting chat details")) {
                try await UserService().chat(id: chatId)
            }
            apply(full)
        } catch { self.error = error }
    }

    /// New messages from the partner, without the busy card.
    private func refreshQuietly() async {
        guard chat != nil, !sending else { return }
        let started = revision
        guard let full = try? await UserService().chat(id: chatId), started == revision, !sending else { return }
        if full != chat { apply(full) }
    }

    private func apply(_ full: ChatFull) {
        revision += 1
        chat = full
        messages = full.chronologicalMessages
    }

    /// Returns true when sent, so the composer clears its draft.
    private func send(_ text: String) async -> Bool {
        // Android checks the partner's is_match before sending; the server itself
        // accepts messages to an ended match.
        let partnerIsMatch = role == .client ? chat?.caregiver?.isMatch : chat?.client?.isMatch
        if partnerIsMatch == false {
            feedback.toast(loc.t("chat_screen_match_check", "You can only send messages to your current matches."))
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let updated = try await feedback.run(loc.t("loading_chat_send", "Sending a new message")) {
                try await UserService().sendMessage(chatId: chatId, message: text, parentId: replyTo?.id)
            }
            apply(updated)
            replyTo = nil
            return true
        } catch {
            feedback.toast(Self.message(error, loc: loc))
            return false
        }
    }

    /// A chat belongs to the match that created it; once that match ends the server
    /// answers "The id field contains an unauthorized value."
    static func message(_ error: Error, loc: Localization) -> String {
        if case .unknown(let m) = error as? APIError, m.localizedCaseInsensitiveContains("unauthori") {
            return loc.t("chat_screen_match_check", "You can only send messages to your current matches.")
        }
        return Feedback.message(error)
    }
}

/// Message field + send button, with the draft as local state.
private struct ChatComposer: View {
    @Binding var replyTo: ChatMessage?
    let focusRequest: Int
    let send: (String) async -> Bool
    @EnvironmentObject private var loc: Localization
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 6) {
            if let replyTo {
                HStack(spacing: 8) {
                    AppIcon(name: "ic_reply", size: 18, tint: Theme.Palette.primary)
                    Text(replyTo.message).font(Theme.Typography.caption(13)).lineLimit(1)
                    Spacer()
                    Button { self.replyTo = nil } label: { AppIcon(name: "ic_clear", size: 16, tint: Theme.Palette.textSecondary) }
                        .accessibilityLabel(loc.t("chat_screen_cancel", "Cancel"))
                }
                .padding(10).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                TextField(loc.t("chat_screen_message_placeholder", "Type a message..."), text: $draft, axis: .vertical)
                    .lineLimit(1...4).focused($focused)
                    .font(Theme.Typography.control(15))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.Palette.line))
                Button {
                    let text = trimmed, sent = draft
                    guard !text.isEmpty else { return }
                    Task {
                        guard await send(text) else { return }
                        // The keyboard stays usable behind the busy card: keep anything
                        // typed while this message was sending.
                        draft = draft.hasPrefix(sent) ? String(draft.dropFirst(sent.count)).trimmingLeadingWhitespace : ""
                    }
                } label: {
                    AppIcon(name: "ic_send", size: 22, tint: .white)
                        .flipsForRightToLeftLayoutDirection(true)
                        .frame(width: 46, height: 46).background(Theme.Palette.primary, in: Circle())
                }
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.45 : 1)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

private extension String {
    var trimmingLeadingWhitespace: String { String(drop { $0.isWhitespace }) }
}

// MARK: - Manage matches

/// Profile → Matches: the user's own match records in three tabs, with the
/// Accept / Reject / Cancel / Unmatch / Review actions each stage allows.
/// Matches / Requests / History. Cards carry no match actions (client specification,
/// October 2026): tapping a card opens the person's profile, where the actions live.
/// History keeps Review, which is not a match action.
struct ManageMatchesView: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @StateObject private var pager = Pager<Match>()
    @State private var tab: MatchListType = .matches
    @State private var reviewing: Match?

    private var role: UserRole { session.role ?? .client }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                segmented
                PagedContent(pager: pager, emptyTitle: "\(loc.t(tab == .histories ? "match_tab_history" : "match_tab_\(tab.rawValue)", tab.rawValue.capitalized)) (0)",
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }) { m in
                    row(m).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
        }
        .refreshable { await pager.reload(fetch) }
        .backHeader(loc.t("profile_matches_title", "Matches"))
        .task(id: tab) { await reload() }
        .sheet(item: $reviewing) { match in
            ReviewSheet(match: match) { reviewing = nil; Task { await reload() } }
                .presentationDetents([.medium, .large])
        }
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            ForEach([MatchListType.matches, .requests, .histories], id: \.self) { x in
                let on = tab == x
                Button { tab = x } label: {
                    Text(loc.t(x == .histories ? "match_tab_history" : "match_tab_\(x.rawValue)", x.rawValue.capitalized))
                        .font(on ? Theme.Typography.filledLabel(15) : Theme.Typography.control(15)).foregroundStyle(on ? .white : Theme.Palette.primaryDark)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Theme.Palette.primary : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .accessibilityShowsLargeContentViewer {
                    Text(loc.t(x == .histories ? "match_tab_history" : "match_tab_\(x.rawValue)", x.rawValue.capitalized))
                }
            }
        }
        .padding(4).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
        // A segmented control: capped like the system's, with the large content viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func row(_ m: Match) -> some View {
        let partner = role == .client ? m.caregiver?.user : m.client?.user
        let partnerId = role == .client ? m.caregiver?.id : m.client?.id
        let preview = Self.preview(m.introduction)
        return Button {
            guard let partnerId else { return }
            router.push(role == .client ? .caregiverDetails(caregiverId: partnerId) : .clientDetails(clientId: partnerId))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AdaptiveStack(alignment: .center, spacing: 12) {
                    Avatar(url: partner?.photo, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(partner?.fullName ?? "").font(Theme.Typography.title(16)).foregroundStyle(.black)
                        Text("\(loc.t("match_start", "Start")): \(ServerTime.local(m.createdAt))").font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                        if let end = m.finishedAt {
                            Text("\(loc.t("match_end", "End")): \(ServerTime.local(end))").font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        if m.awaitsPartner(for: role) {
                            Text(loc.t("match_pending_review", "Pending Review")).font(Theme.Typography.control(12)).foregroundStyle(Theme.Palette.warning)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 8) {
                        // Green only for a real match; ended ones are red; requests have none.
                        if m.stage != .pending {
                            AppIcon(name: m.stage == .history ? "ic_match_off" : "ic_match_on", size: 32,
                                    tint: m.stage == .history ? Theme.Palette.danger : Theme.Palette.success)
                                .accessibilityHidden(true)
                        }
                        if m.stage == .history, m.review(by: role) == nil {
                            MiniButton(title: loc.t("match_review_button", "Review")) { reviewing = m }
                        }
                    }
                }
                if m.stage == .pending, let preview {
                    Text("💬 " + preview).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("\(loc.t("match_introduction_title", "Introduction")): \(preview)")
                }
            }
            .card(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The introduction's first sentence, at most 80 characters, on one card line.
    static func preview(_ message: String?) -> String? {
        let text = (message ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        var beginning = text
        if let end = text.firstIndex(where: { ".!?".contains($0) }), text.index(after: end) < text.endIndex {
            beginning = String(text[..<end])
        }
        let clipped = beginning.count > 80 || beginning != text
        return String(beginning.prefix(80)).trimmingCharacters(in: .whitespaces) + (clipped ? "..." : "")
    }

    private var fetch: Pager<Match>.Fetch {
        let tab = tab
        return { page in try await UserService().matches(type: tab, page: page) }
    }

    private func reload() async {
        let slug = switch tab { case .matches: "loading_matches"; case .requests: "loading_requests"; case .histories: "loading_histories" }
        try? await feedback.run("\(loc.t(slug, "Loading")) 1") { await pager.reload(fetch) }
    }
}

/// "Submit your review": 1–5 stars and a comment. Android treats the comment as
/// optional, but the server answers 400 `Undefined array key "comment"` without one
/// (BE-07), so it is required until that is fixed.
struct ReviewSheet: View {
    let match: Match
    let onDone: () -> Void
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var score = 5
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("match_review_title", "Submit your review")).font(Theme.Typography.title(20))
            let hint = loc.t("match_review_message", "")
            if !hint.isEmpty { Text(hint).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary) }
            Text(loc.t("match_review_score", "Score")).font(Theme.Typography.title(15))
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { n in
                    Button { score = n } label: {
                        Image(systemName: n <= score ? "star.fill" : "star").font(.system(size: 30))
                            .foregroundStyle(n <= score ? Color(hex: 0xF5B301) : Theme.Palette.textSecondary)
                    }
                    .accessibilityLabel("\(n)")
                    .accessibilityAddTraits(score == n ? [.isSelected] : [])
                }
            }
            (Text(loc.t("match_review_comment", "Comment")) + Text(" *").foregroundColor(Theme.Palette.error))
                .font(Theme.Typography.title(15))
            TextField("", text: $comment, axis: .vertical).lineLimit(3...6).padding(12)
                .accessibilityLabel(loc.t("match_review_comment", "Comment"))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.line))
            PrimaryButton(title: loc.t("match_submit_button", "Submit"), isEnabled: !trimmedComment.isEmpty) { Task { await submit() } }
            Spacer()
        }
        .padding(20)
    }

    private var trimmedComment: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() async {
        guard !trimmedComment.isEmpty else { return }
        do {
            _ = try await feedback.run(loc.t("loading_review_submit", "Submitting your review")) {
                try await UserService().submitReview(matchId: match.id, score: score, comment: trimmedComment)
            }
            onDone()
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
