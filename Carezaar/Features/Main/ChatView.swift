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
    @StateObject private var delivery = ChatSendCoordinator()
    /// One send per conversation at a time, from any rebuilt or reopened copy of this screen.
    @ObservedObject private var guards = ActionGuard.shared
    private var sending: Bool { guards.isBusy(ChatSendCoordinator.resource(chatId)) }
    @State private var reloading = false
    /// A message whose earlier send got no answer, offered again with its Idempotency-Key.
    @State private var restoredDraft: String?
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
                SkeletonChat().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                         isEnabled: !sending, isSending: sending, closedNote: closedNote,
                         restoredDraft: restoredDraft, unconfirmed: (delivery.uncertain || restoredDraft != nil) && !sending, send: send)
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

    /// K2/K3: a conversation that can no longer receive messages is closed with a
    /// note above the typing box. A deleted account wins over the match check
    /// (the server also reports `is_match: false` for it).
    private var closedNote: String? {
        guard let chat else { return nil }
        switch ChatAvailability(chat: chat, role: role) {
        case .open: return nil
        case .accountDeleted: return loc.t("chat_screen_account_deleted", "This account has been deleted. You can no longer send messages.")
        case .notMatched: return loc.t("chat_screen_match_check", "You can only send messages to your current matches.")
        }
    }

    private var partnerBar: some View {
        let partner = chat?.partner(for: role)
        return HStack(spacing: 12) {
            Avatar(url: partner?.photo, size: 44)
            Text(partner?.displayName(loc) ?? "").font(Theme.Typography.title(16))
            Spacer()
            Button { Task { await load() } } label: {
                // Progress on the Refresh button itself; the conversation stays on screen.
                Group {
                    if reloading && chat != nil { ProgressView() }
                    else { AppIcon(name: "ic_refresh", size: 24, tint: Theme.Palette.primary) }
                }
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(loc.t("chat_screen_refresh", "Refresh"))
            .accessibilityIdentifier("chat-refresh")
            .disabled(sending || reloading)
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
            .background(mine ? Theme.Palette.primaryFill : Color(hex: 0xF1F3F6),
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
        reloading = true
        defer { operations.finishExplicitRead(owner); reloading = false }
        do {
            let full = try await UserService().chat(id: chatId)
            guard visible, !sending, !Task.isCancelled, operations.canCommit(owner) else { return }
            apply(full)
            restorePending(in: full)
        } catch is CancellationError { return }
        catch {
            guard visible, !sending, !Task.isCancelled, operations.canCommit(owner) else { return }
            // A failed refresh keeps the conversation (and what was just sent) on screen.
            if chat != nil { feedback.toast(Self.message(error, loc: loc)) } else { self.error = error }
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

    /// After a restart or another visit: a message whose send got no answer comes back into
    /// the box (with what it replied to), so Send repeats that same submission, not a new one.
    private func restorePending(in full: ChatFull) {
        guard restoredDraft == nil, !sending,
              let pending = IdempotencyStore.shared.pending(.chatMessage, target: String(chatId)).first,
              let text = pending.draft, !text.isEmpty else { return }
        if let parent = pending.parent { selectReply(full.messages.first { $0.id == parent }) }
        restoredDraft = text
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
        do {
            // The loaded conversation already supplies the relationship context.
            // Server authorization remains authoritative; reads are reserved for
            // initial/explicit refresh and uncertain delivery reconciliation.
            // K2/K3: a closed conversation disables the composer and shows its note
            // above the box; this guard only covers a race with a refresh.
            guard ChatAvailability(chat: current, role: role) == .open else { return false }
            let updated = try await delivery.submit(chatId: chatId, text: text, parentId: submittedReply.parentId,
                                                    baseline: current.messages, role: submittedRole, generation: generation)
            restoredDraft = nil
            // A deliberate, acknowledged send should reveal the new bubble even
            // when the keyboard reduced the viewport or the user was reading above.
            guard visible, !Task.isCancelled, operations.canCommit(owner),
                  session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return false }
            apply(updated, revealAcknowledgedSend: true)
            if replyOwnership.canClear(submittedReply, currentParentId: replyTo?.id) { selectReply(nil) }
            return true
        } catch is CancellationError { return false }
        catch is DuplicateActionError { return false }
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

/// Whether the signed-in user can still write in a conversation.
enum ChatAvailability: Equatable {
    case open, notMatched, accountDeleted

    init(chat: ChatFull, role: UserRole) {
        let partner = role == .client ? chat.caregiver?.user : chat.client?.user
        let isMatch = role == .client ? chat.caregiver?.isMatch : chat.client?.isMatch
        if partner?.isDeleted == true { self = .accountDeleted }
        else if isMatch != true { self = .notMatched }
        else { self = .open }
    }
}

/// Message field + send button, with the draft as local state.
private struct ChatComposer: View {
    @Binding var replyTo: ChatMessage?
    let focusRequest: Int
    let isEnabled: Bool
    /// The message is on its way: progress on the Send button.
    var isSending = false
    /// K2/K3: when set, the conversation is closed: the note sits above a disabled
    /// typing box and a grey send button.
    let closedNote: String?
    /// A message whose earlier send got no answer, put back into the box once.
    var restoredDraft: String? = nil
    /// Says that the message in the box may not have been sent, and Send will try it again.
    var unconfirmed = false
    let send: (String) async -> Bool
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 6) {
            if let closedNote {
                HStack(alignment: .top, spacing: 8) {
                    AppIcon(name: "ic_issue", size: 18, tint: Theme.Palette.textSecondary)
                        .accessibilityHidden(true)
                    Text(closedNote).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-closed-note")
            }
            if unconfirmed, closedNote == nil, !draft.isEmpty {
                Text(loc.t("chat_screen_message_unconfirmed", "This message may not have been sent. Tap Send to try again."))
                    .font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-unconfirmed-note")
            }
            if let replyTo, closedNote == nil {
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
                    .disabled(closedNote != nil)
                    .font(Theme.Typography.control(15))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.Palette.line))
                Button {
                    let text = trimmed, sent = draft
                    // K4: the button stays tappable and explains an empty message.
                    guard !text.isEmpty else {
                        feedback.toast(loc.t("chat_screen_message_required", "Please type a message first."))
                        return
                    }
                    Task {
                        guard await send(text) else { return }
                        // The keyboard stays usable behind the busy card: keep anything
                        // typed while this message was sending.
                        draft = ChatDraftReconciliation.afterAcknowledgedSend(current: draft, submitted: sent)
                    }
                } label: {
                    Group {
                        if isSending { ProgressView().tint(.white) }
                        else { AppIcon(name: "ic_send", size: 22, tint: .white).flipsForRightToLeftLayoutDirection(true) }
                    }
                    // K2/K3: grey on a closed conversation, as on Android.
                    .frame(width: 46, height: 46)
                    .background(closedNote != nil ? Theme.Palette.textSecondary : Theme.Palette.primaryFill, in: Circle())
                }
                .disabled(!isEnabled || closedNote != nil)
                .opacity(!isEnabled ? 0.45 : closedNote != nil ? 0.6 : 1)
                .accessibilityLabel("Send")
                // Progress is on the button itself (no loading window): its value says it is sending.
                .accessibilityValue(isSending ? loc.t("loading_chat_send", "Sending a new message") : "")
                .accessibilityIdentifier("chat-send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: focusRequest) { _, _ in if closedNote == nil { focused = true } }
        .onChange(of: restoredDraft) { _, text in if let text, draft.isEmpty { draft = text } }
        .onAppear { if let restoredDraft, draft.isEmpty { draft = restoredDraft } }
        .onChange(of: closedNote) { _, note in if note != nil { focused = false } }
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
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }, skeleton: .row) { m in
                    row(m).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
        }
        .refreshable { await pager.refresh(fetch) }
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
                        .background(on ? Theme.Palette.primaryFill : .clear, in: RoundedRectangle(cornerRadius: 10))
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
                        Text(partner?.displayName(loc) ?? "").font(Theme.Typography.title(16)).foregroundStyle(.black)
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
        await pager.reload(fetch) // the first load shows skeleton rows (PagedContent)
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
                    Text(partner?.displayName(loc) ?? "").font(Theme.Typography.title(17))
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
/// Each message is one submission with its own Idempotency-Key (IdempotencyStore): when a
/// send gets no answer the key is kept, and Send repeats the same submission, which the
/// server carries out at most once. No conversation read guesses the outcome from the text
/// (client request, 25 Oct 2026). One send per conversation at a time (ActionGuard).
@MainActor
final class ChatSendCoordinator: ObservableObject {
    /// The last send got no answer; its key is kept for the next attempt.
    @Published private(set) var uncertain = false
    private let service: UserService
    init(service: UserService = UserService()) { self.service = service }

    static func resource(_ chatId: Int) -> String { "chat:\(chatId):send" }

    /// `baseline` is the conversation on screen (its newest id lets an expired key be reconciled).
    func submit(chatId: Int, text: String, parentId: Int?,
                baseline: [ChatMessage] = [], role: UserRole = .client, generation: UUID? = nil) async throws -> ChatFull {
        let owner = await service.client.credentialGeneration()
        guard generation == nil || generation == owner else { throw CancellationError() }
        do {
            let full = try await ActionGuard.shared.run(Self.resource(chatId)) {
                try await service.sendMessage(chatId: chatId, message: text, parentId: parentId, ifGeneration: owner,
                                              fromCaregiver: role == .caregiver, after: baseline.map(\.id).max())
            }
            uncertain = false
            return full
        } catch is CancellationError { throw CancellationError() }
        catch let duplicate as DuplicateActionError { throw duplicate }
        catch {
            uncertain = !IdempotencyStore.isDefinitive(error)
            throw error
        }
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
