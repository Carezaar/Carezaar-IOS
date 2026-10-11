import SwiftUI

struct DesignElement: View {
    let node: DesignNode
    let navigate: (DesignNode) -> Void
    var insideButton = false
    /// Parent width, so a translated one-line label can grow into free space.
    var parentWidth: Double?
    /// Supplied by a `FigmaScreen` so the scene drives real state instead of a demo.
    @Environment(\.sceneBinder) private var binder
    @Environment(\.layoutDirection) private var direction
    @State private var replacement: DesignNode?
    @State private var value = ""
    @State private var selected = false

    /// External binding when a screen owns this field, else the local demo state.
    private var text: Binding<String> { binder.binding(rendered) ?? $value }
    /// External selection when a screen owns it, else the local demo toggle.
    private var isSelected: Bool { binder.isSelected(rendered) ?? selected }
    private var rendered: DesignNode {
        var base = node
        if var updated = replacement {
            updated.x = node.x; updated.y = node.y
            updated.width = node.width; updated.height = node.height
            base = updated
        }
        // A bound screen may substitute copy into a designed text slot.
        if base.text != nil, let override = binder.text(base), override != base.text {
            base.text = override
            base.isTextSubstituted = true
            // Translated copy is usually longer than the English the box was drawn
            // for; a one-line label grows towards the far edge of its parent before
            // it has to shrink.
            if base.inputType == nil, let parentWidth, base.height < (base.fontSize ?? 14) * 2.2 {
                let need = (override as NSString).size(withAttributes: [.font: base.sourceFont]).width + 2
                let room = parentWidth - base.x - 4
                if need > base.width, room > base.width { base.width = min(need, room) }
            }
        }
        return base
    }
    private var isInput: Bool { rendered.inputType != nil }
    private var isButton: Bool {
        !insideButton && (rendered.actionTarget != nil || rendered.stateTarget != nil || rendered.selectionGroup != nil || ["Button", "Back", "Care Needer", "Caregiver"].contains(rendered.name) || (!binder.isBound && ["Sign in", "Sign In", "Get Started", "Continue", "Confirm", "Edit"].contains(rendered.text ?? "")))
    }
    var body: some View {
        if binder.isHidden(node) {
            EmptyView()
        } else {
            rendering
        }
    }

    /// Brand marks keep their composition in right-to-left layouts. Only the mark's
    /// contents are forced left-to-right; its own position still mirrors.
    private var isLogo: Bool { node.name.lowercased().contains("logo") }

    /// Glyphs that point along the reading direction mirror their drawing in RTL,
    /// not just their position.
    private var mirrorsGlyph: Bool {
        direction == .rightToLeft
            && rendered.name.range(of: #"chevron|angle-(left|right)|arrow-(left|right)|trailing icon"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var rendering: some View {
        element
            .environment(\.layoutDirection, isLogo ? .leftToRight : direction)
            .scaleEffect(x: mirrorsGlyph ? -1 : 1, y: 1, anchor: .center)
            .frame(width: max(rendered.width, 0), height: max(rendered.height, 0), alignment: .topLeading)
            .modifier(SourceClip(enabled: rendered.clip && rendered.kind != "line" && rendered.width > 1 && rendered.height > 1))
            .overlay { if isSelected { RoundedRectangle(cornerRadius: rendered.radius).stroke(DesignTokens.primary, lineWidth: 2) } }
            .opacity(binder.opacity(rendered) ?? rendered.opacity)
            .transformEffect(CGAffineTransform(a: rendered.matrix[0], b: rendered.matrix[1], c: rendered.matrix[2], d: rendered.matrix[3], tx: 0, ty: 0))
            .offset(x: rendered.x, y: rendered.y)
            .onAppear { if binder.binding(rendered) == nil { value = rendered.inputValue ?? "" } }
    }
    @ViewBuilder private var element: some View {
        if isInput {
            Group {
                if rendered.inputType == "multiline" {
                    TextField("", text: text, prompt: Text(rendered.displayText).foregroundColor(rendered.color), axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.sentences)
                }
                else if rendered.inputType == "password" {
                    Group {
                        if binder.isPasswordRevealed(rendered) {
                            TextField("", text: text, prompt: Text(rendered.displayText).foregroundColor(rendered.color))
                        } else {
                            SecureField("", text: text, prompt: Text(rendered.displayText).foregroundColor(rendered.color))
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                else {
                    TextField("", text: text, prompt: Text(rendered.displayText).foregroundColor(rendered.color))
                        .keyboardType(rendered.inputType == "email" ? .emailAddress : rendered.inputType == "tel" ? .phonePad : .default)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .font(Font(rendered.sourceFont))
            // The frame's text node is the placeholder (the prompt keeps its colour);
            // typed text uses the text colour.
            .foregroundStyle(Theme.Palette.textPrimary)
            .accessibilityLabel(rendered.text ?? "")
        } else if isButton {
            Button {
                // A bound screen gets first refusal; otherwise the scene's own
                // demo navigation still applies (used by the design catalog).
                if binder.handle(rendered) { return }
                if let target = rendered.stateTarget { replacement = try? SourceStore.load(target, folder: "Scenes") }
                else if rendered.selectionGroup != nil { selected.toggle() }
                else { navigate(rendered) }
            } label: { content }
                .buttonStyle(.plain)
                .disabled(!binder.isEnabled(rendered))
                .accessibilityLabel(rendered.label.isEmpty ? rendered.name : rendered.label)
                .accessibilityAddTraits(.isButton)
        } else { content }
    }
    private var content: AnyView {
        if rendered.text != nil { return AnyView(SourceText(node: rendered)) }
        if rendered.kind == "vector" || rendered.kind == "line" { return AnyView(SourceVector(node: rendered)) }
        return AnyView(ZStack(alignment: .topLeading) {
            SourceSurface(node: rendered).frame(width: rendered.width, height: rendered.height)
            ForEach(Array(Self.placeMarkers(rendered.children, binder).enumerated()), id: \.offset) { _, child in
                DesignElement(node: child, navigate: navigate, insideButton: insideButton || isButton, parentWidth: rendered.width)
            }
        })
    }
}
extension DesignElement {
    /// A required-field "*" and a button's trailing arrow are separate nodes placed
    /// after the English label. When the label is translated, keep them just after
    /// the label's rendered text; the marker's box is shrunk to its glyph so it
    /// mirrors next to the label in RTL.
    static func placeMarkers(_ children: [DesignNode], _ binder: SceneBinder) -> [DesignNode] {
        func shownWidth(_ label: DesignNode) -> CGFloat? {
            guard let original = label.text, let shown = binder.text(label), shown != original else { return nil }
            return (shown as NSString).size(withAttributes: [.font: label.sourceFont]).width
        }
        return children.map { child in
            var c = child
            if c.name.range(of: "trailing icon", options: .caseInsensitive) != nil {
                guard let label = children.first(where: { $0.text != nil && $0.x < c.x }), let width = shownWidth(label) else { return c }
                let gap = c.x - (label.x + label.width)
                c.x = label.x + max(label.width, width) + gap
                return c
            }
            guard c.text?.trimmingCharacters(in: .whitespaces) == "*" else { return c }
            guard let label = children.first(where: { $0.text != nil && $0.text?.trimmingCharacters(in: .whitespaces) != "*"
                                                       && abs($0.y - c.y) < 12 && $0.x < c.x }),
                  let width = shownWidth(label) else { return c }
            c.x = label.x + width + 3
            c.width = ("*" as NSString).size(withAttributes: [.font: c.sourceFont]).width + 2
            return c
        }
    }
}

struct SourceClip: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View { if enabled { content.clipped() } else { content } }
}
