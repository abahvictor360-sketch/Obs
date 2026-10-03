// Core Image compositor: under layer + live screen + over layer -> one BGRA
// frame for the encoder. Shared by the app and the broadcast extension.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

enum ScreenFit: UInt8 {
    case contain = 0
    case cover = 1
    case stretch = 2

    init(name: String) {
        switch name {
        case "cover": self = .cover
        case "stretch": self = .stretch
        default: self = .contain
        }
    }
}

/// Screen rect in output pixels with a top-left origin (like Flutter).
/// Rotation is clockwise in degrees around the rect center.
struct ScreenPlacement {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat
    var fit: ScreenFit

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rotation: CGFloat, fit: ScreenFit) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.fit = fit
    }

    init(map: [String: Any]?) {
        func f(_ k: String) -> CGFloat { CGFloat((map?[k] as? NSNumber)?.doubleValue ?? 0) }
        self.init(
            x: f("x"), y: f("y"), width: f("w"), height: f("h"), rotation: f("rotation"),
            fit: ScreenFit(name: map?["fit"] as? String ?? "contain")
        )
    }
}

final class Compositor {
    let width: Int
    let height: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// RGBA (premultiplied, as produced by Flutter's toByteData) -> CGImage.
    static func cgImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func ciImage(rgba: Data, width: Int, height: Int) -> CIImage? {
        cgImage(rgba: rgba, width: width, height: height).map { CIImage(cgImage: $0) }
    }

    func render(
        to pixelBuffer: CVPixelBuffer,
        under: CIImage?,
        screen: CIImage?,
        placement: ScreenPlacement?,
        over: CIImage?
    ) {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(color: CIColor.black).cropped(to: full)
        if let u = under { image = fill(u).composited(over: image) }
        if let s = screen, let p = placement, let placed = place(s, p) {
            image = placed.composited(over: image)
        }
        if let o = over { image = fill(o).composited(over: image) }
        context.render(image, to: pixelBuffer, bounds: full, colorSpace: colorSpace)
    }

    /// Scales a full-frame layer to exactly the output size.
    private func fill(_ img: CIImage) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        return img
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
    }

    private func place(_ screen: CIImage, _ p: ScreenPlacement) -> CIImage? {
        let e = screen.extent
        guard p.width > 0, p.height > 0, e.width > 0, e.height > 0 else { return nil }
        var sx = p.width / e.width
        var sy = p.height / e.height
        switch p.fit {
        case .contain:
            let k = min(sx, sy)
            sx = k
            sy = k
        case .cover:
            let k = max(sx, sy)
            sx = k
            sy = k
        case .stretch:
            break
        }
        // Center on the origin, scale, clip to the box, rotate, then move to
        // the box center. Core Image is y-up, Flutter is y-down: flip y and
        // turn clockwise rotation into a negative angle.
        let cx = p.x + p.width / 2
        let cy = CGFloat(height) - (p.y + p.height / 2)
        return screen
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: -p.width / 2, y: -p.height / 2, width: p.width, height: p.height))
            .transformed(by: CGAffineTransform(rotationAngle: -p.rotation * .pi / 180))
            .transformed(by: CGAffineTransform(translationX: cx, y: cy))
    }
}
