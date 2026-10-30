import SwiftUI
import Combine

/// `Main` — the three-tab shell of the Android app: a top bar (logo, notifications
/// bell, avatar), the tab content, and a bottom bar
/// (`bottom_navigation_matches` / `_messages` / `_profile`).
struct MainView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @Environment(\.dynamicTypeSize) private var typeSize

    @EnvironmentObject private var poller: NotificationPoller
    private var unread: Int { poller.unread }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch router.selectedTab {
                case .matches: MatchesTab()
                case .messages: MessagesTab()
                case .profile: ProfileTab()
                }
            }
            .frame(maxHeight: .infinity)
            bottomBar
        }
        .background(Color.white)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            poller.start { slug, fallback in loc.t(slug, fallback) }
        }
    }

    private var topBar: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    brand.frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        topBarActions
                    }
                }
            } else {
                HStack(spacing: 10) {
                    brand
                    Spacer()
                    topBarActions
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.white)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            AppIcon(name: "logo", size: 40)
            Text("Carezaar").font(Theme.Typography.heading(20)).foregroundStyle(Theme.Palette.primaryDark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var topBarActions: some View {
        HStack(spacing: 10) {
            Button { router.push(.notifications) } label: {
                AppIcon(name: unread > 0 ? "ic_notification_on" : "ic_notification_off", size: 24,
                        tint: unread > 0 ? Color(hex: 0xFF0000) : .black)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(unread > 0 ? "\(loc.t("general_notifications", "Notifications")), \(unread)" : loc.t("general_notifications", "Notifications"))
            Button { router.selectedTab = .profile } label: {
                Avatar(url: session.state.user?.photo, size: 38)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(loc.t("general_profile", "Profile"))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(.matches, "bottom_navigation_matches", "Matches", "ic_matches")
            tabButton(.messages, "bottom_navigation_messages", "Messages", "ic_messages")
            tabButton(.profile, "bottom_navigation_profile", "Profile", "ic_profile")
        }
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.line).frame(height: 1) }
    }

    private func tabButton(_ tab: MainTab, _ slug: String, _ fallback: String, _ icon: String) -> some View {
        let on = router.selectedTab == tab
        return Button { router.selectedTab = tab } label: {
            VStack(spacing: 4) {
                AppIcon(name: "\(icon)_\(on ? "on" : "off")", size: 26, tint: on ? Theme.Palette.primaryDark : Theme.Palette.textSecondary)
                Text(loc.t(slug, fallback)).font(on ? Theme.Typography.control(14).bold() : Theme.Typography.body(14))
                    .foregroundStyle(on ? Theme.Palette.primaryDark : Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 10).padding(.bottom, 6)
            .overlay(alignment: .top) { Rectangle().fill(on ? Theme.Palette.primaryDark : .clear).frame(height: 3) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer {
            AppIcon(name: "\(icon)_\(on ? "on" : "off")", size: 26)
            Text(loc.t(slug, fallback))
        }
    }
}

// MARK: - Matches tab

/// My Matches state for the signed-in session (client request, 23 Oct 2026): the chosen sort is
/// remembered while the person stays signed in and forgotten when they sign out; the list they
/// had loaded (every page, and the card at the top) is kept while they open a profile, Messages
/// or another tab, and quietly refreshed when they come back. It lives outside the tab, which is
/// rebuilt on every tab switch. Keyed by the sign-in (`TokenStore.generation`, new at every
/// login and sign-out, kept by renewal), the account and the role.
@MainActor
final class MatchesStore: ObservableObject {
    static let shared = MatchesStore()

    @Published var sort: MatchSort = .distance
    private(set) var pager = Pager<MatchesTab.Card>()
    /// The sort the loaded pages were fetched in (nil until the first load of this sign-in).
    var loadedSort: MatchSort?
    /// The card at the top of the list when the person left it.
    var topCard: String?
    var headerImages: [String] = []
    #if DEBUG
    /// Outcome of the last quiet refresh, for the UI tests' readout.
    var lastRefresh = ""
    var appears = 0
    var trace = ""
    #endif
    private var key: String?
    private var forwarding: AnyCancellable?

    private init() { forward() }

    /// Called as the tab appears: another sign-in, account or role starts from the defaults.
    func prepare(for key: String) {
        guard self.key != key else { return }
        reset()
        self.key = key
    }

    /// Sign-out: forget the sort and the list.
    func forget() { reset(); key = nil }

    private func reset() {
        sort = .distance
        loadedSort = nil
        topCard = nil
        headerImages = []
        pager = Pager()
        forward()
        objectWillChange.send()
    }

    /// The screen observes the store; the pager's changes are passed on.
    private func forward() {
        forwarding = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// A client sees caregivers (`clients/matches`); a caregiver sees clients
/// (`caregivers/matches`). Hero art follows the user's care type (`header_*`).
struct MatchesTab: View {
    struct Card: Identifiable {
        let id: String
        var user: User
        let min: Int?
        let max: Int?
        let distance: Double?
        let clienttypeId: Int?
        let isMatch: Bool
    }

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @ObservedObject private var store = MatchesStore.shared
    private var pager: Pager<Card> { store.pager }
    private var sort: MatchSort { store.sort }
    @StateObject private var favorites = FavoriteMutationCoordinator.shared
    /// The card at the top, restored when the tab is rebuilt (a tab switch).
    @State private var topCard: String? = MatchesStore.shared.topCard
    /// Until the list is back in place the scroll view's own reports are not the person's place.
    @State private var restoring = true
    @State private var choosingSort = false
    @State private var headerImage = "bg_matches"
    @State private var headerImages: [String] = []
    @State private var headerIndex = 0
    @State private var headerVisible = false
    @Environment(\.scenePhase) private var headerScenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isClient: Bool { session.role != .caregiver }
    private var prefix: String { isClient ? "client" : "caregiver" }

    private var sessionKey: String {
        "\(TokenStore.shared.generation)|\(session.state.user?.id ?? "")|\(session.role?.rawValue ?? "")"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeroHeader(image: headerImage, icon: "ic_matches_off",
                           title: loc.t("\(prefix)_matches_page_title", "My Matches"),
                           subtitle: loc.t("\(prefix)_matches_page_description", ""))
                    .accessibilityIdentifier("matches-hero")
                banner
                AdaptiveStack(alignment: .center, spacing: 8) {
                    Text("\(loc.t("\(prefix)_matches_all_matches", "All Matches")) \(pager.total.map { "(\($0))" } ?? "")")
                        .font(Theme.Typography.title(17))
                    Spacer(minLength: 0)
                    Button { choosingSort = true } label: {
                        HStack(spacing: 6) {
                            AppIcon(name: "ic_sort", size: 20, tint: Theme.Palette.textSecondary)
                            Text("\(loc.t("\(prefix)_matches_sort", "Sort")) (\(loc.t("\(prefix)_matches_sort_\(sort.rawValue)", sort.title)))")
                                .font(Theme.Typography.body(15)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 10)
                PagedContent(pager: pager, emptyTitle: "\(loc.t("\(prefix)_matches_all_matches", "All Matches")) (0)",
                             emptyIllustration: "illus_chat",
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } },
                             scrollTargets: true) { card in
                    cardView(card).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
        }
        .scrollPosition(id: $topCard, anchor: .top)
        .onChange(of: topCard) { _, card in if headerVisible, !restoring, let card { store.topCard = card } }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-request-counts") {
                Text("·").frame(width: 1, height: 1).clipped()
                    .accessibilityLabel(headerImages.joined(separator: ",") + ";current=" + headerImage)
                    .accessibilityIdentifier("qa-matches-header")
                    .allowsHitTesting(false)
                // The list's own state in one element (UI tests read this instead of every card).
                Text("·").frame(width: 1, height: 1).clipped()
                    .accessibilityLabel("sort=\(sort.rawValue);pages=\(pager.page);items=\(pager.items.count);top=\(topCard ?? "");topName=\(pager.items.first { $0.id == topCard }?.user.displayName(loc) ?? "");firstName=\(pager.items.first?.user.displayName(loc) ?? "");revalidating=\(pager.isRevalidating);loading=\(pager.isLoading);lastRefresh=\(store.lastRefresh);appears=\(store.appears);trace=\(store.trace)")
                    .accessibilityIdentifier("qa-matches-state")
                    .allowsHitTesting(false)
            }
        }
        #endif
        .refreshable { await reload(quiet: true) }
        .task(id: sort) { await appear() }
        .onReceive(NotificationCenter.default.publisher(for: FavoriteSync.changed)) { note in
            guard let change = FavoriteSync.decode(note) else { return }
            for i in pager.items.indices where pager.items[i].user.id == change.id {
                pager.items[i].user = pager.items[i].user.with(isFavorite: change.on)
            }
        }
        .onAppear {
            store.prepare(for: sessionKey)
            if !store.headerImages.isEmpty, headerImages.isEmpty { headerImages = store.headerImages; headerImage = store.headerImages[0] }
            headerVisible = true
        }
        .onDisappear { headerVisible = false }
        .task { await loadHeader() }
        // A new task exists only while this screen and scene are active. SwiftUI
        // cancels the old sleep on disappearance/background instead of leaving a timer alive.
        .task(id: headerRotationKey) {
            guard !headerRotationKey.isEmpty, headerImages.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled, headerVisible, headerScenePhase == .active,
                      headerImages.count > 1 else { return }
                headerIndex = (headerIndex + 1) % headerImages.count
                headerImage = headerImages[headerIndex]
            }
        }

        .confirmationDialog(loc.t("\(prefix)_matches_sort", "Sort"), isPresented: $choosingSort, titleVisibility: .visible) {
            ForEach(MatchSort.allCases, id: \.self) { s in
                Button((s == sort ? "✓ " : "") + loc.t("\(prefix)_matches_sort_\(s.rawValue)", s.title)) { store.sort = s }
            }
        }
    }

    private var headerRotationKey: String {
        guard headerVisible, headerScenePhase == .active, headerImages.count > 1 else { return "" }
        return headerImages.joined(separator: "|")
    }

    private var banner: some View {
        AdaptiveStack(alignment: .center, spacing: 12) {
            AppIcon(name: "ic_tune", size: 30, tint: Theme.Palette.primary)
                .frame(width: 56, height: 56).background(Color(hex: 0xD6E6F8), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("\(prefix)_matches_preferences_title", "Looking for something different?")).font(Theme.Typography.title(15))
                Text(loc.t("\(prefix)_matches_preferences_description", "")).font(Theme.Typography.caption(12)).foregroundStyle(Color(hex: 0x333333))
            }
            Spacer(minLength: 4)
            Button { router.push(isClient ? .clientPreferences : .caregiverSkills) } label: {
                Text(loc.t("\(prefix)_matches_preferences_button", "Edit preferences"))
                    // Long translations wrap instead of squeezing the text beside it.
                    .font(Theme.Typography.filledLabel(14)).foregroundStyle(.white)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center).frame(maxWidth: 140)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.Palette.primaryFill, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Theme.Palette.clientPanel)
        .clipShape(UnevenRoundedRectangle(topTrailingRadius: 36))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xD6E5F7)).frame(height: 1) }
        .padding(.top, -12)
    }

    private func cardView(_ c: Card) -> some View {
        Button { router.push(isClient ? .caregiverDetails(caregiverId: c.id) : .clientDetails(clientId: c.id)) } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    // Photo and heart on top, the details full width below.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) { PhotoBox(url: c.user.photo); Spacer(); if c.isMatch { matchedIcon }; favoriteButton(c) }
                        cardDetails(c)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        PhotoBox(url: c.user.photo)
                        cardDetails(c).padding(.top, 4)
                        VStack {
                            favoriteButton(c)
                            if c.isMatch { matchedIcon }
                            Spacer()
                            AppIcon(name: "ic_chevron_forward", size: 20, tint: Theme.Palette.textSecondary)
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                }
            }
            .card(padding: 10)
        }
        .buttonStyle(.plain)
    }

    private var matchedIcon: some View {
        AppIcon(name: "ic_match_on", size: 26, tint: Theme.Palette.success)
            .accessibilityLabel(loc.t("match_tab_matches", "Matched"))
            .accessibilityIdentifier("active-match-icon")
    }

    private func favoriteButton(_ c: Card) -> some View {
        Button { Task { await toggleFavorite(c) } } label: {
            AppIcon(name: c.user.isFavorite ? "ic_favorite_on" : "ic_favorite_off", size: 26,
                    tint: c.user.isFavorite ? Theme.Palette.danger : Theme.Palette.primaryDark)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.user.isFavorite ? "Remove from favorites" : "Add to favorites")
    }

    private func cardDetails(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                Text(c.user.displayName(loc)).font(Theme.Typography.title(17)).foregroundStyle(.black)
                if !isClient, let min = c.min {
                    Text("$\(min) - $\(c.max ?? min)").font(Theme.Typography.control(13)).foregroundStyle(Theme.Palette.primaryDark)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.user.displayName(loc)).font(Theme.Typography.title(17)).foregroundStyle(.black).lineLimit(2)
                    Spacer(minLength: 4)
                    if !isClient, let min = c.min {
                        Text("$\(min) - $\(c.max ?? min)").font(Theme.Typography.control(13)).foregroundStyle(Theme.Palette.primaryDark).fixedSize()
                    }
                }
            }
            meta("ic_distance", bold: formatDistance(c.distance), rest: loc.t("general_miles_away", "mile(s) away"))
            if isClient {
                meta("ic_usd_circle", bold: "\(c.min.map(String.init) ?? "—") - \(c.max.map(String.init) ?? "—")",
                     rest: loc.t("client_details_usd_per_hour", "USD per hour"))
            } else {
                let type = baseData.items(.clienttypes).first { $0.id == c.clienttypeId }
                HStack(spacing: 6) {
                    AppIcon(name: type?.icon, size: 26)
                    Text(loc.label(type)).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private func meta(_ icon: String, bold: String, rest: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            AppIcon(name: icon, size: 20, tint: Theme.Palette.primary).fixedSize()
            Text("\(Text(bold).font(Theme.Typography.title(18)).foregroundStyle(Color(hex: 0x5A6069))) \(Text(rest).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary))")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private var fetch: Pager<Card>.Fetch {
        let sort = sort, isClient = isClient
        return { page in
            if isClient {
                let (list, meta) = try await ClientService().matches(sort: sort, page: page)
                return (list.map { Card(id: $0.id, user: $0.user, min: $0.salaryMin, max: $0.salaryMax, distance: $0.distance, clienttypeId: nil, isMatch: $0.isMatch) }, meta)
            } else {
                let (list, meta) = try await CaregiverService().matches(sort: sort, page: page)
                return (list.map { Card(id: $0.id, user: $0.user, min: $0.salaryMin, max: $0.salaryMax, distance: $0.distance, clienttypeId: $0.clienttypeId, isMatch: $0.isMatch) }, meta)
            }
        }
    }

    /// First visit of this sign-in, or a new sort: page 1 with the loading window, as before.
    /// Back on the tab (from a profile, Messages or Profile) in the same sort: the list stays as
    /// it was and every loaded page is refreshed quietly; no loading window, no jump to page 1.
    private func appear() async {
        #if DEBUG
        store.appears += 1
        store.trace += "a\(store.appears):\(topCard?.suffix(4) ?? "-")/\(store.topCard?.suffix(4) ?? "-") "
        #endif
        store.prepare(for: sessionKey)
        restoring = true
        Task { try? await Task.sleep(for: .milliseconds(800)); restoring = false }
        if store.loadedSort == sort, pager.loadedOnce {
            // A page that started loading as the list came back (its end in view) finishes first;
            // the refresh then covers it too.
            while pager.isLoading, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            let refreshed = await pager.refreshLoaded(fetch)
            #if DEBUG
            store.lastRefresh = refreshed ? "refreshed" : "kept"
            #endif
        } else {
            topCard = nil
            store.topCard = nil
            await reload()
            if pager.loadedOnce { store.loadedSort = sort }
            #if DEBUG
            // `--qa-matches-pages <n>`: load n pages and put a card of the last one at the top, as a
            // person scrolling would; UI tests then leave and return (long swipes through a big
            // list make XCTest's snapshots of the screen too slow to use).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--qa-matches-pages"), i + 1 < args.count, let n = Int(args[i + 1]), n > 1 {
                for _ in 1..<n { await pager.loadMore(fetch) }
                try? await Task.sleep(for: .seconds(1))
                let index = min(pager.items.count - 1, (n - 1) * 10 + 5)
                if index > 0 { topCard = pager.items[index].id; store.topCard = topCard }
            }
            #endif
        }
    }

    /// Page 1 again. The first load shows skeleton cards (PagedContent); pull-to-refresh keeps
    /// the current matches when it fails, but says so: offline the user otherwise saw an
    /// unchanged list and no sign the refresh did not happen.
    private func reload(quiet: Bool = false) async {
        if quiet { await pager.refresh(fetch) } else { await pager.reload(fetch) }
        if quiet, let error = pager.error, !pager.items.isEmpty { feedback.toast(Feedback.message(error)) }
    }

    private func loadHeader() async {
        let ids: [Int]
        if isClient { ids = (try? await ClientService().profile().clienttypeId).map { [$0] } ?? [] }
        else { ids = (try? await CaregiverService().profile().clienttypeIds) ?? [] }
        headerImages = ids.compactMap { id in
            baseData.items(.clienttypes).first(where: { $0.id == id })?.icon?
                .replacingOccurrences(of: "client_", with: "header_")
        }
        headerIndex = 0
        headerImage = headerImages.first ?? "bg_matches"
        store.headerImages = headerImages
    }

    private func toggleFavorite(_ card: Card) async {
        guard !favorites.isBusy(partner: card.user, accountId: session.state.user?.id),
              let index = pager.items.firstIndex(where: { $0.id == card.id }) else { return }
        let accountId = session.state.user?.id
        let generation = TokenStore.shared.generation
        let on = card.user.isFavorite
        pager.items[index].user = card.user.with(isFavorite: !on)
        do {
            // FavoriteMutationCoordinator is the shared guard for one person's favourite.
            let saved = try await favorites.change(partner: card.user, to: !on, profileId: card.id, accountId: accountId, generation: generation)
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            if let i = pager.items.firstIndex(where: { $0.id == card.id }) { pager.items[i].user = saved }
            FavoriteSync.post(userId: card.user.id, isFavorite: saved.isFavorite)
        } catch is CancellationError { return }
        catch let failure as FavoriteReconciliationError {
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            if let i = pager.items.firstIndex(where: { $0.id == card.id }) { pager.items[i].user = failure.saved }
            FavoriteSync.post(userId: card.user.id, isFavorite: failure.saved.isFavorite)
            feedback.toast(Feedback.message(failure.underlying))
        } catch {
            guard session.state.user?.id == accountId, TokenStore.shared.generation == generation else { return }
            if let i = pager.items.firstIndex(where: { $0.id == card.id }) { pager.items[i].user = card.user }
            feedback.toast(Feedback.message(error))
        }
    }
}

/// Android prints the API double as-is (Kotlin `toString`): "0.0", "537.86".
func formatDistance(_ d: Double?) -> String {
    guard let d else { return "—" }
    return String(d)
}

extension User {
    func with(isFavorite: Bool) -> User {
        User(id: id, countryId: countryId, genderId: genderId, role: role, email: email, firstName: firstName,
             lastName: lastName, photo: photo, bio: bio, dateOfBirth: dateOfBirth, status: status, isFavorite: isFavorite,
             isDeleted: isDeleted)
    }
}

// MARK: - Messages tab

struct MessagesTab: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @StateObject private var pager = Pager<ChatBrief>()
    @State private var visible = false

    /// K1: Android refreshes the conversation list every 10 seconds while it is open.
    static let refreshInterval: Duration = .seconds(10)
    /// One timer at most: the task restarts (and the old one is cancelled) whenever
    /// visibility or the scene phase changes, and it does not run while hidden.
    private var refreshing: Bool { visible && scenePhase == .active }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // The client's Messages picture (17 Oct, parity review v3.0 M1).
                HeroHeader(image: "header_messages", icon: "ic_messages_off",
                           title: loc.t("messages_title", "Messages"),
                           subtitle: loc.t("messages_description", "All your conversations in one place"))
                PagedContent(pager: pager, emptyTitle: loc.t("chat_screen_no_messages_yet", "No Messages Yet"),
                             emptyMessage: loc.t("chat_screen_empty_description", "Your chats about jobs will appear here."),
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }, skeleton: .row) { chat in
                    row(chat)
                }
            }
        }
        .refreshable { await pager.refresh(fetch) }
        .task { await reload() }
        // Back from a chat, or back in the app: previews and unread dots may have changed.
        .onChange(of: router.path.isEmpty) { _, atRoot in if atRoot { Task { await pager.reload(fetch) } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await pager.reload(fetch) } } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: refreshing) {
            guard refreshing else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
                guard !Task.isCancelled, visible, scenePhase == .active else { return }
                await pager.refreshQuietly(fetch)
            }
        }
    }

    private func row(_ chat: ChatBrief) -> some View {
        let partner = chat.partner(for: session.role ?? .client)
        let unread = chat.newMessageCount > 0
        return Button { router.push(.chat(chatId: chat.id)) } label: {
            HStack(spacing: 14) {
                Avatar(url: partner?.photo, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    AdaptiveStack(alignment: .center, spacing: 8, stackedSpacing: 2) {
                        Text(partner?.displayName(loc) ?? "").font(Theme.Typography.title(16)).foregroundStyle(.black).lineLimit(2)
                        Spacer(minLength: 0)
                        Text(ServerTime.local(chat.updatedAt)).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(chat.lastMessage ?? "").font(Theme.Typography.body(14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        // The visual preview deliberately ends in an ellipsis. The
                        // conversation button exposes the full message value.
                        .accessibilityHidden(true)
                }
                if unread { Circle().fill(Theme.Palette.primary).frame(width: 10, height: 10).accessibilityLabel("Unread") }
                AppIcon(name: "ic_chevron_forward", size: 22, tint: Theme.Palette.textSecondary).flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xEEF1F5)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(partner?.displayName(loc) ?? loc.t("chat_screen_messages_title", "Chat Messages"))
        .accessibilityValue([chat.lastMessage ?? "", ServerTime.local(chat.updatedAt),
                             unread ? loc.t("messages_unread", "Unread") : ""]
            .filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint(loc.t("messages_open_conversation", "Open conversation"))
    }

    private let fetch: Pager<ChatBrief>.Fetch = { page in try await UserService().chats(page: page) }

    /// Page 1; the first load shows skeleton rows (PagedContent).
    private func reload() async {
        await pager.reload(fetch)
    }
}

// MARK: - Profile tab

struct ProfileTab: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @State private var confirmingLogout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroHeader(image: "bg_profile", icon: "ic_profile_off",
                           title: loc.t("profile_title", "Profile"),
                           subtitle: loc.t("profile_description", "Manage your personal information and account settings."))
                if let user = session.state.user { profileCard(user).padding(.horizontal, 20) }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        item
                        if index < items.count - 1 { Divider().padding(.leading, 78) }
                    }
                }
                .card(padding: 0)
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .task { await session.refreshUser() }
        .alert(loc.t("navigation_drawer_log_out_dialog_title", "Are you sure?"), isPresented: $confirmingLogout) {
            Button(loc.t("navigation_drawer_log_out_dialog_deny", "Cancel"), role: .cancel) {}
            Button(loc.t("navigation_drawer_log_out_dialog_confirm", "Confirm"), role: .destructive) {
                Task { try? await ActionGuard.shared.run("auth:logout") { await session.signOut() } }
            }
        } message: {
            Text(loc.t("navigation_drawer_log_out_dialog_message", "You have selected to sign out from your account."))
        }
    }

    private func profileCard(_ user: User) -> some View {
        let gender = baseData.items(.genders).first { $0.id == user.genderId }
        // No verification badge: Background Check was removed at the client's request.
        return AdaptiveStack(spacing: 14) {
            Avatar(url: user.photo, size: 92)
            VStack(alignment: .leading, spacing: 6) {
                Text(user.fullName).font(Theme.Typography.title(19))
                if let gender { infoLine(gender.icon, loc.label(gender)) }
                infoLine("ic_email", user.email, semanticLabel: loc.t("profile_edit_email", "Email Address"))
                if let dob = user.dateOfBirth, !dob.isEmpty { infoLine("ic_calendar", dob) }
            }
            Spacer(minLength: 0)
            Button { router.push(.profileEdit) } label: {
                AppIcon(name: "ic_edit", size: 22, tint: Theme.Palette.primaryDark)
                    .frame(width: 44, height: 44).background(Theme.Palette.clientPanel, in: Circle())
            }
            .accessibilityLabel(loc.t("profile_edit", "Edit"))
        }
        .card(padding: 16)
    }

    private func infoLine(_ icon: String?, _ text: String, semanticLabel: String? = nil) -> some View {
        HStack(spacing: 6) {
            AppIcon(name: icon, size: 18, tint: Theme.Palette.textSecondary)
            // Wraps rather than cutting off a long email address.
            Text(text).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(semanticLabel ?? text)
        .accessibilityValue(semanticLabel == nil ? "" : text)
    }

    private var items: [MenuRow] {
        let isClient = session.role != .caregiver
        return [
            MenuRow(icon: "ic_match_on", title: loc.t("profile_matches_title", "Matches"),
                    description: loc.t("profile_matches_description", "Review your match history"), tint: Theme.Palette.success,
                    // The icon keeps the brand green; text uses the darker green (5.3:1).
                    titleColor: Color(hex: 0x047A5A)) { router.push(.manageMatches) },
            MenuRow(icon: "ic_support", title: loc.t("profile_help_center_title", "Help Center"),
                    description: loc.t("profile_help_center_description", "Get help and support")) { router.push(.helpCenter) },
            MenuRow(icon: "ic_issue", title: loc.t("profile_report_an_issue_title", "Report an Issue"),
                    description: loc.t("profile_report_an_issue_description", "")) { router.push(.reportAnIssue) },
            MenuRow(icon: "ic_faq", title: loc.t("profile_faq_title", "FAQ"),
                    description: loc.t("profile_faq_description", "Find answers to common questions")) { router.push(.faq) },
            MenuRow(icon: "ic_language", title: loc.t("profile_change_language_title", "Change Language"),
                    description: loc.t("profile_change_language_description", "Choose your preferred language")) { router.push(.changeLanguage) },
            MenuRow(icon: "ic_favorite_off", title: loc.t("profile_favorites_title", "Favorites"),
                    description: isClient ? loc.t("profile_favorites_client_description", "View your saved caregivers")
                                          : loc.t("profile_favorites_caregiver_description", "View your saved clients")) { router.push(.favorites) },
            MenuRow(icon: "ic_lock", title: loc.t("navigation_drawer_password_title", "Change Password"),
                    description: loc.t("profile_password_change_description", "Change your current password")) { router.push(.changePassword) },
            MenuRow(icon: "ic_logout", title: loc.t("profile_log_out_title", "Log Out"),
                    description: loc.t("profile_log_out_description", "Sign out from your account"),
                    tint: Theme.Palette.danger, titleColor: Theme.Palette.danger) { confirmingLogout = true },
        ]
    }
}
