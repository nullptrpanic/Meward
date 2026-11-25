import ImageIO
import UIKit

enum PhotoError: LocalizedError {
    case unreadable, render, write, noEdits, albumDenied, cameraUnavailable, cameraDenied

    var errorDescription: String? {
        switch self {
        case .unreadable: "Couldn’t open this photo. Choose one that’s downloaded to your device."
        case .render: "Couldn’t process this photo. Try another photo."
        case .write: "Couldn’t write the edited copy. Check the available storage on your device."
        case .noEdits: "Add a watermark or a cover first."
        case .albumDenied: "To save a copy, allow Meward to add photos in Settings."
        case .cameraUnavailable: "No camera is available. Choose a photo from your library."
        case .cameraDenied: "To take a photo, allow Meward to use the camera in Settings."
        }
    }
}

struct EditorPhoto {
    private enum Original {
        case encoded(Data)
        case camera(CGImage)
    }

    let id = UUID()
    let name: String
    let size: CGSize
    let thumbnail: CGImage
    private let original: Original
    private let orientation: UIImage.Orientation
    private let tones: [UInt8]
    private static let thumbnailLimit = 1280

    init(data: Data, name: String) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PhotoError.unreadable }
        let orientation = UIImage.Orientation(exif: properties[kCGImagePropertyOrientation] as? UInt32 ?? 1)
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceShouldCacheImmediately: true,
                                                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.thumbnailLimit)]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { throw PhotoError.unreadable }
        self.name = name
        self.orientation = orientation
        self.size = orientation.size(width: width, height: height)
        self.original = .encoded(data)
        self.thumbnail = thumbnail
        self.tones = try Self.luminanceMap(thumbnail)
    }

    init(capture image: UIImage) throws {
        guard let bitmap = image.cgImage else { throw PhotoError.unreadable }
        name = "Captured photo"
        original = .camera(bitmap)
        orientation = image.imageOrientation
        size = orientation.size(width: bitmap.width, height: bitmap.height)
        let ratio = min(1, CGFloat(Self.thumbnailLimit) / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * ratio).rounded()), height: max(1, (size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let thumbnail = scaled.cgImage else { throw PhotoError.render }
        self.thumbnail = thumbnail
        self.tones = try Self.luminanceMap(thumbnail)
    }

    func fullImage() throws -> UIImage {
        let bitmap: CGImage
        switch original {
        case .camera(let captured):
            bitmap = captured
        case .encoded(let data):
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw PhotoError.unreadable }
            bitmap = original
        }
        return UIImage(cgImage: bitmap, scale: 1, orientation: orientation)
    }

    // A shared upright brightness map keeps the text color identical in previews and exports.
    func isLight(at point: CGPoint, in canvas: CGSize) -> Bool {
        let x = min(23, max(0, Int(point.x / canvas.width * 24)))
        let y = min(23, max(0, Int(point.y / canvas.height * 24)))
        var total = 0, count = 0
        for row in max(0, y-1)...min(23, y+1) {
            for column in max(0, x-1)...min(23, x+1) {
                total += Int(tones[row * 24 + column])
                count += 1
            }
        }
        return total >= 146 * count
    }

    private static func luminanceMap(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: 24 * 24)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 24, height: 24, bitsPerComponent: 8,
                                          bytesPerRow: 24, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PhotoError.render }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return bytes
    }
}

extension UIImage.Orientation {
    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    init(exif: UInt32) {
        switch exif {
        case 2: self = .upMirrored
        case 3: self = .down
        case 4: self = .downMirrored
        case 5: self = .leftMirrored
        case 6: self = .right
        case 7: self = .rightMirrored
        case 8: self = .left
        default: self = .up
        }
    }

    func size(width: Int, height: Int) -> CGSize {
        switch self {
        case .right, .rightMirrored, .left, .leftMirrored: CGSize(width: height, height: width)
        default: CGSize(width: width, height: height)
        }
    }
}
