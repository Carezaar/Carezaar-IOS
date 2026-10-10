import SwiftUI
import UIKit

/// UIKit's baseline drawing keeps the source's line boxes exact while exposing native accessible text.
struct SourceText: View {
    let node: DesignNode
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        let inset = (node.fontSize ?? 14) * 2
        // Figma text can overflow a narrow layout box. Preserve that overflow until
        // an actual clipping ancestor, rather than clipping at UIView's draw rect.
        // Translated copy is fitted to its box when drawn, so it never overflows.
        let textWidth = node.isTextSubstituted == true ? node.width : node.displayText.components(separatedBy: "\n").map {
            ($0 as NSString).size(withAttributes: [.font: node.sourceFont]).width
        }.max() ?? node.width
        BaselineTextView(node: node, drawingInset: inset, rightToLeft: direction == .rightToLeft)
            .frame(width: max(node.width, textWidth) + inset * 2, height: node.height + inset * 2)
            .offset(x: -inset, y: -inset)
            .frame(width: node.width, height: node.height, alignment: .topLeading)
    }
}
private struct BaselineTextView: UIViewRepresentable {
    let node: DesignNode
    let drawingInset: Double
    let rightToLeft: Bool
    func makeUIView(context: Context) -> BaselineLabel { BaselineLabel() }
    func updateUIView(_ view: BaselineLabel, context: Context) {
        view.node = node
        view.drawingInset = drawingInset
        view.rightToLeft = rightToLeft
        view.isAccessibilityElement = true
        view.accessibilityLabel = node.text
        view.backgroundColor = .clear
        view.setNeedsDisplay()
    }
}
final class BaselineLabel: UIView {
    var node: DesignNode?
    var drawingInset: Double = 0
    /// Translated copy in an RTL layout reads from the box's right edge.
    var rightToLeft = false
    override func draw(_ rect: CGRect) {
        guard let node, let text = node.text else { return }
        UIGraphicsGetCurrentContext()?.translateBy(x: drawingInset, y: drawingInset)
        // Glyph outlines encode the original string; skip them once it is replaced.
        if node.isTextSubstituted != true,
           let glyphs = node.glyphPaths, !glyphs.isEmpty, let context = UIGraphicsGetCurrentContext() {
            context.setFillColor(UIColor(node.color).cgColor)
            for glyph in glyphs { context.setFillColor(UIColor(glyph.color == nil ? node.color : Color(source: glyph.color)).cgColor); context.addPath(SVGPath.decode(glyph.d).cgPath); context.fillPath() }
            return
        }
        let font = node.sourceFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(node.color)]
        let displayText = node.textCase == "TITLE" ? text.capitalized : node.textCase == "UPPER" ? text.uppercased() : text
        let scalars = Array(displayText.unicodeScalars)
        // Line ranges were measured against the original string too.
        if node.isTextSubstituted != true, let lines = node.lines, !lines.isEmpty {
            let visibleLines = lines.filter { node.textTruncation != "ENDING" || $0.position.y <= node.height }
            for (index,line) in visibleLines.enumerated() {
                let start = min(line.firstCharacter, scalars.count), end = node.textTruncation == "ENDING" && index == visibleLines.count - 1 ? scalars.count : min(line.endCharacter, scalars.count)
                let substring = String(String.UnicodeScalarView(scalars[start..<max(start,end)])).trimmingCharacters(in: .newlines)
                if node.textTruncation == "ENDING" {
                    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                    var styled = attributes; styled[.paragraphStyle] = paragraph
                    (substring as NSString).draw(in: CGRect(x: line.position.x, y: line.position.y - font.ascender, width: node.width - line.position.x, height: font.lineHeight), withAttributes: styled)
                } else { (substring as NSString).draw(at: CGPoint(x: line.position.x, y: line.position.y - font.ascender), withAttributes: attributes) }
            }
        } else if node.isTextSubstituted == true {
            // Translated copy is usually a different length to the English the frame
            // was measured against. `SourceText` already widens the view to fit the
            // current string, so draw unconstrained rather than clipping to the
            // original box. The baseline still comes from the design.
            // Fit to the box: one-line labels shrink (not below 55%); taller boxes
            // wrap within their width and shrink less (not below 70%).
            let size = font.pointSize
            let natural = (displayText as NSString).size(withAttributes: attributes).width
            let multiLine = node.height >= size * 2.2
            let floor: CGFloat = multiLine ? 0.7 : 0.55
            var scale = natural > node.width ? max(floor, node.width / natural) : 1
            if multiLine {
                // Wrapped copy must also fit the box's height (small trust-row labels).
                let limit = node.height + size * 0.4
                while scale > 0.5 {
                    let trial = font.withSize(size * scale)
                    let used = (displayText as NSString).boundingRect(
                        with: CGSize(width: node.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin], attributes: [.font: trial], context: nil).height
                    if used <= limit { break }
                    scale -= 0.05
                }
            }
            let fitted = font.withSize(size * scale)
            let paragraph = NSMutableParagraphStyle()
            // The frame records alignment only through where each measured line sits;
            // keep centred copy centred when the text changes.
            let centred = node.lines.map { lines in
                !lines.isEmpty && lines.contains { $0.position.x > 4 } && lines.allSatisfy { line in
                    guard let w = line.width else { return false }
                    return abs(line.position.x - (node.width - w - line.position.x)) < 3
                }
            } ?? false
            paragraph.alignment = centred ? .center : rightToLeft ? .right : .natural
            paragraph.lineBreakMode = multiLine ? .byWordWrapping : .byClipping
            var styled = attributes
            styled[.font] = fitted
            styled[.paragraphStyle] = paragraph
            let top = node.lines?.first.map { $0.position.y - font.ascender } ?? 0
            if multiLine {
                (displayText as NSString).draw(in: CGRect(x: 0, y: top, width: node.width, height: node.height * 2 + size),
                                               withAttributes: styled)
            } else {
                let width = (displayText as NSString).size(withAttributes: styled).width
                // Keep the design baseline, centred on the original line box.
                let y = top + (font.ascender - fitted.ascender)
                // A design line that starts inside its box was centred; keep it centred.
                let startX = node.lines?.first?.position.x ?? 0
                let x = rightToLeft && width < node.width ? node.width - width
                    : startX > 0.5 ? max(0, (node.width - width) / 2) : startX
                (displayText as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: styled)
            }
        } else { (text as NSString).draw(at: .zero, withAttributes: attributes) }
    }
}
