import SwiftUI

/// The 131 vector drawables shipped in the Android APK, decoded from
/// `Resources/Assets/app/vectors.json` (flattened paths with composed transforms).
/// Base tables name them in their `icon` field, e.g. `ic_condition_bathing`.
final class AndroidVectors: @unchecked Sendable {
    static let shared = AndroidVectors()

    struct Paint: Decodable { let hex: String; let a: Double }
    struct PathSpec: Decodable {
        let d: String
        let fill: Paint?
        let stroke: Paint?
        let fillAlpha: Double
        let strokeAlpha: Double
        let strokeWidth: Double
        let evenOdd: Bool
        let matrix: [Double]
    }
    struct Vector: Decodable { let name: String; let viewport: [Double]; let paths: [PathSpec] }

    private let vectors: [String: Vector]
    private var cache: [String: [(Path, PathSpec)]] = [:]
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.main.url(forResource: "vectors", withExtension: "json", subdirectory: "Assets/app"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Vector].self, from: data) else {
            vectors = [:]; return
        }
        vectors = decoded
    }

    func vector(_ name: String) -> Vector? { vectors[name] }

    /// Decoded, transformed paths; parsed once per icon.
    func paths(_ name: String) -> [(Path, PathSpec)] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let vector = vectors[name] else { return [] }
        let built = vector.paths.map { spec -> (Path, PathSpec) in
            let m = spec.matrix
            let transform = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            return (AndroidPathParser.parse(spec.d).applying(transform), spec)
        }
        cache[name] = built
        return built
    }
}

/// A full SVG/Android path-data parser: M L H V C S Q T A Z in both cases, with
/// reflected control points for S/T and compact arc flags (`a4,4 0 01 2,2`).
enum AndroidPathParser {
    static func parse(_ d: String) -> Path {
        var scanner = Tokens(Array(d.utf8))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while let next = scanner.peekCommandOrNumber() {
            if case .command(let c) = next { command = c; scanner.advance() }
            else if command == 0 { break }
            let relative = command >= 97
            let op = relative ? command - 32 : command
            func pt() -> CGPoint {
                let x = scanner.number(), y = scanner.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch op {
            case 77: // M
                current = pt(); start = current; path.move(to: current)
                command = relative ? 108 : 76 // subsequent pairs are lineto
                lastControl = nil
            case 76: current = pt(); path.addLine(to: current); lastControl = nil
            case 72:
                let x = scanner.number(); current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case 86:
                let y = scanner.number(); current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case 67:
                let c1 = pt(), c2 = pt(), end = pt()
                path.addCurve(to: end, control1: c1, control2: c2); lastControl = c2; current = end
            case 83:
                let reflected = (lastCommand == 67 || lastCommand == 83) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let c2 = pt(), end = pt()
                path.addCurve(to: end, control1: reflected, control2: c2); lastControl = c2; current = end
            case 81:
                let c = pt(), end = pt()
                path.addQuadCurve(to: end, control: c); lastControl = c; current = end
            case 84:
                let reflected = (lastCommand == 81 || lastCommand == 84) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let end = pt()
                path.addQuadCurve(to: end, control: reflected); lastControl = reflected; current = end
            case 65:
                let rx = scanner.number(), ry = scanner.number(), rot = scanner.number()
                let large = scanner.flag(), sweep = scanner.flag()
                let end = pt()
                arc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                current = end; lastControl = nil
            case 90:
                path.closeSubpath(); current = start; lastControl = nil
            default:
                scanner.advance()
            }
            lastCommand = op
            if op == 90 { command = 0 }
        }
        return path
    }

    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double,
                            rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large != sweep ? 1 : -1) * sqrt(num / den)
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cp * cx1 - sp * cy1 + (p0.x + p1.x) / 2
        let cy = sp * cx1 + cp * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step, alpha = 4.0 / 3.0 * tan(step / 4)
            func pointAt(_ a: Double) -> CGPoint {
                CGPoint(x: cx + rx * cos(a) * cp - ry * sin(a) * sp, y: cy + rx * cos(a) * sp + ry * sin(a) * cp)
            }
            func derivative(_ a: Double) -> CGPoint {
                CGPoint(x: -rx * sin(a) * cp - ry * cos(a) * sp, y: -rx * sin(a) * sp + ry * cos(a) * cp)
            }
            let q1 = pointAt(t), q2 = pointAt(t2), d1 = derivative(t), d2 = derivative(t2)
            path.addCurve(to: q2,
                          control1: CGPoint(x: q1.x + alpha * d1.x, y: q1.y + alpha * d1.y),
                          control2: CGPoint(x: q2.x - alpha * d2.x, y: q2.y - alpha * d2.y))
            t = t2
        }
    }

    /// Byte-level tokenizer; handles "1.5.5" (two numbers), "-1-2", exponents and flags.
    struct Tokens {
        enum Token { case command(UInt8); case number }
        let bytes: [UInt8]; var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 10 || bytes[i] == 13 || bytes[i] == 9 { i += 1 }
        }
        mutating func peekCommandOrNumber() -> Token? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122), b != 101, b != 69 { return .command(b) }
            return .number
        }
        mutating func advance() { i += 1 }
        mutating func flag() -> Bool {
            skipSeparators()
            guard i < bytes.count else { return false }
            let on = bytes[i] == 49; i += 1; return on
        }
        mutating func number() -> Double {
            skipSeparators()
            let start = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            var seenDot = false, seenExp = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 48 && b <= 57 { i += 1 }
                else if b == 46 && !seenDot && !seenExp { seenDot = true; i += 1 }
                else if (b == 101 || b == 69) && !seenExp {
                    seenExp = true; i += 1
                    if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                } else { break }
            }
            return Double(String(decoding: bytes[start..<i], as: UTF8.self)) ?? 0
        }
    }
}

/// An Android product icon. With `tint`, it is drawn as a single colour (Android
/// tints its monochrome vectors at runtime); without, multi-colour art renders as
/// authored. Raster assets (`bg_*`, `client_*`, `header_*`, `logo`) load as images.
struct AppIcon: View {
    let name: String?
    var size: CGFloat = 24
    var tint: Color? = nil

    var body: some View {
        if let name, let vector = AndroidVectors.shared.vector(name) {
            Canvas { context, canvasSize in
                let vw = vector.viewport[0], vh = vector.viewport[1]
                let scale = min(canvasSize.width / vw, canvasSize.height / vh)
                let dx = (canvasSize.width - vw * scale) / 2, dy = (canvasSize.height - vh * scale) / 2
                context.translateBy(x: dx, y: dy)
                context.scaleBy(x: scale, y: scale)
                for (path, spec) in AndroidVectors.shared.paths(name) {
                    if let fill = spec.fill {
                        let colour = tint ?? Color(hexString: fill.hex).opacity(fill.a * spec.fillAlpha)
                        context.fill(path, with: .color(colour), style: FillStyle(eoFill: spec.evenOdd))
                    }
                    if let stroke = spec.stroke, spec.strokeWidth > 0 {
                        let colour = tint ?? Color(hexString: stroke.hex).opacity(stroke.a * spec.strokeAlpha)
                        context.stroke(path, with: .color(colour), lineWidth: spec.strokeWidth)
                    }
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else if let name, let image = AppImage.load(name) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// Raster product art extracted from the APK (hero photos, care-type art, logo).
enum AppImage {
    private static var cache = NSCache<NSString, UIImage>()
    static func load(_ name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "Assets/app"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(hex: value)
    }
}
