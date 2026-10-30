import SwiftUI

/// Renders a Figma scene at its designed geometry and binds it to live state.
///
/// This is how a screen that *has* a v2 design should be built: the layout comes from
/// the extracted scene JSON, never from hand-written SwiftUI, so the result matches
/// the design by construction. Behaviour arrives through the `SceneBinder`.
///
/// Screens with no v2 design use hand-built SwiftUI instead — see
/// `FUNCTIONAL-PARITY-MATRIX.md` for which are which.
/// A real control placed in scene coordinates, for behaviour the Kotlin app has but
/// the frame has no node for (e.g. "Forgot Password", the licence checkbox). It
/// scales and mirrors with the design.
struct SceneOverlay: Identifiable {
    let id = UUID()
    let frame: CGRect
    let content: AnyView

    init<V: View>(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> V) {
        frame = CGRect(x: x, y: y, width: width, height: height)
        self.content = AnyView(content())
    }
}

struct FigmaScreen<Overlay: View>: View {
    let key: String
    var binder: SceneBinder
    var overlays: [SceneOverlay] = []
    /// Scale the whole frame into the visible height instead of scrolling, for
    /// frames whose only action sits at the bottom.
    var fitHeight = false
    /// Short, noninteractive loading scenes can reclaim blank vertical gaps
    /// while preserving their text sizes and artwork geometry.
    var compactVerticalGaps = false
    /// Scrolls the frame back to its top whenever this value changes (a dialog drawn in
    /// the frame opening while the view is scrolled to a field lower down).
    var scrollTopTrigger: Bool = false
    @ViewBuilder var overlay: () -> Overlay

    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var language: AppLanguage

    @State private var node: DesignNode?
    @State private var loadError: String?

    /// The scene JSON has English baked into its text nodes. Rather than re-author
    /// the designs per language, each string is looked up in the server-driven
    /// content table and swapped for the current language. The screen's own override
    /// (validation messages) still wins.
    private var localisedBinder: SceneBinder {
        var composed = binder
        let screenText = binder.text
        composed.text = { node in
            if let own = screenText(node) { return own }
            guard let english = node.text else { return nil }
            return baseData.localization.translating(english: english,
                                                     languageId: language.id)
        }
        return composed
    }

    var body: some View {
        GeometryReader { geometry in
            if let node {
                let widthScale = geometry.size.width / node.width
                let display = compactVerticalGaps && widthScale > 0
                    ? ViewportLayout.fitting(node, height: geometry.size.height / widthScale) : node
                let scale = fitHeight ? min(geometry.size.width / display.width, geometry.size.height / display.height)
                    : widthScale
                ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        DesignElement(node: display, navigate: { _ in })
                        // Positional identity: overlays are rebuilt on every render, and a
                        // fresh id each time would tear down (and unfocus) their fields.
                        ForEach(Array(overlays.enumerated()), id: \.offset) { _, item in
                            item.content
                                .frame(width: item.frame.width, height: item.frame.height)
                                .offset(x: item.frame.minX, y: item.frame.minY)
                        }
                    }
                        .frame(width: display.width, height: display.height, alignment: .topLeading)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: display.width * scale, height: display.height * scale, alignment: .topLeading)
                        .frame(width: geometry.size.width)
                        .id("scene-top")
                }
                .onChange(of: scrollTopTrigger) { _, _ in
                    withAnimation { proxy.scrollTo("scene-top", anchor: .top) }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(fitHeight)
                .environment(\.sceneBinder, localisedBinder)
                .accessibilityIdentifier(key)
                // Status messages sit above the design rather than displacing it,
                // because the source frames have no slot for them. Their own height only:
                // offered the full height, the inset took it all (894 pt on a 6.9"
                // phone), leaving a zero-height viewport that one swipe scrolled the
                // whole design out of — a blank white screen.
                .safeAreaInset(edge: .bottom, spacing: 0) { overlay().fixedSize(horizontal: false, vertical: true) }
                }
            } else if let loadError {
                ErrorState(message: loadError)
            } else {
                LoadingState()
            }
        }
        .background(Theme.Palette.surface)
        .task(id: key) {
            do {
                node = try SourceStore.load(key, folder: "Scenes")
                loadError = nil
            } catch {
                loadError = "This screen could not be loaded."
            }
        }
    }
}

extension FigmaScreen where Overlay == EmptyView {
    init(key: String, binder: SceneBinder, overlays: [SceneOverlay] = [], fitHeight: Bool = false, compactVerticalGaps: Bool = false, scrollTopTrigger: Bool = false) {
        self.init(key: key, binder: binder, overlays: overlays, fitHeight: fitHeight, compactVerticalGaps: compactVerticalGaps, scrollTopTrigger: scrollTopTrigger) { EmptyView() }
    }
}

/// Status strip shown under a Figma scene for errors and in-flight work, so the
/// designed frame itself is never altered.
struct SceneStatusBar: View {
    var message: String?
    var isBusy: Bool = false

    var body: some View {
        if let message {
            HStack(spacing: Theme.Spacing.xs) {
                if isBusy { ProgressView() }
                Text(message)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Palette.error)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.error.opacity(0.08))
        } else if isBusy {
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView()
                Text("Please wait…")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.clientPanel)
        }
    }
}
