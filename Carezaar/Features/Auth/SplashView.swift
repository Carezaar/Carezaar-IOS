import SwiftUI

/// `Splash` — rendered from the v2 design (`Splash`, node 195:11749).
///
/// The Android app checks for a stored token here and routes to the authenticated
/// graph or to `Intro`. Base metadata is warmed at the same time so the signup
/// pickers have data before they are shown.
struct SplashView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization

    static let sceneKey = "v2-195-11749"

    private var failed: Bool { baseData.failed }

    var body: some View {
        // The splash frame has a tap target onto Intro; routing here is driven by
        // the session check instead, so every action is swallowed.
        FigmaScreen(key: Self.sceneKey,
                    binder: SceneBinder(handle: { _ in true }))
            .overlay {
                if failed {
                    VStack(spacing: 14) {
                        Text(loc.t("general_network_title", "Cannot communicate with server."))
                            .font(Theme.Typography.title(17)).multilineTextAlignment(.center)
                        PrimaryButton(title: loc.t("general_try_again", "Try Again")) {
                            Task {
                                if baseData.failed { await baseData.bootstrap() }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 320)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                }
            }
            .task {
                async let restore: Void = session.restore()
                async let bootstrap: Void = baseData.bootstrap()
                _ = await (restore, bootstrap)
            }
    }
}
