import SwiftUI

struct SourceScreen: View {
    let key: String
    let navigate: (String) -> Void
    @State private var node: DesignNode?
    @State private var error: String?
    var body: some View {
        GeometryReader { geometry in
            if let node {
                let scale = geometry.size.width / node.width
                let footerNodes = node.children.filter { $0.name.lowercased().contains("bootom navigation") || $0.name.lowercased().contains("bottom navigation") }
                let footerY = footerNodes.map(\.y).min() ?? node.height
                let footerHeight = footerNodes.isEmpty ? 0 : node.height - footerY
                let content = scrollingContent(node, footerIDs: Set(footerNodes.map(\.id)))
                let display = footerNodes.isEmpty ? ViewportLayout.fitting(content, height: geometry.size.height / scale) : content
                ScrollView {
                    DesignElement(node: display, navigate: action)
                        .frame(width: node.width, height: display.height, alignment: .topLeading)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: geometry.size.width, height: display.height * scale, alignment: .topLeading)
                }
                .defaultScrollAnchor(initialScrollAnchor)
                .clipped()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !footerNodes.isEmpty {
                        ZStack(alignment: .topLeading) {
                            Color.white
                            ForEach(footerNodes) { item in
                                let footer = shiftedFooter(item, by: footerY)
                                DesignElement(node: footer, navigate: action)
                            }
                        }
                        .frame(width: node.width, height: footerHeight, alignment: .topLeading)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: geometry.size.width, height: footerHeight * scale, alignment: .topLeading)
                    }
                }
                .scrollIndicators(.hidden)
                .background(.white)
                .accessibilityIdentifier(key)
            } else if let error { ContentUnavailableView("Screen unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
        .task(id: key) {
            do { node = try SourceStore.load(key, folder: "Scenes"); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    // Debug launch option for reproducible lower-viewport visual regression captures.
    private var initialScrollAnchor: UnitPoint {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--scroll-bottom") { return .bottom }
        #endif
        return .top
    }
    private func shiftedFooter(_ node: DesignNode, by origin: Double) -> DesignNode {
        var result = node; result.y -= origin; return result
    }
    private func scrollingContent(_ node: DesignNode, footerIDs: Set<String>) -> DesignNode {
        guard !footerIDs.isEmpty else { return node }
        var result = node
        result.children.removeAll { footerIDs.contains($0.id) || ($0.kind == "rectangle" && $0.y >= node.height * 0.85 && $0.height <= 100) }
        result.height = max(node.height, result.children.map { $0.y + $0.height }.max() ?? node.height)
        return result
    }
    private func action(_ element: DesignNode) {
        func destination(_ n: DesignNode) -> String? { n.actionTarget ?? n.children.compactMap(destination).first }
        if let target = destination(element) { navigate(target); return }
        let label = (element.name + " " + element.label).lowercased()
        if element.name == "Back" { navigate("back") }
        else if label.contains("sign in") { navigate(key == "v2-51-5170" ? "mobile-734-11717" : "v2-51-5170") }
        else if label.contains("care needer") || label.contains("caregiver") { navigate("v2-32-14974") }
        else if label.contains("get started") { navigate("v2-101-11973") }
        else if label.contains("confirm") { navigate("v2-65-19934") }
        else if label.contains("edit") { navigate("v2-32-14974") }
        else if label.contains("continue"), key == "v2-32-14974" { navigate("v2-56-84378") }
        else if label.contains("continue"), key == "v2-101-11973" { navigate("mobile-746-11740") }
    }
}
