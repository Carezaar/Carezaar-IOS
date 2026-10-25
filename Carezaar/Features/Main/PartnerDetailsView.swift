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
    /// Every action on this person's match shares one guard (ActionGuard, `match:<partner id>`):
    /// accept and reject, a double tap, or the same action from a reopened screen never run at once.
    @ObservedObject private var guards = ActionGuard.shared
    private var busy: Bool { guards.isBusy(matchResource) }
    private var matchResource: String { "match:\(partnerId)" }
    /// Which action is running, for the progress indicator on its own button.
    @State private var working: MatchMutation?
    @State private var didLoad = false
    @State private var visible = false
    @State private var delayedBack: Task<Void, Never>?
    @State private var checkUnavailable = false
    @State private var pendingIntent: MatchActionIntent?
    @StateObject private var favorites = FavoriteMutationCoordinator.shared

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
            if error != nil, partner == nil {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let partner {
                content(partner)
            } else {
                ScrollView { SkeletonDetail() }
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
            Button(loc.t("general_cancel", "Cancel"), role: .cancel) {
                // Cancelling the window cannot erase an uncertain write outcome.
                if pendingIntent?.canSubmit == true { pendingIntent = nil }
            }
            Button(loc.t("general_try_again", "Try Again")) {
                Task { await retryCheck() }
            }
        } message: { Text(loc.t("match_check_failed_message", "Please check your connection and try again.")) }
        .alert(confirming.map(title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(loc.t("general_cancel", "Cancel"), role: .cancel) { confirming = nil }
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
                            Text(partner.displayName(loc)).font(Theme.Typography.heading(21))
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
                        WideButton(title: loc.t("\(prefix)_message", "Message"), icon: "ic_message", style: .outline,
                                   loading: guards.isBusy("chat:create:\(partnerId)")) { Task { await message() } }
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
                WideButton(title: loc.t("match_match_button", "Request a Match"), icon: "ic_match_on", enabled: !busy, loading: working == .request) {
                    guard !busy else { return }
                    introduction = ""
                    requesting = true
                }
                .accessibilityIdentifier("match-request")
            case .sent:
                WideButton(title: loc.t("match_withdraw_title", "Withdraw"), icon: "ic_match_off", style: .outline, enabled: !busy, loading: working == .withdraw) { ask(.withdraw) }
                    .accessibilityIdentifier("match-withdraw")
            case .received:
                WideButton(title: loc.t("match_reject_title", loc.t("match_reject", "Reject")), style: .danger, enabled: !busy, loading: working == .reject) { ask(.reject) }
                    .accessibilityIdentifier("match-reject")
                WideButton(title: loc.t("match_accept_title", "Accept"), icon: "ic_match_on", enabled: !busy, loading: working == .accept) { ask(.accept) }
                    .accessibilityIdentifier("match-accept")
            case .active:
                WideButton(title: loc.t("match_unmatch_title", "Unmatch"), icon: "ic_match_off", style: .danger, enabled: !busy, loading: working == .unmatch) { ask(.unmatch) }
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
        case .withdraw: return loc.t("match_withdraw_title", "Withdraw")
        case .unmatch: return loc.t("match_unmatch_title", "Unmatch")
        }
    }

    private func confirmLabel(_ which: MatchMutation) -> String {
        switch which {
        case .request: return loc.t("match_match_title", "Match")
        case .withdraw: return loc.t("match_withdraw_title", "Withdraw")
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
        case .withdraw: question = loc.t("match_withdraw_message", "Are you sure you want to withdraw your match request with this user?")
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
            try await fetch() // a skeleton stands in for the profile until it arrives
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
        if let intent = pendingIntent {
            await continueIntent(intent)
            return
        }
        guard !busy else { return }
        _ = try? await ActionGuard.shared.run(matchResource) {
            do {
                try await fetch()
                guard visible, !Task.isCancelled else { return }
                if matchState == nil { checkUnavailable = true }
            } catch is CancellationError { return }
            catch { if visible { checkUnavailable = true } }
        }
    }

    private func fetch(generation: UUID? = nil) async throws {
        switch kind {
        case .caregiver(let id): caregiver = try await ClientService().caregiver(id: id, ifGeneration: generation)
        case .client(let id): client = try await CaregiverService().client(id: id, ifGeneration: generation)
        }
    }

    private func freshState(generation: UUID? = nil) async throws -> ProfileMatchState? {
        try await fetch(generation: generation)
        return matchState
    }

    private func message() async {
        guard matchState?.status == .active else {
            feedback.toast(loc.t("chat_screen_match_check", "You can only send messages to your current matches.")); return
        }
        do {
            let chat = try await ActionGuard.shared.run("chat:create:\(partnerId)") {
                try await UserService().createChat(partnerId: partnerId)
            }
            guard visible, !Task.isCancelled else { return }
            router.push(.chat(chatId: chat.id))
        } catch { feedback.toast(Feedback.message(error)) }
    }

    /// Preserve the exact confirmed action, original relationship and introduction.
    /// A failed preflight can resume it; an uncertain write can only be reconciled.
    private func perform(_ which: MatchMutation) async {
        guard !busy, let shown = matchState else { return }
        if let unresolved = pendingIntent, !unresolved.canSubmit {
            await continueIntent(unresolved)
            return
        }
        let intent = MatchActionIntent(action: which, before: shown, introduction: introduction, generation: TokenStore.shared.generation)
        pendingIntent = intent
        await continueIntent(intent)
    }

    private func continueIntent(_ intent: MatchActionIntent) async {
        guard !busy, visible, !Task.isCancelled, TokenStore.shared.generation == intent.generation else { return }
        working = intent.action
        defer { working = nil }
        _ = try? await ActionGuard.shared.run(matchResource) { await guardedIntent(intent) }
    }

    private func guardedIntent(_ intent: MatchActionIntent) async {
        let checked: ProfileMatchState?
        do { checked = try await freshState(generation: intent.generation) }
        catch is CancellationError { return }
        catch {
            if visible, TokenStore.shared.generation == intent.generation { pendingIntent = intent; checkUnavailable = true }
            return
        }
        guard visible, !Task.isCancelled, TokenStore.shared.generation == intent.generation else { return }
        guard let checked else { pendingIntent = intent; checkUnavailable = true; return }
        // A match request carries an Idempotency-Key: after a lost answer, while the profile still
        // shows no request, it may be sent again with the same key (the server keeps one).
        let resendable = intent.action == .request && checked.status == .none
        guard intent.canSubmit || resendable, checked == intent.before,
              checked.status == intent.action.expectedStatus else {
            resolve(intent, checked: checked)
            return
        }
        var submitted = intent
        submitted.phase = .uncertain(APIError.unknown(""))
        pendingIntent = submitted // Set before suspension: no tap can replay this write.
        do {
            let result: Match? = try await {
                let service = UserService()
                switch intent.action {
                case .request: return try await service.requestMatch(partnerId: partnerId, introduction: intent.introduction, ifGeneration: intent.generation)
                case .accept: return try await service.acceptMatch(id: checked.id!, ifGeneration: intent.generation)
                case .reject: try await service.rejectMatch(id: checked.id!, ifGeneration: intent.generation); return nil
                case .withdraw: try await service.withdrawMatch(id: checked.id!, ifGeneration: intent.generation); return nil
                case .unmatch: return try await service.breakMatch(id: checked.id!, ifGeneration: intent.generation)
                }
            }()
            submitted.phase = .acknowledged
            pendingIntent = submitted
            guard visible, !Task.isCancelled, TokenStore.shared.generation == intent.generation else { return }
            if (intent.action == .request || intent.action == .accept),
               let result, result.isActive(with: partnerId, for: session.role ?? .client),
               intent.action == .request || result.id == checked.id {
                applyMatchResult(result)
                complete(intent, matched: true)
                return
            }
        } catch is CancellationError { return }
        catch {
            guard MutationOutcome.mayHaveCommitted(error) else {
                pendingIntent = nil
                if visible, !Task.isCancelled { feedback.toast(Feedback.message(error)) }
                return
            }
            submitted.phase = .uncertain(error)
            pendingIntent = submitted
            guard visible, !Task.isCancelled, TokenStore.shared.generation == intent.generation else { return }
        }
        // Acknowledged and ambiguous writes both use a read, never another mutation.
        do {
            let actual = try await freshState(generation: intent.generation)
            guard visible, !Task.isCancelled, TokenStore.shared.generation == intent.generation else { return }
            resolve(submitted, checked: actual)
        } catch is CancellationError { return }
        catch { if visible, TokenStore.shared.generation == intent.generation { checkUnavailable = true } }
    }

    private func resolve(_ intent: MatchActionIntent, checked: ProfileMatchState?) {
        switch MatchFailureResolution.resolve(before: intent.before, after: checked, action: intent.action) {
        case .matched: complete(intent, matched: true)
        case .completed: complete(intent, matched: false)
        case .changed:
            pendingIntent = nil
            feedback.toast(loc.t("match_changed_message", "This match has changed"))
        case .checkUnavailable:
            pendingIntent = intent
            checkUnavailable = true
        case .originalError:
            if intent.canSubmit { pendingIntent = nil }
            else { pendingIntent = intent }
            feedback.toast(Feedback.message(intent.failure ?? APIError.unknown("")))
        }
    }

    private func complete(_ intent: MatchActionIntent, matched: Bool) {
        pendingIntent = nil
        // The profile shows how the request ended: its key is done with.
        if intent.action == .request { IdempotencyStore.shared.retireAll(.matchRequest, target: partnerId) }
        if intent.action == .request, introduction == intent.introduction { introduction = "" }
        if matched { router.push(.matched(partner: matchedPartner)) }
    }

    private func applyMatchResult(_ match: Match) {
        if let value = caregiver { caregiver = value.with(matchStatus: "active", matchId: match.id) }
        if let value = client { client = value.with(matchStatus: "active", matchId: match.id) }
    }

    private var matchedPartner: MatchedPartner {
        isCaregiver ? .caregiver(id: partnerId) : .client(id: partnerId)
    }

    private func toggleFavorite() async {
        guard let partner, !favorites.isBusy(partner: partner, accountId: session.state.user?.id) else { return }
        let accountId = session.state.user?.id
        let generation = TokenStore.shared.generation
        let on = partner.isFavorite
        setPartner(partner.with(isFavorite: !on))
        do {
            // FavoriteMutationCoordinator is the shared guard for one person's favourite.
            let saved = try await favorites.change(partner: partner, to: !on, profileId: partnerId, accountId: accountId, generation: generation)
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            setPartner(saved)
            FavoriteSync.post(userId: partner.id, isFavorite: saved.isFavorite)
        } catch is CancellationError { return }
        catch let failure as FavoriteReconciliationError {
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            setPartner(failure.saved)
            FavoriteSync.post(userId: partner.id, isFavorite: failure.saved.isFavorite)
            feedback.toast(Feedback.message(failure.underlying))
        } catch {
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            setPartner(partner)
            feedback.toast(Feedback.message(error))
        }
    }

    private func setPartner(_ user: User) {
        if let c = caregiver { caregiver = c.with(user: user) }
        if let c = client { client = c.with(user: user) }
    }
}

/// A failed write may still have saved. Carry the actual profile state with a
/// managed failure, rather than rolling the UI back to a guessed old value.
struct FavoriteReconciliationError: Error {
    let saved: User
    let underlying: Error
}

/// Shared by list/profile entry points so cross-screen taps cannot overlap writes.
@MainActor
final class FavoriteMutationCoordinator: ObservableObject {
    static let shared = FavoriteMutationCoordinator()
    private let service: UserService
    init(service: UserService = UserService()) { self.service = service }

    private struct PartnerKey: Hashable {
        let accountId: String?
        let userId: String
        let role: UserRole
    }
    private struct Submission: Hashable {
        let partner: PartnerKey
        let desired: Bool
        let generation: UUID
    }
    private struct Pending {
        let profileId: String
        let error: Error
    }
    @Published private var busy = Set<PartnerKey>()
    private var pending: [Submission: Pending] = [:]

    func isBusy(partner: User, accountId: String?) -> Bool {
        busy.contains(PartnerKey(accountId: accountId, userId: partner.id, role: partner.role))
    }

    func change(partner: User, to desired: Bool, profileId: String? = nil, accountId: String? = nil, generation: UUID? = nil) async throws -> User {
        let key = PartnerKey(accountId: accountId, userId: partner.id, role: partner.role)
        guard !busy.contains(key) else { throw APIError.unknown("") }
        busy.insert(key)
        defer { busy.remove(key) }
        let owner = await service.client.credentialGeneration()
        guard generation == nil || generation == owner else { throw CancellationError() }
        let submission = Submission(partner: key, desired: desired, generation: owner)
        if let unresolved = pending[submission] {
            return try await reconcile(submission, pending: unresolved)
        }
        do {
            if desired { try await service.addBookmark(partnerId: partner.id, ifGeneration: owner) }
            else { try await service.removeBookmark(partnerId: partner.id, ifGeneration: owner) }
            return partner.with(isFavorite: desired)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard MutationOutcome.mayHaveCommitted(error) else { throw error }
            let unresolved = Pending(profileId: profileId ?? partner.id, error: error)
            pending[submission] = unresolved
            return try await reconcile(submission, pending: unresolved)
        }
    }

    private func reconcile(_ submission: Submission, pending unresolved: Pending) async throws -> User {
        let saved: User
        do {
            let path = submission.partner.role == .caregiver
                ? "clients/caregivers/\(unresolved.profileId)" : "caregivers/clients/\(unresolved.profileId)"
            let snapshot: FavoriteProfileSnapshot = try await service.client.send(Endpoint(method: .get, path: path), ifGeneration: submission.generation)
            saved = snapshot.user
        } catch is CancellationError { throw CancellationError() }
        catch { throw unresolved.error }
        guard saved.id == submission.partner.userId, saved.role == submission.partner.role else {
            throw unresolved.error
        }
        guard saved.isFavorite == submission.desired else {
            throw FavoriteReconciliationError(saved: saved, underlying: unresolved.error)
        }
        pending.removeValue(forKey: submission)
        return saved
    }
}

/// Unknown removals need an explicit saved flag; User's display fallback false
/// is not proof that a mutation reached the server.
private struct FavoriteProfileSnapshot: Decodable {
    let user: User
    private enum Keys: String, CodingKey { case user }
    private enum UserKeys: String, CodingKey { case role; case favorite = "is_favorite" }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fields = try container.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        _ = try fields.decode(Bool.self, forKey: .favorite)
        let role = try fields.decode(String.self, forKey: .role)
        guard UserRole(rawValue: role.lowercased()) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .role, in: fields, debugDescription: "Unknown favorite role")
        }
        user = try container.decode(User.self, forKey: .user)
    }
}

/// Confirmed intent and delivery phase survive connection windows and later taps.
struct MatchActionIntent {
    enum Phase { case preflight, uncertain(Error), acknowledged }
    let action: MatchMutation
    let before: ProfileMatchState
    let introduction: String
    let generation: UUID
    var phase: Phase = .preflight
    var canSubmit: Bool { if case .preflight = phase { return true }; return false }
    var failure: Error? { if case .uncertain(let error) = phase { return error }; return nil }
}

/// An own action reaching its requested outcome is success, not an external change.
/// Same-status replacement relationship IDs cannot authorize or acknowledge an action.
enum MatchFailureResolution: Equatable {
    case matched, completed, changed, checkUnavailable, originalError

    static func resolve(before: ProfileMatchState, after: ProfileMatchState?, action: MatchMutation? = nil) -> Self {
        guard let after else { return .checkUnavailable }
        guard after != before else { return .originalError }
        let intent = action ?? inferredAction(before.status)
        guard before.status == intent.expectedStatus else { return .changed }
        switch intent {
        case .request:
            if after.status == .active { return .matched }
            if after.status == .sent { return .completed }
        case .accept:
            if after.id == before.id, after.status == .active { return .matched }
        case .withdraw, .reject, .unmatch:
            if after.status == .none { return .completed }
        }
        return .changed
    }

    private static func inferredAction(_ status: ProfileMatchStatus) -> MatchMutation {
        switch status { case .none: .request; case .sent: .withdraw; case .received: .accept; case .active: .unmatch }
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
        switch self { case .request: "Submitting match request"; case .withdraw: "Withdrawing match request"; case .accept: "Accepting match request"; case .reject: "Rejecting match request"; case .unmatch: "Submitting unmatch request" }
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
                    // A long localized action can consume the native toolbar's
                    // title space. Keep this task heading in the full-width form.
                    Text(loc.t("match_match_button", "Request a Match"))
                        .font(Theme.Typography.title(20))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("match-request-heading")
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
            .accessibilityIdentifier("match-request-content")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("general_cancel", "Cancel"), action: onCancel)
                        .accessibilityIdentifier("match-request-dismiss")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var cardLayoutDirection
    @State private var cardsPresented = false

    private var profileRoute: Route {
        switch partnerRef {
        case .caregiver(let id): return .caregiverDetails(caregiverId: id)
        case .client(let id): return .clientDetails(clientId: id)
        }
    }

    var body: some View {
        Group {
            if error != nil {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let partner {
                content(partner)
            } else {
                ScrollView { SkeletonDetail() }
            }
        }
        .backHeader(loc.t("match_matched_title", "It's a Match!"))
        .onAppear { visible = true }
        .onDisappear { visible = false; delayedBack?.cancel(); delayedBack = nil }
        .task { await load() }
    }

    private func content(_ partner: User) -> some View {
        let name = partner.displayName(loc)
        return ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    photoCard(session.state.user, label: loc.t("chat_screen_you", "You"))
                        .rotationEffect(.degrees(reduceMotion || cardsPresented ? (cardLayoutDirection == .rightToLeft ? 6 : -6) : 0))
                        .offset(x: reduceMotion || cardsPresented ? 0 : (cardLayoutDirection == .rightToLeft ? 180 : -180))
                        .opacity(cardsPresented ? 1 : 0)
                        .accessibilityIdentifier("matched-self-photo-card")
                    Image(systemName: "heart.fill").font(.system(size: 24)).foregroundStyle(Theme.Palette.primary)
                        .accessibilityHidden(true)
                    photoCard(partner, label: partner.displayName(loc))
                        .rotationEffect(.degrees(reduceMotion || cardsPresented ? (cardLayoutDirection == .rightToLeft ? -6 : 6) : 0))
                        .offset(x: reduceMotion || cardsPresented ? 0 : (cardLayoutDirection == .rightToLeft ? -180 : 180))
                        .opacity(cardsPresented ? 1 : 0)
                        .accessibilityIdentifier("matched-partner-photo-card")
                }
                .padding(.top, 12)
                .task {
                    guard !cardsPresented, !Task.isCancelled else { return }
                    // One entrance per presentation. Reduced Motion keeps the cards
                    // in place and reveals them without vestibular movement.
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.55, dampingFraction: 0.9)) {
                        cardsPresented = true
                    }
                }
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
        let generation = TokenStore.shared.generation
        let state: ProfileMatchState?
        let user: User
        switch partnerRef {
        case .caregiver(let id):
            guard session.role == .client else { return nil }
            let p = try await ClientService().caregiver(id: id, ifGeneration: generation); state = p.matchState; user = p.user
        case .client(let id):
            guard session.role == .caregiver else { return nil }
            let p = try await CaregiverService().client(id: id, ifGeneration: generation); state = p.matchState; user = p.user
        }
        guard let state, state.status == .active else { return nil }
        return (state, user)
    }

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        error = nil
        do {
            // A skeleton stands in for the profile until it arrives.
            let profile = try await activeProfile()
            guard visible, !Task.isCancelled else { return }
            guard let (_, user) = profile else { openProfile(); return }
            partner = user
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
            try await ActionGuard.shared.run("chat:create:\(partnerRef.id)") {
                // A single profile read already confirmed active on this opening.
                // The create-chat endpoint remains the authority for authorization.
                let conversation = try await UserService().createChat(partnerId: partnerRef.id)
                guard visible, !Task.isCancelled else { return }
                router.push(.chat(chatId: conversation.id))
            }
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
