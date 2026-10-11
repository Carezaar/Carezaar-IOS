import SwiftUI

/// Binds live application state onto a rendered Figma scene.
///
/// The scene JSON is the visual source of truth and must not be re-laid-out by hand.
/// `DesignElement` already renders it pixel-for-pixel and already knows which nodes
/// are inputs (`inputType`) and which are actions (`actionTarget` / `selectionGroup`),
/// but it kept their state locally, which made the screens a demo.
///
/// A `SceneBinder` hoists that state into a view model: the geometry stays exactly as
/// designed while typing, tapping and selection drive real behaviour.
struct SceneBinder {
    /// Live text for an input node, or nil to leave it as a local demo field.
    var binding: (DesignNode) -> Binding<String>? = { _ in nil }
    /// A screen-owned visibility toggle; password inputs stay secure by default.
    var isPasswordRevealed: (DesignNode) -> Bool = { _ in false }
    /// Handles a tap. Return true when handled, false to fall back to scene navigation.
    var handle: (DesignNode) -> Bool = { _ in false }
    /// Whether a selectable node is currently selected (`selectionGroup` nodes).
    var isSelected: (DesignNode) -> Bool? = { _ in nil }
    /// Disables a control, e.g. a submit button while a request is in flight.
    var isEnabled: (DesignNode) -> Bool = { _ in true }
    /// Replacement copy for a text node. The v2 frames already contain slots for
    /// error messages, so validation is shown *in* the design rather than beneath it.
    var text: (DesignNode) -> String? = { _ in nil }
    /// Hides a node entirely — used for the designed error slots when there is no
    /// error.
    var isHidden: (DesignNode) -> Bool = { _ in false }
    /// Overrides a node's opacity. The v2 signup frame renders the five password
    /// rules as chips (`8+`, `A`, `a`, `1`, `@`); dimming the unmet ones makes the
    /// designed checklist live without redrawing it.
    var opacity: (DesignNode) -> Double? = { _ in nil }

    /// False only for the design catalog, which keeps the renderer's demo behaviour.
    var isBound = true

    static let inert = SceneBinder(isBound: false)
}

private struct SceneBinderKey: EnvironmentKey {
    static let defaultValue = SceneBinder.inert
}

extension EnvironmentValues {
    var sceneBinder: SceneBinder {
        get { self[SceneBinderKey.self] }
        set { self[SceneBinderKey.self] = newValue }
    }
}

extension DesignNode {
    /// Lowercased name + text, which is how the scenes identify their controls.
    var semanticLabel: String { (name + " " + label).lowercased() }

    /// True when this node is the screen's primary submit control.
    var isPrimaryButton: Bool { name == "Button" }

    var isBackButton: Bool { name == "Back" || name == "Header" }
}
