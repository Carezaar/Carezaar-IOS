import SwiftUI

/// Figma path commands are converted to native paths; no web view or rasterized screen is used.
struct SourceVector: View {
    let node: DesignNode
    private var fill: GraphicsContext.Shading {
        if let paint = node.fills.first(where: { $0.stops != nil }), let stops = paint.stops {
            return .linearGradient(Gradient(stops: stops.map { Gradient.Stop(color: Color(source: $0.color), location: $0.position) }), startPoint: CGPoint(x: paint.gradientEndpoints.0.x * node.width, y: paint.gradientEndpoints.0.y * node.height), endPoint: CGPoint(x: paint.gradientEndpoints.1.x * node.width, y: paint.gradientEndpoints.1.y * node.height))
        }
        return .color(node.color)
    }
    var body: some View {
        Canvas { context, _ in
            if node.kind == "line" {
                var line = Path(); line.move(to: .zero); line.addLine(to: CGPoint(x: node.width, y: 0))
                context.stroke(line, with: .color(node.strokeColor), style: StrokeStyle(lineWidth: node.strokeWidth, lineCap: node.strokeCap == "ROUND" ? .round : .butt))
            } else if !(node.fillPaths ?? []).isEmpty || !(node.strokePaths ?? []).isEmpty {
                for source in node.fillPaths ?? [] {
                    context.fill(SVGPath.decode(source.d), with: fill, style: FillStyle(eoFill: source.rule == "ODD"))
                }
                for source in node.strokePaths ?? [] {
                    context.fill(SVGPath.decode(source.d), with: .color(node.strokeColor), style: FillStyle(eoFill: source.rule == "ODD"))
                }
            } else if let source = node.path {
                let transform = CGAffineTransform(scaleX: node.width / max(node.pathWidth ?? node.width, 0.001), y: node.height / max(node.pathHeight ?? node.height, 0.001))
                let path = SVGPath.decode(source).applying(transform)
                if let paint = node.fills.first(where: { $0.stops != nil }), let stops = paint.stops {
                    context.fill(path, with: .linearGradient(Gradient(stops: stops.map { Gradient.Stop(color: Color(source: $0.color), location: $0.position) }), startPoint: CGPoint(x: paint.gradientEndpoints.0.x * node.width, y: paint.gradientEndpoints.0.y * node.height), endPoint: CGPoint(x: paint.gradientEndpoints.1.x * node.width, y: paint.gradientEndpoints.1.y * node.height)))
                } else { context.fill(path, with: .color(node.color)) }
                if !node.strokes.isEmpty { context.stroke(path, with: .color(node.strokeColor), style: StrokeStyle(lineWidth: node.strokeWidth, lineCap: .round, lineJoin: .round)) }
            }
        }
        .frame(width: max(1, node.width), height: max(1, node.height))
        .accessibilityHidden(true)
    }
}
/// Supports the SVG command subset used by extracted and reconstructed source icons.
enum SVGPath {
    static func decode(_ source: String) -> Path {
        guard let regex = try? NSRegularExpression(pattern: "[MLCQAZHVmlcqazhv]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?") else { return Path() }
        let ns = source as NSString
        let tokens = regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var path = Path(), index = 0, command = "M"
        func number() -> Double { defer { index += 1 }; return index < tokens.count ? Double(tokens[index]) ?? 0 : 0 }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
            let relative = command == command.lowercased()
            let start = path.currentPoint ?? .zero
            func point() -> CGPoint {
                let x = number(), y = number()
                return CGPoint(x: x + (relative ? start.x : 0), y: y + (relative ? start.y : 0))
            }
            switch command.uppercased() {
            case "M": path.move(to: point()); command = relative ? "l" : "L"
            case "L": path.addLine(to: point())
            case "H": path.addLine(to: CGPoint(x: number() + (relative ? start.x : 0), y: start.y))
            case "V": path.addLine(to: CGPoint(x: start.x, y: number() + (relative ? start.y : 0)))
            case "C": let a = point(), b = point(), end = point(); path.addCurve(to: end, control1: a, control2: b)
            case "Q": let control = point(), end = point(); path.addQuadCurve(to: end, control: control)
            case "A":
                let rx = number(), ry = number(), rotation = number(), large = number() != 0, sweep = number() != 0
                let end = point()
                appendArc(to: &path, from: start, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
            case "Z": path.closeSubpath(); command = "M"
            default: index += 1
            }
        }
        return path
    }
    private static func appendArc(to path: inout Path, from start: CGPoint, to end: CGPoint, rx inputRX: Double, ry inputRY: Double, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(inputRX), ry = abs(inputRY)
        guard rx > 0, ry > 0, start != end else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let px = cosPhi * dx + sinPhi * dy, py = -sinPhi * dx + cosPhi * dy
        let ratio = px * px / (rx * rx) + py * py / (ry * ry)
        if ratio > 1 { rx *= sqrt(ratio); ry *= sqrt(ratio) }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px)
        let denominator = rx * rx * py * py + ry * ry * px * px
        let factor = (large == sweep ? -1.0 : 1.0) * sqrt(numerator / max(denominator, 0.00000001))
        let cxp = factor * rx * py / ry, cyp = -factor * ry * px / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2
        let theta = atan2((py - cyp) / ry, (px - cxp) / rx)
        var delta = atan2((-py - cyp) / ry, (-px - cxp) / rx) - theta
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let count = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(count)
        func location(_ a: Double) -> CGPoint { CGPoint(x: cx + rx * cosPhi * cos(a) - ry * sinPhi * sin(a), y: cy + rx * sinPhi * cos(a) + ry * cosPhi * sin(a)) }
        func derivative(_ a: Double) -> CGPoint { CGPoint(x: -rx * cosPhi * sin(a) - ry * sinPhi * cos(a), y: -rx * sinPhi * sin(a) + ry * cosPhi * cos(a)) }
        for index in 0..<count {
            let a = theta + Double(index) * step, b = a + step, alpha = 4 / 3 * tan(step / 4)
            let p1 = location(a), p2 = location(b), d1 = derivative(a), d2 = derivative(b)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y), control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y))
        }
    }
}
