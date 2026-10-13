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
    @State private var operations = ChatOperationOwnership()
    @State private var replyOwnership = ChatReplyOwnership()
    @State private var sending = false
    @StateObject private var delivery = ChatSendCoordinator()
    @State private var visible = false
    @State private var scrollPosition = ChatViewportPosition()
    @State private var followIncoming = true
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
            ChatComposer(replyTo: Binding(get: { replyTo }, set: selectReply), focusRequest: focusRequest,
                         isEnabled: !sending, send: send)
        }
        .backHeader(loc.t("chat_screen_messages_title", "Chat Messages"))
        .onAppear { visible = true }
        .onDisappear { visible = false; operations.invalidate(); scrollPosition = ChatViewportPosition() }
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
            .disabled(sending)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(messages) { bubble($0).id($0.id) }
                        Color.clear.frame(height: 1)
                            .id("chat-bottom")
                    }
                    .padding(16)
                    .background(GeometryReader { content in
                        Color.clear.preference(key: ChatViewportPreference.self,
                            value: ChatViewportMetrics(contentBottom: content.frame(in: .named("chat-viewport")).maxY,
                                                       viewportHeight: viewport.size.height))
                    })
                }
                .coordinateSpace(name: "chat-viewport")
                .onPreferenceChange(ChatViewportPreference.self) { metrics in
                    guard let metrics else { return }
                    let followResize = scrollPosition.observe(contentBottom: metrics.contentBottom, viewportHeight: metrics.viewportHeight)
                    if followResize {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .simultaneousGesture(DragGesture().onChanged { _ in scrollPosition.beganUserScroll() })
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: messages.last?.id) { _, _ in
                    guard followIncoming else { return }
                    withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
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
            }
            // Black remains readable on the unchanged brand-blue fill, including
            // small server-time and quoted-message text.
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(mine ? Theme.Palette.primary : Color(hex: 0xF1F3F6),
                        in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mine ? 16 : 4,
                                                   bottomTrailingRadius: mine ? 4 : 16, topTrailingRadius: 16))
            .contextMenu { menuItems(m) }
            if !mine { menu(m) }
            if !mine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-message-\(m.id)")
    }

    private func menu(_ m: ChatMessage) -> some View {
        Menu { menuItems(m) } label: {
            AppIcon(name: "ic_more", size: 20, tint: Theme.Palette.textSecondary).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Message options")
        .accessibilityIdentifier("chat-message-options-\(m.id)")
    }

    @ViewBuilder private func menuItems(_ m: ChatMessage) -> some View {
        Button(loc.t("chat_screen_reply", "Reply")) { selectReply(m); focusRequest += 1 }
        Button(loc.t("chat_screen_copy", "Copy")) { UIPasteboard.general.string = m.message }
    }

    private func selectReply(_ message: ChatMessage?) {
        replyOwnership.selectionChanged()
        replyTo = message
    }

    private func load() async {
        guard visible, !sending, !Task.isCancelled else { return }
        let owner = operations.beginExplicitRead()
        error = nil
        defer { operations.finishExplicitRead(owner) }
        do {
            let full = try await feedback.run(loc.t("loading_chat_get_one", "Getting chat details")) {
                try await UserService().chat(id: chatId)
            }
            guard visible, !sending, !Task.isCancelled, operations.canCommit(owner) else { return }
            apply(full)
        } catch is CancellationError { return }
        catch {
            guard visible, !sending, !Task.isCancelled, operations.canCommit(owner) else { return }
            self.error = error
        }
    }

    /// Quiet checks never supersede an explicit read or a send.
    private func refreshQuietly() async {
        guard visible, chat != nil, !sending, !Task.isCancelled,
              let owner = operations.beginQuietRead() else { return }
        guard let full = try? await UserService().chat(id: chatId),
              visible, !Task.isCancelled, !sending, operations.canCommit(owner) else { return }
        if full != chat { apply(full) }
    }

    private func apply(_ full: ChatFull, revealAcknowledgedSend: Bool = false) {
        followIncoming = revealAcknowledgedSend || chat == nil || scrollPosition.isAtBottom
        chat = full
        messages = full.chronologicalMessages
    }

    /// Returns true when sent, so the composer clears its draft.
    private func send(_ text: String) async -> Bool {
        guard visible, !Task.isCancelled, !sending, let current = chat else { return false }
        let accountId = session.state.user?.id
        let generation = TokenStore.shared.generation
        let submittedRole = role
        let submittedReply = replyOwnership.capture(parentId: replyTo?.id)
        let owner = operations.beginSend()
        sending = true
        defer { sending = false }
        do {
            // The loaded conversation already supplies the relationship context.
            // Server authorization remains authoritative; reads are reserved for
            // initial/explicit refresh and uncertain delivery reconciliation.
            let partnerIsMatch = role == .client ? current.caregiver?.isMatch : current.client?.isMatch
            guard partnerIsMatch == true else {
                feedback.toast(loc.t("chat_screen_match_check", "You can only send messages to your current matches."))
                return false
            }
            let updated = try await feedback.run(loc.t("loading_chat_send", "Sending a new message")) {
                try await delivery.submit(chatId: chatId, text: text, parentId: submittedReply.parentId,
                                          baseline: current.messages, role: submittedRole, generation: generation)
            }
            // A deliberate, acknowledged send should reveal the new bubble even
            // when the keyboard reduced the viewport or the user was reading above.
            guard visible, !Task.isCancelled, operations.canCommit(owner),
                  session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return false }
            apply(updated, revealAcknowledgedSend: true)
            if replyOwnership.canClear(submittedReply, currentParentId: replyTo?.id) { selectReply(nil) }
            return true
        } catch is CancellationError { return false }
        catch {
            guard visible, !Task.isCancelled, operations.canCommit(owner),
                  session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return false }
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
    let isEnabled: Bool
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
                    Button { self.replyTo = nil } label: {
                        AppIcon(name: "ic_clear", size: 16, tint: Theme.Palette.textSecondary)
                            .frame(width: 44, height: 44)
                    }
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
                        draft = ChatDraftReconciliation.afterAcknowledgedSend(current: draft, submitted: sent)
                    }
                } label: {
                    AppIcon(name: "ic_send", size: 22, tint: .white)
                        .flipsForRightToLeftLayoutDirection(true)
                        .frame(width: 46, height: 46).background(Theme.Palette.primary, in: Circle())
                }
                .disabled(trimmed.isEmpty || !isEnabled)
                .opacity(trimmed.isEmpty || !isEnabled ? 0.45 : 1)
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
/// relationship records; actions remain on the partner profile.
/// Matches / Requests / History. Cards carry no match actions (client specification,
/// October 2026): tapping a card opens the person's profile, where the actions live.
/// Finished matches expose no review controls.
struct ManageMatchesView: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @StateObject private var pager = Pager<Match>()
    @State private var tab: MatchListType = .matches
    @State private var introduction: Match?

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
        .sheet(item: $introduction) { match in
            IntroductionSheet(match: match, role: role)
                .presentationDetents([.medium, .large])
        }
    }

    private var segmented: some View {
        AdaptiveStack(alignment: .center, spacing: 4) {
            ForEach([MatchListType.matches, .requests, .histories], id: \.self) { x in
                let on = tab == x
                Button { tab = x } label: {
                    Text(loc.t(x == .histories ? "match_tab_history" : "match_tab_\(x.rawValue)", x.rawValue.capitalized))
                        .font(on ? Theme.Typography.filledLabel(15) : Theme.Typography.control(15)).foregroundStyle(on ? .white : Theme.Palette.primaryDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
    }

    private func row(_ m: Match) -> some View {
        let partner = role == .client ? m.caregiver?.user : m.client?.user
        let partnerId = role == .client ? m.caregiver?.id : m.client?.id
        let preview = Self.preview(m.introduction)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                guard let partnerId else { return }
                router.push(role == .client ? .caregiverDetails(caregiverId: partnerId) : .clientDetails(clientId: partnerId))
            } label: {
                AdaptiveStack(alignment: .center, spacing: 12) {
                    Avatar(url: partner?.photo, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(partner?.fullName ?? "").font(Theme.Typography.title(16)).foregroundStyle(.black)
                        Text("\(loc.t("match_start", "Start")): \(ServerTime.local(m.createdAt))").font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                        if let end = m.finishedAt {
                            Text("\(loc.t("match_end", "End")): \(ServerTime.local(end))").font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        if m.awaitsPartner(for: role) {
                            Text(loc.t("match_pending_acceptance", "Pending Acceptance")).font(Theme.Typography.control(12)).foregroundStyle(Theme.Palette.warning)
                        }
                    }
                    Spacer(minLength: 4)
                    if m.stage != .pending {
                        AppIcon(name: m.stage == .history ? "ic_match_off" : "ic_match_on", size: 32,
                                tint: m.stage == .history ? Theme.Palette.danger : Theme.Palette.success)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if m.stage == .pending, let preview {
                Button { introduction = m } label: {
                    HStack(spacing: 6) {
                        AppIcon(name: "ic_message", size: 16, tint: Theme.Palette.textSecondary)
                        Text(preview).lineLimit(1)
                    }
                    .font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(loc.t("match_introduction_title", "Introduction")): \(preview)")
                .accessibilityIdentifier("match-introduction-\(m.id)")
            }
        }
        .card(padding: 12)
    }

    /// Preserve the first literal line; visual truncation belongs to the card only.
    static func preview(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        return String(message.prefix { !$0.isNewline })
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

/// Full introduction stays separate from profile navigation and match mutations.
private struct IntroductionSheet: View {
    let match: Match
    let role: UserRole
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(loc.t("match_introduction_title", "Introduction")).font(Theme.Typography.title(20))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(loc.t("general_cancel", "Cancel"))
                }
                let partner = role == .client ? match.caregiver?.user : match.client?.user
                HStack(spacing: 12) {
                    Avatar(url: partner?.photo, size: 72)
                    Text(partner?.fullName ?? "").font(Theme.Typography.title(17))
                }
                Text(match.introduction ?? "").font(Theme.Typography.body(15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .accessibilityIdentifier("match-introduction-detail")
    }
}

/// The sentinel is visible at the bottom (including short transcripts). This is
/// measured before applying a received chat, so new content cannot change the decision.
enum ChatScrollPosition {
    static func isAtBottom(contentBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentBottom.isFinite && viewportHeight > 0 && contentBottom <= viewportHeight + 24
    }
}

/// A keyboard resize must retain the reader's prior bottom intent until its
/// requested scroll has settled. New content alone never starts a resize scroll.
struct ChatViewportPosition {
    private(set) var isAtBottom = true
    private var previousHeight: CGFloat?
    private var awaitingBottomAfterResize = false

    mutating func observe(contentBottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard contentBottom.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return false }
        let resized = previousHeight.map { $0 != viewportHeight } ?? false
        let followResize = resized && (isAtBottom || awaitingBottomAfterResize)
        previousHeight = viewportHeight
        if followResize { awaitingBottomAfterResize = true }
        let reachedBottom = ChatScrollPosition.isAtBottom(contentBottom: contentBottom, viewportHeight: viewportHeight)
        if reachedBottom { awaitingBottomAfterResize = false }
        isAtBottom = reachedBottom || awaitingBottomAfterResize
        return followResize
    }

    mutating func beganUserScroll() {
        awaitingBottomAfterResize = false
        isAtBottom = false
    }
}

struct ChatViewportMetrics: Equatable {
    let contentBottom: CGFloat
    let viewportHeight: CGFloat
}

struct ChatViewportPreference: PreferenceKey {
    static let defaultValue: ChatViewportMetrics? = nil
    static func reduce(value: inout ChatViewportMetrics?, nextValue: () -> ChatViewportMetrics?) {
        if let measured = nextValue() { value = measured }
    }
}

/// Owns the boundary between a submitted message and its server acknowledgement.
/// Kept separate from the composer so a failed response cannot silently repeat POST.
@MainActor
final class ChatSendCoordinator: ObservableObject {
    @Published private(set) var uncertain = false
    private let service: UserService
    init(service: UserService = UserService()) { self.service = service }

    private struct Submission: Hashable {
        let chatId: Int
        let text: String
        let parentId: Int?
        let role: UserRole
        let generation: UUID
    }
    private struct Pending {
        let highestMessageID: Int
        let originalError: Error
    }
    private var pending: [Submission: Pending] = [:]
    private var submitting = false

    /// A known transcript is supplied by the active conversation. Reconciliation
    /// never mistakes an older identical message for this submission.
    func submit(chatId: Int, text: String, parentId: Int?,
                baseline: [ChatMessage] = [], role: UserRole = .client, generation: UUID? = nil) async throws -> ChatFull {
        guard !submitting else { throw APIError.unknown("") }
        submitting = true
        defer { submitting = false }
        let owner = await service.client.credentialGeneration()
        guard generation == nil || generation == owner else { throw CancellationError() }
        let submission = Submission(chatId: chatId, text: text, parentId: parentId, role: role, generation: owner)
        if let unresolved = pending[submission] {
            // Remember every unresolved operation, even when another draft was sent
            // between attempts. Another tap may check its outcome, never replay POST.
            return try await reconcile(submission, pending: unresolved)
        }
        do {
            return try await service.sendMessage(chatId: chatId, message: text, parentId: parentId, ifGeneration: owner)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard MutationOutcome.mayHaveCommitted(error) else { throw error }
            let unresolved = Pending(highestMessageID: baseline.map(\.id).max() ?? 0, originalError: error)
            pending[submission] = unresolved
            uncertain = true
            return try await reconcile(submission, pending: unresolved)
        }
    }

    private func reconcile(_ submission: Submission, pending unresolved: Pending) async throws -> ChatFull {
        let conversation: ChatFull
        do { conversation = try await service.chat(id: submission.chatId, ifGeneration: submission.generation) }
        catch is CancellationError { throw CancellationError() }
        catch { throw unresolved.originalError }
        guard conversation.id == submission.chatId,
              conversation.messages.contains(where: {
                  $0.id > unresolved.highestMessageID && $0.isMine(role: submission.role)
                      && $0.message == submission.text && $0.parent?.value.id == submission.parentId
              }) else { throw unresolved.originalError }
        pending.removeValue(forKey: submission)
        uncertain = !pending.isEmpty
        return conversation
    }


}

/// Reconciles only the submitted prefix after acknowledgement; new typing belongs
/// to the next message and must not be erased by an older request completing.
enum ChatDraftReconciliation {
    static func afterAcknowledgedSend(current: String, submitted: String) -> String {
        current.hasPrefix(submitted) ? String(current.dropFirst(submitted.count)).trimmingLeadingWhitespace : current
    }
}

/// Each explicit read or send supersedes older reads, including their failures.
/// Quiet polls are subordinate to an in-flight explicit read.
struct ChatOperationOwnership {
    private var revision = 0
    private var explicitRead: Int?
    mutating func beginExplicitRead() -> Int {
        revision += 1; explicitRead = revision; return revision
    }
    mutating func beginQuietRead() -> Int? {
        guard explicitRead == nil else { return nil }
        revision += 1; return revision
    }
    mutating func beginSend() -> Int {
        revision += 1; explicitRead = nil; return revision
    }
    mutating func finishExplicitRead(_ owner: Int) {
        if explicitRead == owner { explicitRead = nil }
    }
    mutating func invalidate() { revision += 1; explicitRead = nil }
    func canCommit(_ owner: Int) -> Bool { revision == owner }
}

/// Identity alone cannot distinguish cancelling then selecting the same reply again.
struct ChatReplyOwnership {
    struct Submission { let parentId: Int?; fileprivate let revision: Int }
    private var revision = 0
    mutating func selectionChanged() { revision += 1 }
    func capture(parentId: Int?) -> Submission { Submission(parentId: parentId, revision: revision) }
    func canClear(_ submission: Submission, currentParentId: Int?) -> Bool {
        revision == submission.revision && currentParentId == submission.parentId
    }
}
