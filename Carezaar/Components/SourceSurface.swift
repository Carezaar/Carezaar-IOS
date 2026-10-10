import SwiftUI

struct SourceSurface: View {
    let node: DesignNode
    var body: some View {
        surface
            // Fills and pictures are decoration; the frame's text nodes carry the content.
            .accessibilityHidden(true)
    }

    private var surface: some View {
        ZStack {
            node.color
            if let paint = node.fills.first(where: { $0.stops != nil }), let stops = paint.stops {
                LinearGradient(stops: stops.map { Gradient.Stop(color: Color(source: $0.color), location: $0.position) }, startPoint: paint.gradientEndpoints.0, endPoint: paint.gradientEndpoints.1)
            }
            if let image = node.fills.first(where: { $0.asset != nil }), let name = image.asset,
               let url = SourceStore.assetURL(name), let uiImage = UIImage(contentsOfFile: url.path) {
                SourceImage(image: uiImage, paint: image, width: node.width, height: node.height)
            }
        }
        .clipShape(SourceOutline(ellipse: node.kind == "ellipse", radius: node.radius, corners: node.corners))
        .overlay { SourceOutline(ellipse: node.kind == "ellipse", radius: node.radius, corners: node.corners).inset(by: node.strokeAlign == "OUTSIDE" ? -node.strokeWidth : node.strokeAlign == "CENTER" ? -node.strokeWidth / 2 : 0).strokeBorder(node.strokeColor, style: StrokeStyle(lineWidth: node.strokeWidth, dash: (node.strokeDashes ?? []).map { CGFloat($0) })) }
        .overlay { ForEach(Array(node.effects.filter { $0.type == "INNER_SHADOW" }.enumerated()), id: \.offset) { _, effect in SourceInnerShadow(node: node, effect: effect) } }
        .modifier(SourceShadows(effects: node.effects))
    }
}
struct SourceOutline: InsettableShape {
    let ellipse: Bool
    let radius: Double
    var corners: [Double]? = nil
    var insetAmount: Double = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if let c = corners, !ellipse { return UnevenRoundedRectangle(topLeadingRadius: max(0,c[0]-insetAmount), bottomLeadingRadius: max(0,c[3]-insetAmount), bottomTrailingRadius: max(0,c[2]-insetAmount), topTrailingRadius: max(0,c[1]-insetAmount)).path(in: r) }
        return ellipse ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: max(0, radius - insetAmount))
    }
    func inset(by amount: CGFloat) -> Self { var copy = self; copy.insetAmount += amount; return copy }
}
struct SourceShadows: ViewModifier {
    let effects: [DesignEffect]
    func body(content: Content) -> some View {
        effects.filter { $0.type == "DROP_SHADOW" }.reduce(AnyView(content)) { view, effect in
            AnyView(view.shadow(color: Color(source: effect.color), radius: effect.radius / 2, x: effect.offset.x, y: effect.offset.y))
        }
    }
}

struct SourceImage: View {
    let image: UIImage
    let paint: DesignPaint
    let width, height: Double
    var body: some View {
        Group {
            if (paint.mode == "STRETCH" || paint.mode == "CROP"), let t = paint.transform {
                let normalized = CGAffineTransform(a: t["m00"] ?? 1, b: t["m10"] ?? 0, c: t["m01"] ?? 0, d: t["m11"] ?? 1, tx: t["m02"] ?? 0, ty: t["m12"] ?? 0).inverted()
                Image(uiImage: image).resizable().frame(width: width, height: height)
                    .transformEffect(CGAffineTransform(a: normalized.a, b: normalized.b * height / max(width,1), c: normalized.c * width / max(height,1), d: normalized.d, tx: normalized.tx * width, ty: normalized.ty * height))
            } else {
                Image(uiImage: image).resizable().aspectRatio(contentMode: paint.mode == "FIT" ? .fit : .fill)
                    .frame(width: width, height: height)
            }
        }.frame(width: width, height: height).clipped().opacity(paint.opacity ?? 1)
    }
}

struct SourceInnerShadow: View {
    let node: DesignNode
    let effect: DesignEffect
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let outline = SourceOutline(ellipse: node.kind == "ellipse", radius: node.radius, corners: node.corners)
            context.clip(to: outline.path(in: rect))
            let padding = effect.radius * 3 + abs(effect.offset.x) + abs(effect.offset.y) + 32
            var inverse = Path(rect.insetBy(dx: -padding, dy: -padding))
            inverse.addPath(outline.inset(by: effect.spread).path(in: rect))
            context.addFilter(.shadow(color: Color(source: effect.color), radius: effect.radius / 2, x: effect.offset.x, y: effect.offset.y, options: .shadowOnly))
            context.fill(inverse, with: .color(.black), style: FillStyle(eoFill: true))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
