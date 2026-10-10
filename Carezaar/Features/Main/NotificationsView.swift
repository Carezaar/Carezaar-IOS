import SwiftUI

/// `Notifications`: subject label, partner and time. Opening one marks it seen and
/// routes by subject code — chat_* to the chat, *match to Matches, else the partner.
struct NotificationsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback
    @StateObject private var pager = Pager<AppNotification>()
    @EnvironmentObject private var poller: NotificationPoller
    @State private var seen: Set<Int> = []

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
    }

    private func row(_ n: AppNotification) -> some View {
        let unseen = !n.isSeen && !seen.contains(n.id)
        let subject = baseData.items(.subjects).first { $0.id == n.subjectId }
        let isChat = subject?.code == "chat_new"
        let dateParts = ServerTime.local(n.createdAt).split(separator: " ").map(String.init)
        // Figma v2 frame 738:11732: dot, subject icon, name + event, date, chevron.
        return Button { open(n, code: subject?.code ?? "") } label: {
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
                        Text(partner.fullName).font(Theme.Typography.title(13)).foregroundStyle(Color(hex: 0x111111))
                    }
                    Text(loc.label(subject)).font(Theme.Typography.body(12)).foregroundStyle(Color(hex: 0x111111))
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    AppIcon(name: "ic_clock", size: 12, tint: Theme.Palette.textSecondary)
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(dateParts, id: \.self) { Text($0) }
                    }
                }
                .font(Theme.Typography.caption(9)).foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxHeight: .infinity, alignment: .top)
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
    }

    private func open(_ n: AppNotification, code: String) {
        if !n.isSeen && !seen.contains(n.id) {
            seen.insert(n.id)
            Task { _ = try? await UserService().markNotificationSeen(id: n.id) }
        }
        // `match_accept`: the request was accepted, so "It's a Match!" (which re-checks
        // that the match is still active). `match`: a new request, so the requester's
        // profile, where Accept and Reject are.
        if code.hasPrefix("chat"), let chat = n.chat { router.push(.chat(chatId: chat.id)) }
        else if code == "match_accept", let partner = n.partner {
            router.push(.matched(partner: partner.role == .caregiver ? .caregiver(id: partner.id) : .client(id: partner.id)))
        }
        else if code == "match" || code == "match_accept" {
            if let partner = n.partner { router.push(profileRoute(partner)) }
            else { feedback.toast(loc.t("notification_target_unavailable", "This notification is no longer available.")) }
        }
        else if code == "unmatch" { router.push(.manageMatches) }
        else if let partner = n.partner { router.push(profileRoute(partner)) }
    }

    private func profileRoute(_ partner: User) -> Route {
        partner.role == .caregiver ? .caregiverDetails(caregiverId: partner.id) : .clientDetails(clientId: partner.id)
    }

    private let fetch: Pager<AppNotification>.Fetch = { page in try await UserService().notifications(page: page) }

    private func reload() async {
        try? await feedback.run("\(loc.t("loading_user_notifications_get", "Getting notifications - Page")) 1") { await pager.reload(fetch) }
    }
}
