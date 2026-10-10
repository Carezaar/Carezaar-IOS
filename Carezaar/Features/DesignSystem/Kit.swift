import SwiftUI

extension Theme.Palette {
    static let primaryDark = Color(hex: 0x1B4F8F)
    static let primarySoft = Color(hex: 0xE7F1FF)
    static let warning = Color(hex: 0xE39B0B)
    static let danger = Color(hex: 0xD6202D)
    static let dangerSoft = Color(hex: 0xFDECEC)
    static let line = Color(hex: 0xE3E7EE)
}

// MARK: - Paging

/// Page-by-page loader shared by every list (perPage 10, like Android). `loadMore`
/// is guarded so a fast scroll can't request the same page twice.
@MainActor
final class Pager<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    typealias Fetch = (Int) async throws -> ([Item], APIMeta?)

    @Published var items: [Item] = []
    @Published private(set) var total: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var loadedOnce = false
    private var page = 0
    private var lastPage: Int?

    var hasMore: Bool { lastPage.map { page < $0 } ?? true }

    /// Each reload starts a new generation; results from an older, superseded load
    /// (e.g. one whose view disappeared mid-flight) are discarded instead of
    /// blocking the new one.
    private var generation = 0

    func reload(_ fetch: Fetch) async {
        generation += 1
        page = 0; lastPage = nil; error = nil
        await next(fetch, replacing: true, generation: generation)
    }

    func loadMore(_ fetch: Fetch) async {
        guard hasMore, !isLoading, error == nil else { return }
        await next(fetch, replacing: false, generation: generation)
    }

    private func next(_ fetch: Fetch, replacing: Bool, generation g: Int) async {
        isLoading = true
        defer { if g == generation { isLoading = false } }
        do {
            let (result, meta) = try await fetch(page + 1)
            guard g == generation else { return }
            loadedOnce = true
            page += 1
            lastPage = meta?.lastPage ?? (result.count < APIConfiguration.defaultPageSize ? page : nil)
            total = meta?.total ?? total
            // The server's order isn't stable for equal sort keys (BE-16), so a later
            // page can repeat someone; duplicate ids would also break `ForEach`.
            var seen = Set(replacing ? [] : items.map(\.id))
            let fresh = result.filter { seen.insert($0.id).inserted }
            items = replacing ? fresh : items + fresh
        } catch is CancellationError {
        } catch {
            guard g == generation else { return }
            loadedOnce = true
            if replacing { items = [] }
            self.error = error
        }
    }
}

/// Loading / error / empty wrapper used by every paged list.
struct PagedContent<Item: Identifiable, Row: View>: View {
    @ObservedObject var pager: Pager<Item>
    let emptyTitle: String
    var emptyMessage: String?
    var emptyIllustration: String?
    /// A monochrome APK icon, tinted, for lists whose empty state has no artwork.
    var emptyIcon: String?
    let retry: () -> Void
    let more: () -> Void
    @ViewBuilder let row: (Item) -> Row
    @EnvironmentObject private var loc: Localization

    var body: some View {
        if let error = pager.error, pager.items.isEmpty {
            ErrorState(message: Feedback.message(error)) { retry() }
                .padding(.top, 40)
        } else if pager.loadedOnce && !pager.isLoading && pager.items.isEmpty {
            VStack(spacing: 12) {
                if let emptyIllustration { EmptyArt(name: emptyIllustration) }
                if let emptyIcon {
                    AppIcon(name: emptyIcon, size: 48, tint: Theme.Palette.primary)
                        .frame(width: 96, height: 96).background(Theme.Palette.clientPanel, in: Circle())
                }
                Text(emptyTitle).font(Theme.Typography.title(18))
                if let emptyMessage, !emptyMessage.isEmpty {
                    Text(emptyMessage).font(Theme.Typography.body()).foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40).frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(pager.items) { item in
                    row(item).onAppear { if item.id == pager.items.last?.id { more() } }
                }
                if pager.isLoading && !pager.items.isEmpty { ProgressView().padding() }
            }
        }
    }
}

// MARK: - Headers

/// Secondary screens: native back button, centred title, logo mark on the right.
struct BackHeader: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AppIcon(name: "logo", size: 34).environment(\.layoutDirection, .leftToRight)
                }
            }
            .toolbarBackground(.white, for: .navigationBar)
    }
}

extension View {
    func backHeader(_ title: String) -> some View { modifier(BackHeader(title: title)) }

    /// White card with the soft shadow used across Android's lists.
    func card(radius: CGFloat = Theme.Radius.card, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color(red: 16/255, green: 40/255, blue: 80/255).opacity(0.10), radius: 5, y: 2)
    }
}

/// Photo header of Matches, Messages and Profile.
/// Side by side at ordinary text sizes; stacked at the accessibility sizes, where two
/// columns on a phone leave each too narrow and words break mid-word.
struct AdaptiveStack<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 12
    var stackedSpacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: stackedSpacing ?? spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout(content)
    }
}

struct HeroHeader: View {
    let image: String
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                if let ui = AppImage.load(image) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    Theme.Palette.clientPanel
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    // Long translations ("Mes correspondances") wrap rather than truncate;
                    // the icon keeps its own width beside the wrapped title.
                    Text(title).font(Theme.Typography.heading(28)).lineLimit(2).minimumScaleFactor(0.7)
                    AppIcon(name: icon, size: 28, tint: Theme.Palette.primaryDark)
                        .fixedSize().layoutPriority(1)
                }
                if !subtitle.isEmpty { Text(subtitle).font(Theme.Typography.body(14)).lineLimit(3).minimumScaleFactor(0.85) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 20)
        }
        .frame(height: 196)
        // Text over a fixed-height picture card: capped, as the system caps its bars.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 36))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Partner photo, or the placeholder art when there is none.
struct PhotoBox: View {
    let url: String?
    var width: CGFloat = 92
    var height: CGFloat = 116
    var radius: CGFloat = 12

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            // Android shows the brand mark when a partner has no photo.
            else { ZStack { Theme.Palette.clientPanel; AppIcon(name: "logo", size: min(width, height) * 0.62) } }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Icon + title + description row with a chevron, as in Android's Profile menu.
struct MenuRow: View {
    let icon: String
    let title: String
    let description: String
    var tint: Color = .black
    var titleColor: Color = .black
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AppIcon(name: icon, size: 28, tint: tint)
                    .frame(width: 48, height: 48)
                    .background(Theme.Palette.clientPanel, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Typography.title(16)).foregroundStyle(titleColor)
                    if !description.isEmpty {
                        Text(description).font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                AppIcon(name: "ic_chevron_forward", size: 18, tint: Theme.Palette.textSecondary)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small capsule action used on match rows (Accept / Reject / Unmatch / Review).
struct MiniButton: View {
    let title: String
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(danger ? Theme.Typography.control(13) : Theme.Typography.filledLabel(14)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(danger ? Theme.Palette.danger : .white)
                .background(danger ? Theme.Palette.dangerSoft : Theme.Palette.primary, in: Capsule())
                .overlay(Capsule().stroke(danger ? Theme.Palette.danger : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// A full-width button variant matching the web kit's outline/danger styles.
struct WideButton: View {
    enum Style { case primary, outline, danger }
    let title: String
    var icon: String?
    var style: Style = .primary
    var enabled = true
    /// Forward arrows ("Keep Exploring →") follow the label, as on Android.
    var iconTrailing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon, !iconTrailing { AppIcon(name: icon, size: 20, tint: foreground) }
                // Long translations ("Demander une mise en relation") wrap to a second line.
                Text(title).font(style == .primary ? Theme.Typography.filledLabel(16) : Theme.Typography.control(16))
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                if let icon, iconTrailing {
                    AppIcon(name: icon, size: 20, tint: foreground).flipsForRightToLeftLayoutDirection(true)
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1.5))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var foreground: Color {
        switch style { case .primary: return .white; case .outline: return Theme.Palette.primaryText; case .danger: return Theme.Palette.danger }
    }
    private var background: Color {
        switch style { case .primary: return Theme.Palette.primary; case .outline: return .white; case .danger: return Theme.Palette.dangerSoft }
    }
    private var border: Color {
        switch style { case .primary: return .clear; case .outline: return Theme.Palette.primary; case .danger: return Theme.Palette.danger }
    }
}

/// A partner was bookmarked or un-bookmarked on one screen; lists showing the same
/// partner further down the stack update their heart instead of going stale.
enum FavoriteSync {
    static let changed = Notification.Name("Carezaar.favoriteChanged")

    static func post(userId: String, isFavorite: Bool) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["id": userId, "on": isFavorite])
    }

    static func decode(_ note: Notification) -> (id: String, on: Bool)? {
        guard let id = note.userInfo?["id"] as? String, let on = note.userInfo?["on"] as? Bool else { return nil }
        return (id, on)
    }
}

/// Unread notifications badge: `users/notifications/count?checked_at=`.
enum NotificationsBadge {
    static let key = "carezaar.notificationsCheckedAt"
    static var checkedAt: Int { UserDefaults.standard.integer(forKey: key) }
    static func markChecked() { UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: key) }
}

/// Empty-state artwork. The APK's chat drawable is a tint mask that renders as a
/// black silhouette untinted, so conversations and matches use the empty-conversation
/// art from the Figma frames; other illustrations are multi-colour and draw as-is.
struct EmptyArt: View {
    let name: String
    var body: some View {
        if name == "illus_chat", let url = SourceStore.assetURL("desktop-empty-message-illustration.jpg"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 150, height: 157)
                .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
        } else {
            AppIcon(name: name, size: 150)
        }
    }
}
