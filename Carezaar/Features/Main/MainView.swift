import SwiftUI

/// `Main` — the three-tab shell of the Android app: a top bar (logo, notifications
/// bell with badge, avatar), the tab content, and a bottom bar
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
                AppIcon(name: unread > 0 ? "ic_notification_on" : "ic_notification_off", size: 26, tint: .black)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Theme.Palette.danger, in: Capsule())
                        }
                    }
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

    @StateObject private var pager = Pager<Card>()
    @State private var sort: MatchSort = .distance
    @State private var choosingSort = false
    @State private var headerImage = "bg_matches"
    @State private var headerImages: [String] = []
    @State private var headerIndex = 0
    @State private var headerVisible = false
    @Environment(\.scenePhase) private var headerScenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isClient: Bool { session.role != .caregiver }
    private var prefix: String { isClient ? "client" : "caregiver" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeroHeader(image: headerImage, icon: "ic_matches_off",
                           title: loc.t("\(prefix)_matches_page_title", "My Matches"),
                           subtitle: loc.t("\(prefix)_matches_page_description", ""))
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
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }) { card in
                    cardView(card).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
        }
        .refreshable { await reload(quiet: true) }
        .task(id: sort) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: FavoriteSync.changed)) { note in
            guard let change = FavoriteSync.decode(note) else { return }
            for i in pager.items.indices where pager.items[i].user.id == change.id {
                pager.items[i].user = pager.items[i].user.with(isFavorite: change.on)
            }
        }
        .onAppear { headerVisible = true }
        .onDisappear { headerVisible = false }
        .task {
            await loadHeader()
            guard headerImages.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                guard !Task.isCancelled, headerImages.count > 1 else { return }
                guard headerVisible, headerScenePhase == .active else { continue }
                headerIndex = (headerIndex + 1) % headerImages.count
                headerImage = headerImages[headerIndex]
            }
        }
        .confirmationDialog(loc.t("\(prefix)_matches_sort", "Sort"), isPresented: $choosingSort, titleVisibility: .visible) {
            ForEach(MatchSort.allCases, id: \.self) { s in
                Button((s == sort ? "✓ " : "") + loc.t("\(prefix)_matches_sort_\(s.rawValue)", s.title)) { sort = s }
            }
        }
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
                    .background(Theme.Palette.primary, in: RoundedRectangle(cornerRadius: 10))
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
                Text(c.user.fullName).font(Theme.Typography.title(17)).foregroundStyle(.black)
                if !isClient, let min = c.min {
                    Text("$\(min) - $\(c.max ?? min)").font(Theme.Typography.control(13)).foregroundStyle(Theme.Palette.primaryDark)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.user.fullName).font(Theme.Typography.title(17)).foregroundStyle(.black).lineLimit(2)
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
        HStack(spacing: 6) {
            AppIcon(name: icon, size: 20, tint: Theme.Palette.primary)
            Text(bold).font(Theme.Typography.title(18)).foregroundStyle(Color(hex: 0x5A6069))
            Text(rest).font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
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

    private func reload(quiet: Bool = false) async {
        let label = "\(loc.t("loading_matches", "Getting list of matches - Page")) 1"
        if quiet { await pager.reload(fetch) }
        else { try? await feedback.run(label) { await pager.reload(fetch) } }
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
    }

    private func toggleFavorite(_ card: Card) async {
        guard let index = pager.items.firstIndex(where: { $0.id == card.id }) else { return }
        let on = card.user.isFavorite
        pager.items[index].user = card.user.with(isFavorite: !on)
        do {
            try await feedback.run(on ? loc.t("loading_favorite_delete", "Removing from favorite list")
                                      : loc.t("loading_favorite_create", "Adding to favorite list")) {
                if on { try await UserService().removeBookmark(partnerId: card.user.id) }
                else { try await UserService().addBookmark(partnerId: card.user.id) }
            }
        } catch {
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
             lastName: lastName, photo: photo, bio: bio, dateOfBirth: dateOfBirth, status: status, isFavorite: isFavorite)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeroHeader(image: "bg_messages", icon: "ic_messages_off",
                           title: loc.t("messages_title", "Messages"),
                           subtitle: loc.t("messages_description", "All your conversations in one place"))
                PagedContent(pager: pager, emptyTitle: loc.t("chat_screen_no_messages_yet", "No Messages Yet"),
                             emptyMessage: loc.t("chat_screen_empty_description", "Your chats about jobs will appear here."),
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }) { chat in
                    row(chat)
                }
            }
        }
        .refreshable { await pager.reload(fetch) }
        .task { await reload() }
        // Back from a chat, or back in the app: previews and unread dots may have changed.
        .onChange(of: router.path.isEmpty) { _, atRoot in if atRoot { Task { await pager.reload(fetch) } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await pager.reload(fetch) } } }
    }

    private func row(_ chat: ChatBrief) -> some View {
        let partner = chat.partner(for: session.role ?? .client)
        let unread = chat.newMessageCount > 0
        return Button { router.push(.chat(chatId: chat.id)) } label: {
            HStack(spacing: 14) {
                Avatar(url: partner?.photo, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    AdaptiveStack(alignment: .center, spacing: 8, stackedSpacing: 2) {
                        Text(partner?.fullName ?? "").font(Theme.Typography.title(16)).foregroundStyle(.black).lineLimit(2)
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
        .accessibilityLabel(partner?.fullName ?? loc.t("chat_screen_messages_title", "Chat Messages"))
        .accessibilityValue([chat.lastMessage ?? "", ServerTime.local(chat.updatedAt),
                             unread ? loc.t("messages_unread", "Unread") : ""]
            .filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint(loc.t("messages_open_conversation", "Open conversation"))
    }

    private let fetch: Pager<ChatBrief>.Fetch = { page in try await UserService().chats(page: page) }

    private func reload() async {
        try? await feedback.run("\(loc.t("loading_chat_get_all", "Getting list of chats - Page")) 1") { await pager.reload(fetch) }
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
                Task { try? await feedback.run(loc.t("loading_auth_logout", "Signing out")) { await session.signOut() } }
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
                    description: loc.t("navigation_drawer_password_description", "Update your account password")) { router.push(.changePassword) },
            MenuRow(icon: "ic_logout", title: loc.t("profile_log_out_title", "Log Out"),
                    description: loc.t("profile_log_out_description", "Sign out from your account"),
                    tint: Theme.Palette.danger, titleColor: Theme.Palette.danger) { confirmingLogout = true },
        ]
    }
}
