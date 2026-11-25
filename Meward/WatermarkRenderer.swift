import ImageIO
import UIKit
import UniformTypeIdentifiers

enum WatermarkPosition: String, CaseIterable {
    case tile, center
    case topLeft = "top-left", topRight = "top-right"
    case bottomLeft = "bottom-left", bottomRight = "bottom-right"

    var label: String {
        switch self {
        case .tile: "Tile"
        case .center: "Center"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    var anchor: CGPoint {
        switch self {
        case .tile, .center: CGPoint(x: 0.5, y: 0.5)
        case .topLeft: .zero
        case .topRight: CGPoint(x: 1, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }
}

struct Watermark: Hashable {
    static let defaultTileAngle = 13.0
    static let defaultTileOpacity = 46.0

    var text = ""
    var position = WatermarkPosition.tile
    var tileAngle = defaultTileAngle
    // Express opacity as a percentage, as shown in the editor.
    var tileOpacity = defaultTileOpacity
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class WatermarkedFile {
    let url: URL

    init() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meward-Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("Meward.png")
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

enum WatermarkRenderer {
    static func preview(_ photo: EditorPhoto, mark: Watermark, covers: [Redaction] = []) throws -> CGImage {
        if mark.trimmedText.isEmpty && covers.isEmpty { return photo.thumbnail }
        let image = UIImage(cgImage: photo.thumbnail)
        return try render(photo, image: image, size: image.size, mark: mark, covers: covers)
    }

    // In the editor the covers can move under this transparent layer during a drag.
    static func watermarkLayer(_ photo: EditorPhoto, mark: Watermark, covers: [Redaction]) throws -> CGImage {
        let image = UIImage(cgImage: photo.thumbnail)
        return try render(photo, image: image, size: image.size, mark: mark, covers: covers, layerOnly: true)
    }

    static func export(_ photo: EditorPhoto, mark: Watermark, covers: [Redaction] = []) throws -> WatermarkedFile {
        guard !mark.trimmedText.isEmpty || !covers.isEmpty else { throw PhotoError.noEdits }
        let image = try render(photo, image: photo.fullImage(), size: photo.size, mark: mark, covers: covers)
        let file = try WatermarkedFile()
        guard let destination = CGImageDestinationCreateWithURL(file.url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PhotoError.write }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.write }
        return file
    }

    private static func render(_ photo: EditorPhoto, image: UIImage, size: CGSize, mark: Watermark,
                               covers: [Redaction], layerOnly: Bool = false) throws -> CGImage {
        guard let original = image.cgImage else { throw PhotoError.render }
        let rgb = original.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let depth = original.bitsPerComponent > 8 ? 16 : 8
        let byteOrder: CGBitmapInfo = depth == 16 ? .byteOrder16Little : .byteOrder32Big
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: depth, bytesPerRow: 0, space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | byteOrder.rawValue)
        else { throw PhotoError.render }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let bounds = CGRect(origin: .zero, size: size)
        if layerOnly {
            context.clear(bounds)
        } else {
            image.draw(in: bounds, blendMode: .copy, alpha: 1)
            context.saveGState()
            context.setBlendMode(.copy)
            context.setShouldAntialias(false)
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            for cover in covers {
                let pixels = cover.rect.applying(CGAffineTransform(scaleX: size.width, y: size.height)).integral
                context.fill(pixels)
            }
            context.restoreGState()
        }

        // Lay out text once in the same coordinate system at either rendering resolution.
        if !mark.trimmedText.isEmpty {
            context.saveGState()
            let units = 720 / min(photo.size.width, photo.size.height)
            let canvas = CGSize(width: photo.size.width * units, height: photo.size.height * units)
            context.scaleBy(x: size.width / canvas.width, y: size.height / canvas.height)
            draw(mark, on: photo, in: canvas, covers: covers, context: context)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw PhotoError.render }
        return result
    }

    private static func draw(_ mark: Watermark, on photo: EditorPhoto, in size: CGSize, covers: [Redaction], context: CGContext) {
        let tiled = mark.position == .tile
        let side = min(size.width, size.height)
        let inset = side * 0.065
        let maxWidth = tiled ? size.width * 0.5 : size.width - 2 * inset
        let maxHeight = tiled ? size.height * 0.22 : size.height - 2 * inset
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let text = mark.trimmedText as NSString
        var fontSize = side * (tiled ? 0.047 : 0.063)
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        var bounds: CGRect
        repeat {
            attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: options, attributes: attributes, context: nil).integral
            if bounds.height <= maxHeight || fontSize < 1 { break }
            fontSize *= min(0.8, sqrt(maxHeight / bounds.height))
        } while true
        let block = CGSize(width: min(maxWidth, bounds.width + 1), height: bounds.height)
        let rect = CGRect(x: -block.width / 2, y: -block.height / 2, width: block.width, height: block.height)
        let angle = CGFloat(mark.tileAngle) * .pi / 180
        let opacity: CGFloat = tiled ? CGFloat(mark.tileOpacity / 100) : 0.78

        func stamp(at point: CGPoint) {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            if tiled { context.rotate(by: -angle) }
            let anchor = CGPoint(x: point.x / size.width, y: point.y / size.height)
            let covered = covers.contains { $0.rect.contains(anchor) }
            let shade: CGFloat = !covered && photo.isLight(at: point, in: size) ? 0.14 : 1
            attributes[.foregroundColor] = UIColor(white: shade, alpha: opacity)
            text.draw(with: rect, options: options, attributes: attributes, context: nil)
            context.restoreGState()
        }

        if tiled {
            let width = block.width * cos(angle) + block.height * sin(angle)
            let height = block.width * sin(angle) + block.height * cos(angle)
            let stepX = max(size.width * 0.36, width + side * 0.12)
            let stepY = max(size.height * 0.205, side * 0.245, height + side * 0.055)
            for (row, y) in stride(from: stepY * 0.4, to: size.height + height / 2, by: stepY).enumerated() {
                let start = stepX * (row.isMultiple(of: 2) ? 0.25 : -0.25)
                for x in stride(from: start, to: size.width + width / 2, by: stepX) {
                    stamp(at: CGPoint(x: x, y: y))
                }
            }
        } else {
            let anchor = mark.position.anchor
            stamp(at: CGPoint(x: inset + block.width / 2 + anchor.x * (size.width - inset * 2 - block.width),
                              y: inset + block.height / 2 + anchor.y * (size.height - inset * 2 - block.height)))
        }
    }
}
