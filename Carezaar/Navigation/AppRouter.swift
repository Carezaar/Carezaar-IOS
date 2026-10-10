import SwiftUI

/// Owns the navigation stack. Screens push by calling `router.push(_:)` rather than
/// constructing `NavigationLink` destinations, which keeps routing decisions in one
/// place the way `AppNavHost` does on Android.
@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []
    @Published var selectedTab: MainTab = .matches

    func push(_ route: Route) { path.append(route) }

    func pop() { if !path.isEmpty { path.removeLast() } }

    func popToRoot() { path.removeAll() }

    /// Replaces the whole stack — used when the session state changes and the app
    /// must move between the authenticated and unauthenticated graphs.
    func reset(to route: Route) { path = [route] }
}
