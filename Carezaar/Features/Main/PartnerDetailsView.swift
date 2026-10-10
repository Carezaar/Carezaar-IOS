import SwiftUI

/// `CaregiverDetails/{id}` (a client viewing) and `ClientDetails/{id}` (a caregiver
/// viewing). Match requests live here (client specification, October 2026): one set of
/// actions per `match_status` from the profile response, each confirmed first.
/// - `none`: Request a Match, with an optional Introduction (`POST users/matches`);
/// - `sent`: Pending Review and Withdraw (`DELETE users/matches/{id}/withdraw`);
/// - `received`: the requester's Introduction, Accept (`PATCH …/accept`, then
///   "It's a Match!") and Reject (`DELETE …/reject`);
/// - `active`: Unmatch (`DELETE users/matches/{id}`).
/// Before each action the profile is re-read; if the state has changed meanwhile nothing
/// is sent. Messaging needs an active match. There is no background-check gate (removed
/// at the client's request).
struct PartnerDetailsView: View {
    enum Kind: Hashable { case caregiver(id: String), client(id: String) }
    let kind: Kind

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @EnvironmentObject private var poller: NotificationPoller
    @Environment(\.scenePhase) private var scenePhase

    @State private var caregiver: CaregiverFull?
    @State private var client: ClientFull?
    @State private var error: Error?
    @State private var confirming: MatchMutation?
    @State private var requesting = false
    @State private var introduction = ""
    @State private var busy = false

    private var isCaregiver: Bool { if case .caregiver = kind { return true } else { return false } }
    private var partner: User? { caregiver?.user ?? client?.user }
    private var matchState: ProfileMatchState? { caregiver?.matchState ?? client?.matchState }
    private var matchIntroduction: String? { caregiver?.matchIntroduction ?? client?.matchIntroduction }
    private var partnerId: String {
        switch kind { case .caregiver(let id), .client(let id): return id }
    }
    private var prefix: String { isCaregiver ? "caregiver_details" : "client_details" }

    var body: some View {
        Group {
            if let error, partner == nil {
                ErrorState(message: Feedback.message(error)) { Task { await load() } }
            } else if let partner {
                content(partner)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let partner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await toggleFavorite() } } label: {
                        AppIcon(name: partner.isFavorite ? "ic_favorite_on" : "ic_favorite_off", size: 28,
                                tint: partner.isFavorite ? Theme.Palette.danger : Theme.Palette.primaryDark)
                    }
                    .accessibilityLabel(partner.isFavorite ? "Remove from favorites" : "Add to favorites")
                }
            }
        }
        .task { await load() }
        // Coming back from Matches or "It's a Match!": the state may have changed.
        .onAppear { if partner != nil { Task { await refreshQuietly() } } }
        // The partner may answer while this screen is open (accept, unmatch): a new
        // notification, a return to the app, or a pull re-reads the relationship.
        .onChange(of: poller.unread) { old, new in if new > old, partner != nil { Task { await refreshQuietly() } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active, partner != nil { Task { await refreshQuietly() } } }
        .alert(confirming.map(title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(loc.t("general_cancel", "Cancel"), role: .cancel) { confirming = nil }
            if let which = confirming {
                Button(confirmLabel(which), role: which == .accept ? nil : .destructive) {
                    confirming = nil
                    Task { await perform(which) }
                }
            }
        } message: {
            Text(confirming.map(confirmMessage) ?? "")
        }
        .sheet(isPresented: $requesting) {
            MatchRequestSheet(introduction: $introduction) {
                requesting = false
                Task { await perform(.request) }
            } onCancel: { requesting = false }
            .presentationDetents([.medium, .large])
        }
    }

    private func content(_ partner: User) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let text = matchIntroduction?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                   matchState?.status == .received || matchState?.status == .sent {
                    introductionCard(text)
                }
                AdaptiveStack(spacing: 16) {
                    PhotoBox(url: partner.photo, width: 132, height: 160, radius: 16)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            AppIcon(name: item(.genders, partner.genderId)?.icon, size: 24, tint: Theme.Palette.primaryDark)
                            Text(partner.fullName).font(Theme.Typography.heading(21))
                        }
                        Text(isCaregiver ? loc.label(item(.roles, caregiver?.roleId)) : loc.label(item(.clienttypes, client?.clienttypeId)))
                            .font(Theme.Typography.body(14)).foregroundStyle(Theme.Palette.textSecondary)
                        fact("ic_distance", bold: formatDistance(caregiver?.distance ?? client?.distance), rest: loc.t("general_miles_away", "mile(s) away"))
                        if isCaregiver { fact("ic_calendar", bold: "", rest: loc.label(item(.experiences, caregiver?.experienceId))) }
                        let min = caregiver?.salaryMin ?? client?.salaryMin, max = caregiver?.salaryMax ?? client?.salaryMax
                        fact("ic_usd_circle", bold: "\(min.map(String.init) ?? "—") - \(max.map(String.init) ?? "—")",
                             rest: loc.t("\(prefix)_usd_per_hour", "USD per hour"))
                    }
                }
                AdaptiveStack(spacing: 12) {
                    pair(isCaregiver ? loc.t("caregiver_details_maximum_commute_distance", "Maximum Commute Distance") : loc.t("client_details_max_commute", "Max Commute"),
                         isCaregiver ? loc.label(item(.commutes, caregiver?.commuteId)) : names(.commutes, client?.commuteIds ?? []))
                    pair(isCaregiver ? loc.t("caregiver_details_work_type", "Work Type") : loc.t("client_details_work_types", "Work Types"),
                         isCaregiver ? loc.label(item(.worktypes, caregiver?.worktypeId)) : names(.worktypes, client?.worktypeIds ?? []))
                }
                if let bio = partner.bio, !bio.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        AppIcon(name: "ic_quote", size: 28, tint: Theme.Palette.primaryDark)
                        Text(bio).font(Theme.Typography.body(15)).italic()
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 14))
                }
                section(isCaregiver ? loc.t("caregiver_details_provided_care_types", "Provided Care Types") : loc.t("client_details_needed_care_types", "Needed Care Types"),
                        items(.careconditions, caregiver?.careconditionIds ?? client?.careconditionIds ?? []), tiles: true)
                section(isCaregiver ? loc.t("caregiver_details_special_qualities", "Special Qualities") : loc.t("client_details_special_qualities", "Important Qualities"),
                        items(.carespecials, caregiver?.carespecialIds ?? client?.carespecialIds ?? []))
                section(isCaregiver ? loc.t("caregiver_details_spoken_languages", "Spoken Languages") : loc.t("client_details_preferred_languages", "Preferred Language"),
                        items(.languageskills, caregiver?.languageskillIds ?? client?.languageskillIds ?? []), coloured: true)
                section(loc.t("\(prefix)_preferred_shifts", "Preferred Shifts"), items(.shifts, caregiver?.shiftIds ?? client?.shiftIds ?? []))
                section(isCaregiver ? loc.t("caregiver_details_selected_work_days", "Selected Work Days") : loc.t("client_details_work_days", "Work Days"),
                        items(.caredays, caregiver?.caredayIds ?? client?.caredayIds ?? []))
                section(isCaregiver ? loc.t("caregiver_details_certifications", "Certifications") : loc.t("client_details_certifications", "Required Certifications"),
                        items(.certifications, caregiver?.certificationIds ?? client?.certificationIds ?? []))
                if isCaregiver {
                    section(loc.t("caregiver_details_supported_care_needer_types", "Supported Care Needer Types"),
                            items(.clienttypes, caregiver?.clienttypeIds ?? []), coloured: true)
                }
            }
            .padding(20).padding(.bottom, 90)
        }
        .refreshable { await refreshQuietly() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if matchState?.status == .sent {
                    Label(loc.t("match_pending_review", "Pending Review"), systemImage: "clock")
                        .font(Theme.Typography.control(14)).foregroundStyle(Theme.Palette.warning)
                        .accessibilityAddTraits(.isStaticText)
                }
                AdaptiveStack(alignment: .center, spacing: 12, stackedSpacing: 8) {
                    WideButton(title: loc.t("\(prefix)_message", "Message"), icon: "ic_message", style: .outline) { Task { await message() } }
                    matchButtons
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
    }

    /// The requester's note, shown with an open request to both people.
    private func introductionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("match_introduction_title", "Introduction")).font(Theme.Typography.title(15))
                .foregroundStyle(Theme.Palette.primaryDark)
            // Not selectable: VoiceOver treats selectable text as a text area and keeps the
            // swipe inside it, so the rest of the profile was never reached.
            Text(text).font(Theme.Typography.body(15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// One set of actions per state, never two at once.
    @ViewBuilder private var matchButtons: some View {
        if let state = matchState {
            switch state.status {
            case .none:
                WideButton(title: loc.t("match_match_button", "Request a Match"), icon: "ic_match_on") {
                    guard !busy else { return }
                    introduction = ""
                    requesting = true
                }
                .accessibilityIdentifier("match-request")
            case .sent:
                WideButton(title: loc.t("match_withdraw_button", "Withdraw"), icon: "ic_match_off", style: .outline) { ask(.withdraw) }
                    .accessibilityIdentifier("match-withdraw")
            case .received:
                WideButton(title: loc.t("match_accept_title", "Accept"), icon: "ic_match_on") { ask(.accept) }
                    .accessibilityIdentifier("match-accept")
                WideButton(title: loc.t("match_reject_title", "Reject"), style: .danger) { ask(.reject) }
                    .accessibilityIdentifier("match-reject")
            case .active:
                WideButton(title: loc.t("match_unmatch_title", "Unmatch"), icon: "ic_match_off", style: .danger) { ask(.unmatch) }
                    .accessibilityIdentifier("match-unmatch")
            }
        } else if partner != nil {
            // Missing or contradictory match fields: no action until the profile is re-read.
            WideButton(title: loc.t("general_try_again", "Try Again"), style: .outline) { Task { await refreshQuietly() } }
                .accessibilityHint(loc.t("match_state_unavailable", "Match information is unavailable."))
        }
    }

    private func ask(_ which: MatchMutation) { if !busy { confirming = which } }

    private func title(_ which: MatchMutation) -> String {
        switch which {
        case .request: return loc.t("match_match_button", "Request a Match")
        case .accept: return loc.t("match_accept_title", "Accept")
        case .reject: return loc.t("match_reject_title", "Reject")
        case .withdraw: return loc.t("match_withdraw_button", "Withdraw")
        case .unmatch: return loc.t("match_unmatch_title", "Unmatch")
        }
    }

    private func confirmLabel(_ which: MatchMutation) -> String {
        which == .request ? loc.t("match_match_title", "Match") : loc.t("general_confirm", "Confirm")
    }

    private func confirmMessage(_ which: MatchMutation) -> String {
        switch which {
        case .request: return loc.t("match_match_message", "Are you sure you want to match with this user? They should accept your request.")
        case .accept: return loc.t("match_accept_message", "Are you sure you want to accept this match request?")
        case .reject: return loc.t("match_reject_message", "Are you sure you want to reject this match request?")
        case .withdraw: return loc.t("match_withdraw_message", "Are you sure you want to withdraw this match request?")
        case .unmatch: return loc.t("match_unmatch_message", "Are you sure you want to end your match with this user?")
        }
    }

    private func fact(_ icon: String, bold: String, rest: String) -> some View {
        HStack(spacing: 6) {
            AppIcon(name: icon, size: 24, tint: Theme.Palette.primaryDark)
            if !bold.isEmpty { Text(bold).font(Theme.Typography.title(16)) }
            Text(rest).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func pair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Typography.title(14)).foregroundStyle(Theme.Palette.primaryDark)
            Text(value.isEmpty ? "—" : value).font(Theme.Typography.body(14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BaseItem], tiles: Bool = false, coloured: Bool = false) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.Typography.title(17))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(list) { entry in
                            if tiles {
                                VStack(spacing: 8) {
                                    AppIcon(name: entry.icon, size: 56, tint: coloured ? nil : Theme.Palette.primaryDark)
                                    Text(loc.label(entry)).font(Theme.Typography.body(12)).multilineTextAlignment(.center).lineLimit(2)
                                }
                                .frame(width: 104, height: 118).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 14))
                            } else {
                                HStack(spacing: 6) {
                                    if entry.icon != nil { AppIcon(name: entry.icon, size: 22, tint: coloured ? nil : Theme.Palette.primaryDark) }
                                    Text(loc.label(entry)).font(Theme.Typography.body(13))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.Palette.clientPanel, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func item(_ table: BaseTable, _ id: Int?) -> BaseItem? { baseData.items(table).first { $0.id == id } }
    private func items(_ table: BaseTable, _ ids: [Int]) -> [BaseItem] { ids.compactMap { item(table, $0) } }
    private func names(_ table: BaseTable, _ ids: [Int]) -> String { items(table, ids).map { loc.label($0) }.joined(separator: ", ") }

    // MARK: actions

    private func load() async {
        error = nil
        do {
            try await feedback.run(loc.t("loading_profile_get", "Getting profile")) { try await fetch() }
        } catch { self.error = error }
    }

    /// Re-reads the profile (and so its match state) without the busy card.
    private func refreshQuietly() async { try? await fetch() }

    private func fetch() async throws {
        switch kind {
        case .caregiver(let id): caregiver = try await ClientService().caregiver(id: id)
        case .client(let id): client = try await CaregiverService().client(id: id)
        }
    }

    private func freshState() async throws -> ProfileMatchState? {
        try await fetch()
        return matchState
    }

    private func message() async {
        guard matchState?.status == .active else {
            feedback.toast(loc.t("chat_screen_match_check", "You can only send messages to your current matches.")); return
        }
        do {
            let chat = try await feedback.run(loc.t("loading_chat_create", "Creating a new chat")) {
                try await UserService().createChat(partnerId: partnerId)
            }
            router.push(.chat(chatId: chat.id))
        } catch { feedback.toast(Feedback.message(error)) }
    }

    private enum StateChanged: Error { case changed }

    /// Confirms the state is still the one the action was offered for, sends the one
    /// operation that belongs to it, and re-reads the profile. Accept succeeds only
    /// once the server shows an active match; then "It's a Match!" opens.
    private func perform(_ which: MatchMutation) async {
        guard !busy, let shown = matchState else { return }
        busy = true
        defer { busy = false }
        let label = switch which {
        case .request: loc.t("loading_match_submit", "Submitting match request")
        case .accept: loc.t("loading_match_accept", "Accepting match request")
        case .reject: loc.t("loading_match_reject", "Rejecting match request")
        case .withdraw: loc.t("loading_match_withdraw", "Withdrawing match request")
        case .unmatch: loc.t("loading_unmatch_submit", "Submitting unmatch request")
        }
        let expected: ProfileMatchStatus = switch which {
        case .request: .none
        case .withdraw: .sent
        case .accept, .reject: .received
        case .unmatch: .active
        }
        do {
            try await feedback.run(label) {
                guard let current = try await freshState(), current.status == expected, current == shown || which == .request
                else { throw StateChanged.changed }
                let service = UserService()
                switch which {
                case .request: _ = try await service.requestMatch(partnerId: partnerId, introduction: introduction)
                case .accept: _ = try await service.acceptMatch(id: current.id ?? 0)
                case .reject: try await service.rejectMatch(id: current.id ?? 0)
                case .withdraw: try await service.withdrawMatch(id: current.id ?? 0)
                case .unmatch: _ = try await service.breakMatch(id: current.id ?? 0)
                }
                let after = try await freshState()
                if which == .accept, after?.status != .active { throw StateChanged.changed }
            }
            introduction = ""
            if which == .accept { router.push(.matched(partner: matchedPartner)) }
        } catch {
            await refreshQuietly()
            feedback.toast(error is StateChanged
                ? loc.t("match_state_changed", "This match has changed. Please review the updated profile and try again.")
                : Feedback.message(error))
        }
    }

    private var matchedPartner: MatchedPartner {
        isCaregiver ? .caregiver(id: partnerId) : .client(id: partnerId)
    }

    private func toggleFavorite() async {
        guard let partner else { return }
        let on = partner.isFavorite
        setPartner(partner.with(isFavorite: !on))
        do {
            try await feedback.run(on ? loc.t("loading_favorite_delete", "Removing from favorite list")
                                      : loc.t("loading_favorite_create", "Adding to favorite list")) {
                if on { try await UserService().removeBookmark(partnerId: partner.id) }
                else { try await UserService().addBookmark(partnerId: partner.id) }
            }
            FavoriteSync.post(userId: partner.id, isFavorite: !on)
        } catch {
            setPartner(partner)
            feedback.toast(Feedback.message(error))
        }
    }

    private func setPartner(_ user: User) {
        if let c = caregiver { caregiver = c.with(user: user) }
        if let c = client { client = c.with(user: user) }
    }
}

// MARK: - Match request

enum MatchMutation: Hashable { case request, withdraw, accept, reject, unmatch }

/// The Request a Match confirmation: the question, an optional Introduction, Cancel and
/// Match. Cancel sends nothing.
struct MatchRequestSheet: View {
    @Binding var introduction: String
    let onMatch: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var loc: Localization
    @FocusState private var focused: Bool

    static let limit = 1000

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(loc.t("match_match_message", "Are you sure you want to match with this user? They should accept your request."))
                        .font(Theme.Typography.body(15)).foregroundStyle(Theme.Palette.textSecondary)
                    Text(loc.t("match_introduction_title", "Introduction")).font(Theme.Typography.title(15))
                    TextField(loc.t("match_introduction_message", "You can introduce yourself here (Optional)"),
                              text: $introduction, axis: .vertical)
                        .lineLimit(4...10).padding(12).focused($focused)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.line))
                        .accessibilityLabel(loc.t("match_introduction_title", "Introduction"))
                        .onChange(of: introduction) { _, text in
                            if text.count > Self.limit { introduction = String(text.prefix(Self.limit)) }
                        }
                    Text("\(introduction.count)/\(Self.limit)").font(Theme.Typography.caption(12))
                        .foregroundStyle(Theme.Palette.textSecondary).frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .padding(20)
            }
            .navigationTitle(loc.t("match_match_button", "Request a Match"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("general_cancel", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("match_match_title", "Match"), action: onMatch).fontWeight(.semibold)
                        .accessibilityIdentifier("match-request-confirm")
                }
            }
        }
    }
}

// MARK: - It's a Match!

/// The partner of an "It's a Match!" screen: whose profile it is about.
enum MatchedPartner: Hashable, Sendable {
    case caregiver(id: String), client(id: String)
    var id: String { switch self { case .caregiver(let id), .client(let id): return id } }
}

/// "It's a Match!", shown after accepting a request and from a request-accepted
/// notification (`match_accept`). It replaces the old Pending screen. The match is
/// re-checked when the screen opens (profile `match_status` and the connection itself),
/// so a stale notification shows that the match is no longer active instead.
struct MatchedView: View {
    let partnerRef: MatchedPartner

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var partner: User?
    @State private var stale = false
    @State private var error: Error?
    @AccessibilityFocusState private var headingFocused: Bool

    private var profileRoute: Route {
        switch partnerRef {
        case .caregiver(let id): return .caregiverDetails(caregiverId: id)
        case .client(let id): return .clientDetails(clientId: id)
        }
    }

    var body: some View {
        Group {
            if let error {
                ErrorState(message: Feedback.message(error)) { Task { await load() } }
            } else if stale {
                VStack(spacing: 14) {
                    AppIcon(name: "ic_match_off", size: 56, tint: Theme.Palette.textSecondary)
                    Text(loc.t("match_no_longer_active", "This match is no longer active."))
                        .font(Theme.Typography.title(17)).multilineTextAlignment(.center)
                    WideButton(title: loc.t("profile_matches_title", "Matches"), style: .outline) {
                        router.pop(); router.push(.manageMatches)
                    }
                }
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let partner {
                content(partner)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .backHeader(loc.t("match_matched_title", "It's a Match!"))
        .task { await load() }
    }

    private func content(_ partner: User) -> some View {
        let name = partner.firstName ?? ""
        return ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: -14) {
                    Avatar(url: session.state.user?.photo, size: 96)
                    AppIcon(name: "ic_match_on", size: 22, tint: Theme.Palette.primary)
                        .frame(width: 40, height: 40).background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1).zIndex(1)
                        .accessibilityHidden(true)
                    Avatar(url: partner.photo, size: 96).accessibilityLabel(partner.fullName)
                }
                .padding(.top, 12)
                Text(loc.t("match_matched_prompt", "You and {PARTNER} have matched!").replacingOccurrences(of: "{PARTNER}", with: name))
                    .font(Theme.Typography.heading(22)).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    // VoiceOver starts here, not on the first info row.
                    .accessibilityFocused($headingFocused)
                Text(loc.t("match_matched_message", "You can now start messaging each other, discuss care needs, and next steps."))
                    .font(Theme.Typography.body(15)).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) {
                    info("ic_message", loc.t("match_matched_chat_title", "Start a Conversation"),
                         loc.t("match_matched_chat_message", "Send a message and get to know each other."))
                    info("ic_calendar", loc.t("match_matched_plan_title", "Plan Next Steps"),
                         loc.t("match_matched_plan_message", "Discuss care needs and availability."))
                    info("ic_match_on", loc.t("match_matched_fit_title", "A Better Care Experience"),
                         loc.t("match_matched_fit_message", "Find the right care together."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            }
            .padding(20).padding(.bottom, 140)
        }
        .bottomAction {
            VStack(spacing: 10) {
                WideButton(title: loc.t("match_matched_chat_button", "Send a Message"), icon: "ic_message") { Task { await chat() } }
                WideButton(title: loc.t("match_matched_profile_button", "View Profile"), style: .outline) { openProfile() }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
    }

    private func info(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(name: icon, size: 22, tint: Theme.Palette.primary)
                .frame(width: 40, height: 40).background(Theme.Palette.clientPanel, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typography.title(15))
                Text(text).font(Theme.Typography.body(14)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Back to the profile the user accepted from, or to it fresh from a notification.
    private func openProfile() {
        let path = router.path
        if path.count >= 2, path[path.count - 2] == profileRoute { router.pop() }
        else { router.pop(); router.push(profileRoute) }
    }

    /// The profile must say `active` for this partner and the connection it names must be
    /// active with them; anything else is a stale or invalid target.
    private func activeProfile() async throws -> (ProfileMatchState, User)? {
        let state: ProfileMatchState?
        let user: User
        switch partnerRef {
        case .caregiver(let id):
            guard session.role == .client else { return nil }
            let p = try await ClientService().caregiver(id: id); state = p.matchState; user = p.user
        case .client(let id):
            guard session.role == .caregiver else { return nil }
            let p = try await CaregiverService().client(id: id); state = p.matchState; user = p.user
        }
        guard let state, state.status == .active else { return nil }
        return (state, user)
    }

    private func load() async {
        error = nil; stale = false
        do {
            try await feedback.run(loc.t("loading_match_get", "Getting match details")) {
                guard let (state, user) = try await activeProfile(), let id = state.id else { stale = true; return }
                let connection = try await UserService().match(id: id)
                let other = session.role == .client ? connection.caregiver?.id : connection.client?.id
                guard connection.stage == .active, other == partnerRef.id else { stale = true; return }
                partner = user
            }
            if partner != nil {
                try? await Task.sleep(for: .milliseconds(600))
                headingFocused = true
            }
        } catch { self.error = error }
    }

    private func chat() async {
        do {
            try await feedback.run(loc.t("loading_chat_create", "Creating a new chat")) {
                guard try await activeProfile() != nil else { stale = true; return }
                let conversation = try await UserService().createChat(partnerId: partnerRef.id)
                router.push(.chat(chatId: conversation.id))
            }
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
