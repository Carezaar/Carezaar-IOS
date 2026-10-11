import SwiftUI

/// Native partner profile: load once per opening, and re-check only when the user
/// explicitly confirms a relationship mutation. Messaging is offered only for an
/// active relationship; failed checks never replay a mutation automatically.
struct PartnerDetailsView: View {
    enum Kind: Hashable { case caregiver(id: String), client(id: String) }
    let kind: Kind

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var caregiver: CaregiverFull?
    @State private var client: ClientFull?
    @State private var error: Error?
    @State private var confirming: MatchMutation?
    @State private var requesting = false
    @State private var introduction = ""
    @State private var busy = false
    @State private var didLoad = false
    @State private var visible = false
    @State private var delayedBack: Task<Void, Never>?
    @State private var checkUnavailable = false
    @State private var failedCheckAction: MatchMutation?

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
                Text(Feedback.message(error)).font(Theme.Typography.body(15)).padding(24)
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
        .onAppear { visible = true }
        .onDisappear { visible = false; delayedBack?.cancel(); delayedBack = nil }
        .task { await load() }
        .alert(loc.t("match_check_failed_title", "Couldn't check this match"), isPresented: $checkUnavailable) {
            Button(loc.t("general_cancel", "Cancel"), role: .cancel) { failedCheckAction = nil }
            Button(loc.t("general_try_again", "Try Again")) {
                // Retry the read only. The user must confirm any mutation again.
                Task { await retryCheck() }
            }
        } message: { Text(loc.t("match_check_failed_message", "Please check your connection and try again.")) }
        .alert(confirming.map(title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming == .withdraw ? loc.t("general_close", "Close") : loc.t("general_cancel", "Cancel"), role: .cancel) { confirming = nil }
                .accessibilityIdentifier("match-confirm-dismiss")
            if let which = confirming {
                Button(confirmLabel(which), role: which == .accept ? nil : .destructive) {
                    confirming = nil
                    Task { await perform(which) }
                }
                .accessibilityIdentifier("match-action-confirm")
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
                if !isCaregiver {
                    section(loc.t("client_details_gender_preferences", "Gender Preferences"), items(.genders, client?.genderIds ?? []))
                    section(loc.t("client_details_experience", "Minimum Experience"), items(.experiences, client?.experienceIds ?? []))
                    section(loc.t("client_details_role", "Preferred Caregiver Role"), items(.roles, client?.roleIds ?? []))
                }
                if isCaregiver {
                    section(loc.t("caregiver_details_supported_care_needer_types", "Supported Care Needer Types"),
                            items(.clienttypes, caregiver?.clienttypeIds ?? []), coloured: true)
                }
            }
            .padding(20).padding(.bottom, 90)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if matchState?.status == .sent {
                    Label(loc.t("match_pending_acceptance", "Pending Acceptance"), systemImage: "clock")
                        .font(Theme.Typography.control(14)).foregroundStyle(Theme.Palette.warning)
                        .accessibilityAddTraits(.isStaticText)
                }
                AdaptiveStack(alignment: .center, spacing: 12, stackedSpacing: 8) {
                    if matchState?.status == .active {
                        WideButton(title: loc.t("\(prefix)_message", "Message"), icon: "ic_message", style: .outline) { Task { await message() } }
                    }
                    matchButtons
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.white)
        }
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
                WideButton(title: loc.t("match_withdraw_title", "Cancel"), icon: "ic_match_off", style: .outline) { ask(.withdraw) }
                    .accessibilityIdentifier("match-withdraw")
            case .received:
                WideButton(title: loc.t("match_reject_title", loc.t("match_reject", "Reject")), style: .danger) { ask(.reject) }
                    .accessibilityIdentifier("match-reject")
                WideButton(title: loc.t("match_accept_title", "Accept"), icon: "ic_match_on") { ask(.accept) }
                    .accessibilityIdentifier("match-accept")
            case .active:
                WideButton(title: loc.t("match_unmatch_title", "Unmatch"), icon: "ic_match_off", style: .danger) { ask(.unmatch) }
                    .accessibilityIdentifier("match-unmatch")
            }
        }
    }

    private func ask(_ which: MatchMutation) { if !busy { confirming = which } }

    private func title(_ which: MatchMutation) -> String {
        switch which {
        case .request: return loc.t("match_match_button", "Request a Match")
        case .accept: return loc.t("match_accept_title", "Accept")
        case .reject: return loc.t("match_reject_title", loc.t("match_reject", "Reject"))
        case .withdraw: return loc.t("match_withdraw_title", "Cancel")
        case .unmatch: return loc.t("match_unmatch_title", "Unmatch")
        }
    }

    private func confirmLabel(_ which: MatchMutation) -> String {
        switch which {
        case .request: return loc.t("match_match_title", "Match")
        case .withdraw: return loc.t("match_withdraw_title", "Cancel")
        case .accept: return loc.t("match_accept_title", "Accept")
        case .reject: return loc.t("match_reject_title", loc.t("match_reject", "Reject"))
        case .unmatch: return loc.t("match_unmatch_title", "Unmatch")
        }
    }

    private func confirmMessage(_ which: MatchMutation) -> String {
        let question: String
        switch which {
        case .request: question = loc.t("match_match_message", "Are you sure you want to match with this user? They should accept your request.")
        case .accept: question = loc.t("match_accept_message", "Are you sure you want to accept this match request?")
        case .reject: question = loc.t("match_reject_message", "Are you sure you want to reject this match request?")
        case .withdraw: question = loc.t("match_withdraw_message", "Are you sure you want to cancel this match request?")
        case .unmatch: question = loc.t("match_unmatch_message", "Are you sure you want to end your match with this user?")
        }
        if (which == .accept || which == .reject), let introduction = matchIntroduction,
           !introduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return question + "\n\n" + loc.t("match_introduction_title", "Introduction") + "\n" + introduction
        }
        return question
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
        guard !didLoad else { return }
        didLoad = true
        error = nil
        do {
            try await feedback.run(loc.t("loading_profile_get", "Getting profile")) { try await fetch() }
            if matchState == nil { checkUnavailable = true }
        } catch is CancellationError { return }
        catch { failAndReturn(error) }
    }

    private func failAndReturn(_ failure: Error) {
        guard visible else { return }
        error = failure
        feedback.toast(Feedback.message(failure))
        let openedRoute = router.path.last
        delayedBack?.cancel()
        delayedBack = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, visible, router.path.last == openedRoute else { return }
            router.pop()
        }
    }

    private func retryCheck() async {
        do {
            try await fetch()
            guard matchState != nil else { checkUnavailable = true; return }
            // Confirmation remains a separate user action, preventing an ambiguous replay.
            failedCheckAction = nil
        } catch is CancellationError { return }
        catch { checkUnavailable = true }
    }

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
            guard visible, !Task.isCancelled else { return }
            router.push(.chat(chatId: chat.id))
        } catch { feedback.toast(Feedback.message(error)) }
    }

    /// Confirms the state is still the one the action was offered for, sends the one
    /// operation that belongs to it, and re-reads the profile. Accept succeeds only
    /// once the server shows an active match; then "It's a Match!" opens.
    private func perform(_ which: MatchMutation) async {
        guard !busy, let shown = matchState else { return }
        busy = true
        defer { busy = false }
        let expected = which.expectedStatus
        let current: ProfileMatchState
        do {
            let checked = try await freshState()
            guard visible, !Task.isCancelled else { return }
            guard let checked else {
                failedCheckAction = which; checkUnavailable = true; return
            }
            current = checked
        } catch is CancellationError { return }
        catch {
            guard visible, !Task.isCancelled else { return }
            failedCheckAction = which; checkUnavailable = true; return
        }
        guard visible, !Task.isCancelled else { return }
        guard current.status == expected, current == shown else {
            feedback.toast(loc.t("match_changed_message", "This match has changed")); return
        }
        do {
            let result: Match? = try await feedback.run(loc.t(which.loadingKey, which.loadingFallback)) {
                let service = UserService()
                switch which {
                case .request: return try await service.requestMatch(partnerId: partnerId, introduction: introduction)
                case .accept: return try await service.acceptMatch(id: current.id ?? 0)
                case .reject: try await service.rejectMatch(id: current.id ?? 0); return nil
                case .withdraw: try await service.withdrawMatch(id: current.id ?? 0); return nil
                case .unmatch: return try await service.breakMatch(id: current.id ?? 0)
                }
            }
            guard visible, !Task.isCancelled else { return }
            introduction = ""
            if (which == .request || which == .accept), result?.isActive(with: partnerId, for: session.role ?? .client) == true {
                // The mutation response confirms an active relationship. MatchedView
                // obtains the profile once; no separate connection check is needed.
                applyMatchResult(result!)
                router.push(.matched(partner: matchedPartner))
            } else {
                try await fetch() // Explicit mutation reconciliation, never appearance refresh.
                guard visible, !Task.isCancelled else { return }
                guard let reconciled = matchState else {
                    failedCheckAction = which; checkUnavailable = true; return
                }
                if (which == .accept || which == .request), reconciled.status == .active {
                    router.push(.matched(partner: matchedPartner))
                } else if which == .accept {
                    feedback.toast(loc.t("match_changed_message", "This match has changed"))
                }
            }
        } catch is CancellationError { return }
        catch {
            // Never retry the write: it may have succeeded before the response was lost.
            guard visible, !Task.isCancelled else { return }
            let reconciled: ProfileMatchState?
            do {
                reconciled = try await freshState()
            } catch is CancellationError { return }
            catch {
                guard visible, !Task.isCancelled else { return }
                failedCheckAction = which; checkUnavailable = true; return
            }
            guard visible, !Task.isCancelled else { return }
            switch MatchFailureResolution.resolve(before: current, after: reconciled) {
            case .changed: feedback.toast(loc.t("match_changed_message", "This match has changed"))
            case .checkUnavailable: failedCheckAction = which; checkUnavailable = true
            case .originalError: feedback.toast(Feedback.message(error))
            }
        }
    }

    private func applyMatchResult(_ match: Match) {
        if let value = caregiver { caregiver = value.with(matchStatus: "active", matchId: match.id) }
        if let value = client { client = value.with(matchStatus: "active", matchId: match.id) }
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

/// Presentation chosen after a failed write has been reconciled with a fresh profile.
/// Missing/failed checks cannot justify replay; a changed state gets the standard
/// changed message. An unchanged state retains the original operation error.
/// Kept separate from transport so lost-response behavior can be regression-tested.
enum MatchFailureResolution: Equatable {
    case changed, checkUnavailable, originalError

    static func resolve(before: ProfileMatchState, after: ProfileMatchState?) -> Self {
        guard let after else { return .checkUnavailable }
        return after == before ? .originalError : .changed
    }
}

// MARK: - Match request

enum MatchMutation: Hashable {
    case request, withdraw, accept, reject, unmatch
    var expectedStatus: ProfileMatchStatus {
        switch self { case .request: .none; case .withdraw: .sent; case .accept, .reject: .received; case .unmatch: .active }
    }
    var loadingKey: String {
        switch self { case .request: "loading_match_submit"; case .withdraw: "loading_match_withdraw"; case .accept: "loading_match_accept"; case .reject: "loading_match_reject"; case .unmatch: "loading_unmatch_submit" }
    }
    var loadingFallback: String {
        switch self { case .request: "Submitting match request"; case .withdraw: "Cancelling match request"; case .accept: "Accepting match request"; case .reject: "Rejecting match request"; case .unmatch: "Submitting unmatch request" }
    }
}

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

/// Successful match presentation. One profile read supplies current relationship
/// information; an inactive relationship routes directly to that person's profile.
struct MatchedView: View {
    let partnerRef: MatchedPartner

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var partner: User?
    @State private var didLoad = false
    @State private var visible = false
    @State private var delayedBack: Task<Void, Never>?
    @EnvironmentObject private var baseData: BaseDataStore
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
                Text(Feedback.message(error)).font(Theme.Typography.body(15)).padding(24)
            } else if let partner {
                content(partner)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .backHeader(loc.t("match_matched_title", "It's a Match!"))
        .onAppear { visible = true }
        .onDisappear { visible = false; delayedBack?.cancel(); delayedBack = nil }
        .task { await load() }
    }

    private func content(_ partner: User) -> some View {
        let name = partner.fullName
        return ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    photoCard(session.state.user, label: loc.t("chat_screen_chats_you", "You"))
                    Image(systemName: "heart.fill").font(.system(size: 24)).foregroundStyle(Theme.Palette.primary)
                        .accessibilityHidden(true)
                    photoCard(partner, label: partner.fullName)
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

    private func photoCard(_ user: User?, label: String) -> some View {
        VStack(spacing: 8) {
            PhotoBox(url: user?.photo, width: 96, height: 128, radius: 12)
            Text(label).font(Theme.Typography.title(15)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(roleLabel(user?.role)).font(Theme.Typography.caption(12))
                .foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(8).background(Theme.Palette.clientPanel, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func roleLabel(_ role: UserRole?) -> String {
        guard let role else { return "" }
        return role == .client ? loc.t("general_usertype_client", "Client") : loc.t("general_usertype_caregiver", "Caregiver")
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

    /// The profile must identify an active relationship with this partner. There is
    /// no redundant GET for the connection itself.
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
        guard !didLoad else { return }
        didLoad = true
        error = nil
        do {
            try await feedback.run(loc.t("loading_match_get", "Getting match details")) {
                let profile = try await activeProfile()
                guard visible, !Task.isCancelled else { return }
                guard let (_, user) = profile else { openProfile(); return }
                partner = user
            }
            if partner != nil, visible {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled, visible { headingFocused = true }
            }
        } catch is CancellationError { return }
        catch {
            guard visible else { return }
            self.error = error
            feedback.toast(Feedback.message(error))
            let openedRoute = router.path.last
            delayedBack = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, visible, router.path.last == openedRoute else { return }
                router.pop()
            }
        }
    }

    private func chat() async {
        guard partner != nil else { return }
        do {
            try await feedback.run(loc.t("loading_chat_create", "Creating a new chat")) {
                // A single profile read already confirmed active on this opening.
                // The create-chat endpoint remains the authority for authorization.
                let conversation = try await UserService().createChat(partnerId: partnerRef.id)
                guard visible, !Task.isCancelled else { return }
                router.push(.chat(chatId: conversation.id))
            }
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
