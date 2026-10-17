import SwiftUI

/// Tapping marks a notification read and presents its details. Show alone navigates.
struct NotificationsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var pager = Pager<AppNotification>()
    @EnvironmentObject private var poller: NotificationPoller
    @State private var seen: Set<Int> = []
    @State private var selected: AppNotification?

    var body: some View {
        ScrollView {
            PagedContent(pager: pager, emptyTitle: loc.t("general_notifications", "Notifications"),
                         emptyIcon: "ic_notification_off",
                         retry: { Task { await reload() } }, more: { Task { await pager.loadMore(fetch) } }) { n in
                row(n)
            }
        }
        .refreshable { await pager.reload(fetch) }
        .backHeader(loc.t("general_notifications", "Notifications"))
        .task { await reload() }
        .onDisappear { poller.markChecked() }
        .allowsHitTesting(selected == nil)
        .accessibilityHidden(selected != nil)
        .overlay {
            if let notification = selected {
                GeometryReader { geometry in
                    ZStack {
                        Button { selected = nil } label: {
                            Color.black.opacity(0.3).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc.t("general_cancel", "Cancel"))
                        .accessibilityIdentifier("notification-dismiss-backdrop")
                        notificationDetails(notification)
                            .frame(maxWidth: 420, maxHeight: geometry.size.height * 0.72)
                            .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                            .padding(.horizontal, 20)
                            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                            .accessibilityAction(.escape) { selected = nil }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func row(_ n: AppNotification) -> some View {
        let unseen = !n.isSeen && !seen.contains(n.id)
        let subject = baseData.items(.subjects).first { $0.id == n.subjectId }
        let isChat = subject?.code == "chat_new"
        let timestamp = ServerTime.local(n.createdAt)
        // Figma v2 frame 738:11732: dot, subject icon, name + event, date, chevron.
        return Button { select(n) } label: {
            AdaptiveStack(alignment: .center, spacing: 12) {
                Circle().fill(unseen ? Theme.Palette.primary : .clear).frame(width: 7, height: 7)
                    .accessibilityLabel(unseen ? "Unread" : "")
                ZStack {
                    Circle().fill(isChat ? Color(hex: 0xF0EBFA) : Color(hex: 0xFFF0B8))
                    AppIcon(name: isChat ? "ic_message" : "ic_info_circle", size: 22,
                            tint: isChat ? Color(hex: 0x6D4BC2) : Color(hex: 0xB98900))
                }
                .frame(width: 49, height: 49)
                VStack(alignment: .leading, spacing: 6) {
                    if let partner = n.partner {
                        Text(partner.displayName(loc)).font(Theme.Typography.title(13)).foregroundStyle(Color(hex: 0x111111))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(loc.label(subject)).font(Theme.Typography.body(12)).foregroundStyle(Color(hex: 0x111111))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                Spacer(minLength: 8)
                HStack(alignment: .top, spacing: 4) {
                    AppIcon(name: "ic_clock", size: 12, tint: Theme.Palette.textSecondary)
                    Text(timestamp)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Typography.caption(9)).foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
            }
            .padding(.leading, 25).padding(.trailing, 36).padding(.vertical, 14)
            .frame(minHeight: 95)
            .overlay(alignment: .bottomTrailing) {
                AppIcon(name: "ic_chevron_forward", size: 16, tint: Theme.Palette.textSecondary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .padding(.trailing, 12).padding(.bottom, 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if DEBUG
        .accessibilityIdentifier("notification-row-\(n.id)")
        #endif
    }

    private func select(_ n: AppNotification) {
        selected = n
        if !n.isSeen && !seen.contains(n.id) {
            seen.insert(n.id)
            Task { _ = try? await UserService().markNotificationSeen(id: n.id) }
        }
    }

    private func notificationDetails(_ n: AppNotification) -> some View {
        let subject = baseData.items(.subjects).first { $0.id == n.subjectId }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let partner = n.partner {
                    HStack(spacing: 12) {
                        Avatar(url: partner.photo, size: 64)
                        Text(partner.displayName(loc)).font(Theme.Typography.title(17))
                    }
                }
                Text(loc.label(subject)).font(Theme.Typography.body(16))
                PrimaryButton(title: loc.t("general_show", "Show")) {
                    selected = nil
                    // A missing target simply dismisses the detail. The list remains
                    // usable; never push an invented id or a broken destination.
                    if let route = Self.destination(for: n, code: subject?.code ?? "") {
                        router.push(route)
                    }
                }
                .accessibilityIdentifier("notification-show")
            }
            .padding(20)
        }
        .accessibilityIdentifier("notification-detail")
    }

    static func destination(for n: AppNotification, code: String) -> Route? {
        if code.hasPrefix("chat"), let chat = n.chat { return .chat(chatId: chat.id) }
        guard let partner = n.partner, !partner.id.isEmpty else { return nil }
        if code == "match_accept" {
            return .matched(partner: partner.role == .caregiver ? .caregiver(id: partner.id) : .client(id: partner.id))
        }
        return partner.role == .caregiver ? .caregiverDetails(caregiverId: partner.id) : .clientDetails(clientId: partner.id)
    }

    private let fetch: Pager<AppNotification>.Fetch = { page in try await UserService().notifications(page: page) }

    private func reload() async {
        try? await feedback.run("\(loc.t("loading_user_notifications_get", "Getting notifications - Page")) 1") { await pager.reload(fetch) }
    }
}
