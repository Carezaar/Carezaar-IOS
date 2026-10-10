import SwiftUI

struct DesignNode: Decodable, Identifiable {
    let id: String
    let key: String?
    let name: String
    let kind: String
    var width, height, x, y: Double
    let matrix: [Double]
    let opacity: Double
    let clip: Bool
    let radius: Double
    let corners: [Double]?
    let textCase, textTruncation: String?
    let strokeDashes: [Double]?
    let actionTarget, stateTarget, inputType, inputValue, selectionGroup, strokeAlign, strokeCap: String?
    let fills, strokes: [DesignPaint]
    let strokeWidth: Double
    var children: [DesignNode]
    var text: String?
    /// Set when a `SceneBinder` replaced this node's copy (localisation or a
    /// validation message). Glyph outlines and measured line ranges belong to the
    /// original string, so both must be bypassed when it changes.
    var isTextSubstituted: Bool?
    let fontSize: Double?
    let fontFamily: String?
    let fontWeight: Double?
    let lines: [SourceLine]?
    let path: String?
    let pathWidth, pathHeight: Double?
    let glyphPaths, fillPaths, strokePaths: [VectorPath]?
    let effects: [DesignEffect]
    var color: Color { fills.first(where: { $0.color != nil })?.swiftColor ?? .clear }
    var strokeColor: Color { strokes.first(where: { $0.color != nil })?.swiftColor ?? .clear }
    var label: String { text ?? children.map(\.label).filter { !$0.isEmpty }.joined(separator: " ") }
}
struct SourcePoint: Decodable { let x, y: Double }
struct SourceLine: Decodable { let position: SourcePoint; let firstCharacter, endCharacter: Int; let lineHeight, lineY: Double; let width: Double? }
struct VectorPath: Decodable { let d, rule: String; let color: [Double]? }
struct DesignEffect: Decodable { let type: String; let radius, spread: Double; let offset: SourcePoint; let color: [Double] }
struct DesignPaint: Decodable {
    let type: String
    let color: [Double]?
    let asset, mode: String?
    let opacity: Double?
    let stops: [GradientStop]?
    let transform: [String: Double]?
    var swiftColor: Color { Color(source: color) }
}
struct GradientStop: Decodable { let position: Double; let color: [Double] }
extension Color {
    init(source: [Double]?) {
        let c = source ?? [0, 0, 0, 0]
        self.init(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
    }
}
struct ScreenRecord: Decodable, Identifiable {
    let key, name, page, node: String
    let width, height: Double
    var id: String { key }
}
enum SourceStore {
    static func load<T: Decodable>(_ name: String, folder: String? = nil) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    static func assetURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Assets")
    }
}

extension DesignPaint {
    var gradientEndpoints: (UnitPoint, UnitPoint) {
        guard let t = transform else { return (.leading, .trailing) }
        let matrix = CGAffineTransform(a: t["m00"] ?? 1, b: t["m10"] ?? 0, c: t["m01"] ?? 0, d: t["m11"] ?? 1, tx: t["m02"] ?? 0, ty: t["m12"] ?? 0).inverted()
        let a = CGPoint(x: 0, y: 0.5).applying(matrix), b = CGPoint(x: 1, y: 0.5).applying(matrix)
        return (UnitPoint(x: a.x, y: a.y), UnitPoint(x: b.x, y: b.y))
    }
}

extension DesignNode {
    var sourceFont: UIFont {
        let suffixes: [Int: String] = [100: "_Thin", 200: "_ExtraLight", 300: "_Light", 400: "", 500: "_Medium", 600: "_SemiBold", 700: "_Bold", 800: "_ExtraBold", 900: "_Black"]
        let name = fontFamily == "Arial" ? ((fontWeight ?? 400) >= 600 ? "Arial-BoldMT" : "ArialMT") : "Vazirmatn-Regular" + (suffixes[Int(fontWeight ?? 400)] ?? "")
        return UIFont(name: name, size: fontSize ?? 14) ?? .systemFont(ofSize: fontSize ?? 14)
    }
    var displayText: String {
        let value = text ?? ""
        return textCase == "TITLE" ? value.capitalized : textCase == "UPPER" ? value.uppercased() : value
    }
}

/// Current editable Figma palette; individual legacy scenes preserve their source values.
enum DesignTokens {
    static let primary = Color(source: [0, 122.0 / 255, 254.0 / 255, 1])
    static let muted = Color(source: [127.0 / 255, 127.0 / 255, 127.0 / 255, 1])
    static let screenInset = 20.0
    static let bodySize = 14.0
}
