import SwiftUI

extension Theme.Palette {
    static let primaryDark = Color(hex: 0x1B4F8F)
    static let primarySoft = Color(hex: 0xE7F1FF)
    static let warning = Color(hex: 0xE39B0B)
    static let danger = Color(hex: 0xD6202D)
    /// Small destructive labels need stronger contrast on the pale red panel.
    static let dangerText = Color(hex: 0xB91C28)
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
    /// Server totals are informational: rows may be added after the first response.
    /// Only an empty page or a repeated page with no new ids ends the traversal.
    private var exhausted = false

    var hasMore: Bool { !exhausted }

    /// Each reload starts a new generation; results from an older, superseded load
    /// (e.g. one whose view disappeared mid-flight) are discarded instead of
    /// blocking the new one.
    private var generation = 0

    func reload(_ fetch: Fetch) async {
        generation += 1
        page = 0; exhausted = false; error = nil
        await next(fetch, replacing: true, generation: generation)
    }

    /// Periodic background refresh (Messages list, K1): replaces the list with the
    /// first page only when it loads, never shows loading or error state, and yields
    /// to any explicit load or reload in flight.
    func refreshQuietly(_ fetch: Fetch) async {
        guard !isLoading, loadedOnce else { return }
        let g = generation
        guard let (result, meta) = try? await fetch(1), g == generation, !isLoading, !Task.isCancelled else { return }
        var seen = Set<Item.ID>()
        items = result.filter { seen.insert($0.id).inserted }
        page = 1
        exhausted = result.isEmpty
        total = meta?.total
        error = nil
    }

    func loadMore(_ fetch: Fetch) async {
        guard hasMore, !isLoading else { return }
        await next(fetch, replacing: page == 0, generation: generation)
    }

    private func next(_ fetch: Fetch, replacing: Bool, generation g: Int) async {
        isLoading = true
        error = nil
        let requestedPage = page + 1
        defer { if g == generation { isLoading = false } }
        do {
            let (result, meta) = try await fetch(requestedPage)
            try Task.checkCancellation()
            guard g == generation else { return }
            loadedOnce = true
            page = requestedPage
            total = meta?.total ?? (replacing ? nil : total)
            // The server's order isn't stable for equal sort keys (BE-16), so a later
            // page can repeat someone; duplicate ids would also break `ForEach`.
            var seen = Set(replacing ? [] : items.map(\.id))
            let fresh = result.filter { seen.insert($0.id).inserted }
            exhausted = result.isEmpty || (!replacing && fresh.isEmpty)
            items = replacing ? fresh : items + fresh
        } catch is CancellationError {
        } catch {
            guard g == generation else { return }
            loadedOnce = true
            // Keep a valid loaded list even if an explicit reload fails. A later
            // page failure also leaves the page number unchanged for its retry.
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
                if let error = pager.error {
                    VStack(spacing: 10) {
                        ErrorBanner(message: Feedback.message(error))
                        OutlineButton(title: loc.t("general_try_again", "Try Again")) { more() }
                            .accessibilityIdentifier("pagination-retry")
                    }
                    .padding(20)
                }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var headerHeight: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(Theme.Typography.heading(28))
                    .fixedSize(horizontal: false, vertical: true)
                AppIcon(name: icon, size: 28, tint: Theme.Palette.primaryDark)
                    .fixedSize().layoutPriority(1)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(Theme.Typography.body(14))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 300, alignment: .leading)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
        // The picture keeps its ordinary height, but wrapped text can make the
        // header taller. Scaling a fixed height alone still clipped long copy.
        .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .leading)
        .background {
            GeometryReader { geo in
                if let ui = AppImage.load(image) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    Theme.Palette.clientPanel
                }
            }
        }
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
    @Environment(\.dynamicTypeSize) private var textSize

    private var leadingIcon: some View {
        AppIcon(name: icon, size: 28, tint: tint)
            .frame(width: 48, height: 48)
            .background(Theme.Palette.clientPanel, in: Circle())
    }

    private var chevron: some View {
        AppIcon(name: "ic_chevron_forward", size: 18, tint: Theme.Palette.textSecondary)
            .flipsForRightToLeftLayoutDirection(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Typography.title(16)).foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
            if !description.isEmpty {
                Text(description).font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if textSize.isAccessibilitySize {
                    // Large text needs the full card width; the normal icon/text
                    // row left only182pt for the Help description on small phones.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { leadingIcon; Spacer(minLength: 8); chevron }
                        labels.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 14) {
                        leadingIcon
                        labels
                        Spacer(minLength: 8)
                        chevron
                    }
                }
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
            Text(title).font(danger ? Theme.Typography.control(13) : Theme.Typography.filledLabel(14))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(danger ? Theme.Palette.dangerText : .white)
                .background(danger ? Theme.Palette.dangerSoft : Theme.Palette.primaryFill, in: Capsule())
                .overlay(Capsule().stroke(danger ? Theme.Palette.danger : .clear))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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
        }
        .buttonStyle(ReadableInactiveStyle())
        .disabled(!enabled)
    }

    /// PlainButtonStyle fades disabled labels even when their colors are opaque.
    /// Keep its exact enabled appearance while letting the native disabled Button
    /// display our readable inactive palette without another visual fade.
    private struct ReadableInactiveStyle: PrimitiveButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        @ViewBuilder
        func makeBody(configuration: Configuration) -> some View {
            if isEnabled {
                PlainButtonStyle().makeBody(configuration: configuration)
            } else {
                Button(configuration).buttonStyle(InactiveLabelStyle())
            }
        }

        /// The primitive adapter keeps native Button activation and inherited
        /// disabled semantics; only its label presentation bypasses fading.
        private struct InactiveLabelStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }
    }

    private var foreground: Color {
        if !enabled { return Theme.Palette.disabledForeground }
        switch style { case .primary: return .white; case .outline: return Theme.Palette.primaryText; case .danger: return Theme.Palette.dangerText }
    }
    private var background: Color {
        if !enabled { return Theme.Palette.disabledBackground }
        switch style { case .primary: return Theme.Palette.primary; case .outline: return .white; case .danger: return Theme.Palette.dangerSoft }
    }
    private var border: Color {
        if !enabled { return Theme.Palette.disabledBackground }
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
