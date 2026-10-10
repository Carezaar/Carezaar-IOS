import SwiftUI

/// `Favorites` — bookmarked partners; the heart removes one.
struct FavoritesView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @StateObject private var pager = Pager<User>()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AppIcon(name: "ic_favorite_on", size: 44, tint: Theme.Palette.primaryDark)
                    .frame(width: 88, height: 88).background(Theme.Palette.clientPanel, in: Circle())
                    .padding(.vertical, 16)
                PagedContent(pager: pager, emptyTitle: loc.t("profile_favorites_title", "Favorites"),
                             retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }) { u in
                    row(u).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
        }
        .refreshable { await pager.reload(fetch) }
        .backHeader(loc.t("profile_favorites_title", "Favorites"))
        .task { await reload() }
        // Un-bookmarked from the partner's profile: drop the row; bookmarked again: reload.
        .onReceive(NotificationCenter.default.publisher(for: FavoriteSync.changed)) { note in
            guard let change = FavoriteSync.decode(note) else { return }
            if change.on { Task { await pager.reload(fetch) } } else { pager.items.removeAll { $0.id == change.id } }
        }
    }

    private func row(_ u: User) -> some View {
        Button { router.push(u.role == .caregiver ? .caregiverDetails(caregiverId: u.id) : .clientDetails(clientId: u.id)) } label: {
            AdaptiveStack(spacing: 12) {
                Avatar(url: u.photo, size: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(u.fullName).font(Theme.Typography.title(17)).foregroundStyle(.black)
                    Text(u.bio ?? "").font(Theme.Typography.body(13)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                VStack {
                    Button { Task { await remove(u) } } label: {
                        AppIcon(name: "ic_favorite_on", size: 28, tint: Theme.Palette.danger).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from favorites")
                    Spacer()
                    AppIcon(name: "ic_chevron_forward", size: 20, tint: Theme.Palette.textSecondary).flipsForRightToLeftLayoutDirection(true)
                }
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }

    private let fetch: Pager<User>.Fetch = { page in try await UserService().bookmarks(page: page) }

    private func reload() async {
        try? await feedback.run("\(loc.t("loading_favorite_get", "Getting favorites - Page")) 1") { await pager.reload(fetch) }
    }

    private func remove(_ u: User) async {
        do {
            try await feedback.run(loc.t("loading_favorite_delete", "Removing from favorite list")) {
                try await UserService().removeBookmark(partnerId: u.id)
            }
            pager.items.removeAll { $0.id == u.id }
        } catch { feedback.toast(Feedback.message(error)) }
    }
}
