import SwiftUI

/// Square crop after choosing a photo, as Android does before upload. Pinch to zoom,
/// drag to position; the square always stays covered. Output is an 800×800 JPEG,
/// which also normalises HEIC library photos to the `image/jpeg` the upload declares.
struct PhotoCropper: View {
    let image: UIImage
    let onDone: (Data) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var loc: Localization
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let source: UIImage

    init(image: UIImage, onDone: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.image = image; self.onDone = onDone; self.onCancel = onCancel
        // Bake in the EXIF orientation so the maths below works in pixel space.
        source = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    /// This cover can be laid out with a zero top inset; keep the controls below the
    /// status bar using the window's real inset.
    private var windowTopInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { outer in
            content.padding(.top, max(0, windowTopInset - outer.safeAreaInsets.top))
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Button(loc.t("general_cancel", "Cancel"), action: onCancel)
                Spacer()
                Button(loc.t("general_confirm", "Confirm")) { confirm() }
                    .fontWeight(.semibold)
            }
            .font(Theme.Typography.control(17)).foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .zIndex(1)
            cropArea
        }
    }

    private var cropArea: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 40
            let base = side / min(source.size.width, source.size.height)
            let scale = base * zoom
            let shown = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            ZStack {
                Image(uiImage: source).resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                // Dim everything outside the square.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side))
                }
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().stroke(.white, lineWidth: 2).frame(width: side, height: side).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onAppear { geometry = (side, scale, shown) }
            .onChange(of: scale) { _, _ in geometry = (side, scale, shown) }
            .onChange(of: geo.size) { _, _ in geometry = (side, scale, shown) }
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { zoom = max(1, min(4, committedZoom * $0)) }
                        .onEnded { _ in committedZoom = zoom; offset = clamp(offset, side: side, shown: currentShown(side)); committedOffset = offset },
                    DragGesture()
                        .onChanged { g in
                            offset = clamp(CGSize(width: committedOffset.width + g.translation.width,
                                                  height: committedOffset.height + g.translation.height),
                                           side: side, shown: shown)
                        }
                        .onEnded { _ in committedOffset = offset }
                )
            )
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    @State private var geometry: (side: CGFloat, scale: CGFloat, shown: CGSize) = (0, 1, .zero)

    private func confirm() {
        onDone(crop(side: geometry.side, scale: geometry.scale, shown: geometry.shown))
    }

    private func currentShown(_ side: CGFloat) -> CGSize {
        let s = side / min(source.size.width, source.size.height) * zoom
        return CGSize(width: source.size.width * s, height: source.size.height * s)
    }

    /// Keeps the image edges outside the crop square.
    private func clamp(_ o: CGSize, side: CGFloat, shown: CGSize) -> CGSize {
        let maxX = max(0, (shown.width - side) / 2), maxY = max(0, (shown.height - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    private func crop(side: CGFloat, scale: CGFloat, shown: CGSize) -> Data {
        let x = (shown.width / 2 - side / 2 - offset.width) / scale
        let y = (shown.height / 2 - side / 2 - offset.height) / scale
        let length = side / scale
        let output: CGFloat = 800
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let cropped = renderer.image { _ in
            let k = output / length
            source.draw(in: CGRect(x: -x * k, y: -y * k, width: source.size.width * k, height: source.size.height * k))
        }
        return cropped.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
