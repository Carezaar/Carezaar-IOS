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
    /// A quiet refresh of the loaded pages is running (`refreshLoaded`): nothing is shown for
    /// it, and further pages wait until it is done.
    @Published private(set) var isRevalidating = false
    private(set) var page = 0
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

    /// Pull-to-refresh. The load runs in its own task: the refresh control cancels its task when
    /// the scroll content changes, and a cancelled newest load would otherwise leave the list
    /// with neither the earlier load's answer nor its own (25 Oct 2026).
    func refresh(_ fetch: @escaping Fetch) async {
        await Task { await self.reload(fetch) }.value
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

    /// Quiet refresh of every page already loaded (My Matches on return, client request
    /// 23 Oct 2026): pages 1…N are asked for again while the list stays on screen, with no
    /// loading or error state, and replace it only once all have answered. They are rebuilt in
    /// order with the usual rules (no id twice; an empty page, or one adding nothing, ends the
    /// list). A failure keeps the list; a reload started meanwhile (a new sort) wins.
    @discardableResult
    func refreshLoaded(_ fetch: @escaping Fetch) async -> Bool {
        guard loadedOnce, page > 0, !isLoading, !isRevalidating else { return false }
        let g = generation, count = page
        isRevalidating = true
        defer { isRevalidating = false }
        do {
            let answers = try await withThrowingTaskGroup(of: (Int, [Item], APIMeta?).self) { group in
                for p in 1...count { group.addTask { let (result, meta) = try await fetch(p); return (p, result, meta) } }
                var out: [(Int, [Item], APIMeta?)] = []
                for try await answer in group { out.append(answer) }
                return out.sorted { $0.0 < $1.0 }
            }
            guard g == generation, !isLoading, !Task.isCancelled else { return false }
            var seen = Set<Item.ID>(), merged: [Item] = [], pages = 0, ended = false
            for (_, result, _) in answers {
                pages += 1
                let fresh = result.filter { seen.insert($0.id).inserted }
                if result.isEmpty || fresh.isEmpty { ended = true; break }
                merged += fresh
            }
            items = merged
            page = pages
            exhausted = ended
            total = answers.first?.2?.total ?? total
            error = nil
            return true
        } catch {
            return false
        }
    }

    func loadMore(_ fetch: Fetch) async {
        guard hasMore, !isLoading, !isRevalidating else { return }
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
    /// The rows are scroll targets, so the enclosing ScrollView can report and restore which
    /// row is at the top (`scrollPosition(id:)`; My Matches keeps its place).
    var scrollTargets = false
    /// The shape of the skeleton rows shown until the first page arrives.
    var skeleton: SkeletonList.Style = .card
    @ViewBuilder let row: (Item) -> Row
    @EnvironmentObject private var loc: Localization

    var body: some View {
        if let error = pager.error, pager.items.isEmpty {
            ErrorState(message: Feedback.message(error)) { retry() }
                .padding(.top, 40)
        } else if pager.items.isEmpty && (pager.isLoading || !pager.loadedOnce) {
            // The first page: placeholders in the shape of the rows (client request, 25 Oct 2026).
            SkeletonList(style: skeleton)
                // A first load that was cancelled leaves nothing loading and nothing loaded:
                // load once more rather than show placeholders for ever. It fires only from that
                // idle state (never while a load runs), so it can't repeat itself.
                .task(id: pager.isLoading) {
                    guard !pager.isLoading, !pager.loadedOnce, pager.error == nil else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, !pager.isLoading, !pager.loadedOnce, pager.error == nil else { return }
                    retry()
                }
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
        } else if scrollTargets {
            rows.scrollTargetLayout()
        } else {
            rows
        }
    }

    private var rows: some View {
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

// MARK: - Skeletons

/// The shimmer of a placeholder. It exists only while the placeholder is on screen, so it stops
/// the moment the content, an empty state or an error replaces it; it requests nothing itself.
/// Still under Reduce Motion.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

private struct Bone: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(red: 0.91, green: 0.93, blue: 0.96))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Rows loading: card (photo and three lines), row (avatar and two lines) or issue (three lines).
struct SkeletonList: View {
    enum Style { case card, row, issue }
    var style: Style = .card
    var count = 4
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    if style == .card { Bone(width: 88, height: 88, radius: 12) }
                    if style == .row { Bone(width: 48, height: 48, radius: 24) }
                    VStack(alignment: .leading, spacing: 10) {
                        Bone(width: 150)
                        Bone(width: 220)
                        if style != .row { Bone(width: 110) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12)
        .modifier(Shimmer())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("skeleton")
    }
}

/// A profile or details page loading: photo, name and a few sections.
struct SkeletonDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Bone(height: 220, radius: 20)
            Bone(width: 180, height: 22)
            Bone(width: 120)
            ForEach(0..<3, id: \.self) { _ in
                Bone(width: 140).padding(.top, 10)
                HStack(spacing: 8) { Bone(width: 96, height: 32, radius: 16); Bone(width: 96, height: 32, radius: 16); Bone(width: 96, height: 32, radius: 16) }
            }
        }
        .padding(20)
        .modifier(Shimmer())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("skeleton")
    }
}

/// A conversation loading: message bubbles on both sides.
struct SkeletonChat: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array([(false, 190.0), (false, 140.0), (true, 220.0), (false, 160.0), (true, 130.0), (true, 200.0)].enumerated()), id: \.offset) { _, bubble in
                HStack {
                    if bubble.0 { Spacer(minLength: 0) }
                    Bone(width: bubble.1, height: 44, radius: 16)
                    if !bubble.0 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(16)
        .modifier(Shimmer())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("skeleton")
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
    /// The action is running: progress in place of the icon, and the button is disabled.
    var loading = false
    /// Forward arrows ("Keep Exploring →") follow the label, as on Android.
    var iconTrailing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(foreground) }
                else if let icon, !iconTrailing { AppIcon(name: icon, size: 20, tint: foreground) }
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
        .disabled(!enabled || loading)
        .accessibilityValue(loading ? "In progress" : "")
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
