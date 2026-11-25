import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Meward

final class WatermarkTests: XCTestCase {
    func testWatermarkRemainsVisibleAboveOpaqueAutomaticAndManualCovers() throws {
        let original = try fixture(400, 300) { _, _ in (255, 255, 255, 255) }
        let photo = try EditorPhoto(capture: UIImage(cgImage: original))
        let covers = [Redaction(.identity, rect: CGRect(x: 0, y: 0, width: 0.55, height: 1)),
                      Redaction(.manual, rect: CGRect(x: 0.45, y: 0, width: 0.55, height: 1))]
        let mark = Watermark(text: "PRIVATE", position: .center)
        let file = try WatermarkRenderer.export(photo, mark: mark, covers: covers)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = pixels(output)
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 60 },
                      "The watermark must remain visible on top of the black covers.")
        XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, 255])
        XCTAssertEqual(bytes, pixels(try WatermarkRenderer.preview(photo, mark: mark, covers: covers)))
        withExtendedLifetime(file) {}
    }

    func testRedactionOnlyReplacesTransparentPixelsInOrientedFullSizePNG() throws {
        let original = try fixture(1800, 1000) { _, _ in (0, 0, 0, 0) }
        let photo = try EditorPhoto(capture: UIImage(cgImage: original, scale: 1, orientation: .right))
        let cover = Redaction(.manual, rect: CGRect(x: 0.2, y: 0.1, width: 0.25, height: 0.12))
        let mark = Watermark(text: "")
        let file = try WatermarkRenderer.export(photo, mark: mark, covers: [cover])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.width, 1000)
        XCTAssertEqual(output.height, 1800)
        for image in [try WatermarkRenderer.preview(photo, mark: mark, covers: [cover]), output] {
            let bytes = pixels(image)
            let inside = 4 * (Int(Double(image.height) * 0.15) * image.width + image.width / 3)
            XCTAssertEqual(Array(bytes[inside..<inside + 4]), [0, 0, 0, 255])
            XCTAssertEqual(bytes.last, 0)
        }
        withExtendedLifetime(file) {}
    }

    func testExportUsesOriginalPixelsAndLosslessPNG() throws {
        let width = 2400, height = 1600
        let original = try fixture(width, height) { x, y in
            (UInt8(truncatingIfNeeded: x ^ y), UInt8(truncatingIfNeeded: 7 * x), UInt8(truncatingIfNeeded: 11 * y), 255)
        }
        let input = try encode(original, as: .png)
        let photo = try EditorPhoto(data: input, name: "Pattern")
        XCTAssertLessThan(photo.thumbnail.width, width)
        let export = try WatermarkRenderer.export(photo, mark: .init(text: "本次办理使用", position: .bottomRight))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(export.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
        let before = pixels(original), after = pixels(result)
        XCTAssertTrue(before.prefix(width * height * 2).elementsEqual(after.prefix(width * height * 2)))
        XCTAssertFalse(after == before)
        withExtendedLifetime(export) {}
    }

    func testAllPositionsAreBurnedIntoTheirPartOfTheImage() throws {
        let photo = try EditorPhoto(data: encode(fixture(400, 300) { _, _ in (255,255,255,255) }, as: .png), name: "Paper")
        let placements: [(WatermarkPosition, Int)] = [(.topLeft,0),(.topRight,2),(.center,4),(.bottomLeft,6),(.bottomRight,8)]
        for (position, region) in placements {
            let output = try WatermarkRenderer.preview(photo, mark: .init(text: "M", position: position))
            XCTAssertEqual(inkRegions(output), [region], position.rawValue)
        }
        let tiled = try WatermarkRenderer.preview(photo, mark: .init(text: "个人资料", position: .tile))
        XCTAssertEqual(inkRegions(tiled), Set(0..<9))
    }

    func testTileAdjustmentsMatchExportAndLeaveSingleWatermarksAlone() throws {
        let white = try fixture(400, 300) { _, _ in (255,255,255,255) }
        let photo = try EditorPhoto(data: encode(white, as: .png), name: "Paper")
        var mark = Watermark(text: "Private", position: .tile, tileAngle: 8, tileOpacity: 12)
        let faint = pixels(try WatermarkRenderer.preview(photo, mark: mark))
        mark.tileOpacity = 55
        let darker = pixels(try WatermarkRenderer.preview(photo, mark: mark))
        XCTAssertLessThan(try XCTUnwrap(darker.min()), try XCTUnwrap(faint.min()))
        mark.tileAngle = 30
        let angled = pixels(try WatermarkRenderer.preview(photo, mark: mark))
        XCTAssertFalse(angled.elementsEqual(darker))
        let file = try WatermarkRenderer.export(photo, mark: mark)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(angled.elementsEqual(pixels(exported)))
        withExtendedLifetime(file) {}

        mark.position = .bottomRight
        let corner = pixels(try WatermarkRenderer.preview(photo, mark: mark))
        mark.tileAngle = 8
        mark.tileOpacity = 12
        XCTAssertTrue(corner.elementsEqual(pixels(try WatermarkRenderer.preview(photo, mark: mark))))
    }

    func testPickerAndCameraHonorOrientationAndAlpha() throws {
        let original = try fixture(160, 100) { x, _ in x < 80 ? (240,0,0,255) : (0,0,0,0) }
        let library = try EditorPhoto(data: encode(original, as: .tiff, orientation: 6), name: "Portrait")
        let camera = try EditorPhoto(capture: UIImage(cgImage: original, scale: 1, orientation: .right))
        for photo in [library, camera] {
            XCTAssertEqual(photo.size, CGSize(width: 100, height: 160))
            let result = try WatermarkRenderer.export(photo, mark: .init(text: "A", position: .center))
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(image.width, 100)
            XCTAssertEqual(image.height, 160)
            let data = pixels(image)
            XCTAssertEqual(Array(data[0..<4]), [240,0,0,255])
            XCTAssertEqual(Array(data.suffix(4)), [0,0,0,0])
            withExtendedLifetime(result) {}
        }
    }

    func testHighDepthDisplayP3InputKeepsItsPrecisionAndColorSpace() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 16,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(red: 0.19, green: 0.62, blue: 0.84, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let input = try encode(XCTUnwrap(context.makeImage()), as: .png)
        let photo = try EditorPhoto(data: input, name: "P3")
        let result = try WatermarkRenderer.export(photo, mark: .init(text: "用途", position: .center))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        withExtendedLifetime(result) {}
    }

    @MainActor
    func testCapturedPhotoCanShareTheSameFileAgainAndUpdatesAfterEditing() async throws {
        let editor = WatermarkEditor()
        editor.mark = Watermark(text: "仅供面试", position: .tile)
        let original = try fixture(320, 200) { _, _ in (255,255,255,255) }
        editor.acceptCapture(UIImage(cgImage: original))
        try await waitUntilIdle(editor)
        XCTAssertEqual(editor.photo?.name, "Captured photo")
        XCTAssertTrue(editor.canExport)
        XCTAssertNotNil(editor.feedback)

        func sharedFile() async throws -> WatermarkedFile {
            editor.share()
            try await waitUntilIdle(editor)
            guard case let .share(file) = editor.sheet else {
                XCTFail("Expected a watermarked file in the share sheet")
                throw PhotoError.write
            }
            editor.sheet = nil
            return file
        }
        let first = try await sharedFile()
        let again = try await sharedFile()
        XCTAssertEqual(first.url, again.url)
        editor.mark.text = "仅供本次使用"
        let changed = try await sharedFile()
        XCTAssertNotEqual(try Data(contentsOf: first.url), try Data(contentsOf: changed.url))
        editor.mark.tileOpacity = 20
        let adjusted = try await sharedFile()
        XCTAssertNotEqual(try Data(contentsOf: changed.url), try Data(contentsOf: adjusted.url))
    }

    @MainActor
    func testCaptureWithEmptyWatermarkKeepsThePhotoAvailableForRedaction() async throws {
        let editor = WatermarkEditor()
        XCTAssertEqual(editor.mark.text, "")
        let original = try fixture(120, 80) { _, _ in (255, 255, 255, 255) }
        editor.acceptCapture(UIImage(cgImage: original))
        try await waitUntilIdle(editor)
        XCTAssertEqual(editor.photo?.size, CGSize(width: 120, height: 80))
        XCTAssertNil(editor.feedback)
        XCTAssertNil(editor.watermarkLayer)
        XCTAssertFalse(editor.canExport)
        editor.addCover()
        XCTAssertTrue(editor.canExport)
    }

    @MainActor
    func testTextAloneControlsWatermarkInPreviewAndExportIndependentlyOfCovers() async throws {
        let editor = WatermarkEditor()
        editor.mark = Watermark(text: "PRIVATE", position: .center)
        let white = try fixture(240, 160) { _, _ in (255, 255, 255, 255) }
        editor.acceptCapture(UIImage(cgImage: white))
        try await waitUntilIdle(editor)
        editor.addCover(Redaction.imageBounds)
        for (text, visible) in [("PRIVATE", true), ("", false), ("  \n\t", false), ("Again", true)] {
            editor.mark.text = text
            XCTAssertEqual(editor.visibleWatermarkPosition, visible ? .center : nil)
            if !visible { XCTAssertNil(editor.watermarkLayer) }
            XCTAssertTrue(editor.canExport)
            editor.preview()
            try await waitUntilIdle(editor)
            guard case let .preview(preview) = editor.cover else { return XCTFail("Expected a preview") }
            editor.cover = nil
            editor.share()
            try await waitUntilIdle(editor)
            guard case let .share(file) = editor.sheet else { return XCTFail("Expected a shareable copy") }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
            let bytes = pixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
            XCTAssertEqual(bytes, pixels(try XCTUnwrap(preview.cgImage)))
            XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, 255])
            let hasVisibleText = stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
            XCTAssertEqual(hasVisibleText, visible, "The exported watermark must follow the current text.")
            editor.sheet = nil
        }
    }

    @MainActor
    private func waitUntilIdle(_ editor: WatermarkEditor) async throws {
        let limit = ContinuousClock.now + .seconds(10)
        while editor.busy != nil && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.busy)
        XCTAssertNil(editor.errorMessage)
    }

    private func inkRegions(_ image: CGImage) -> Set<Int> {
        let data = pixels(image)
        var regions = Set<Int>()
        for y in 0..<image.height {
            for x in 0..<image.width where data[4 * (y * image.width + x)] < 230 {
                regions.insert(y * 3 / image.height * 3 + x * 3 / image.width)
            }
        }
        return regions
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private func fixture(_ width: Int, _ height: Int, color: (Int,Int) -> (UInt8,UInt8,UInt8,UInt8)) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r,g,b,a) = color(x,y)
                bytes.append(r); bytes.append(g); bytes.append(b); bytes.append(a)
            }
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent))
    }

    private func encode(_ image: CGImage, as type: UTType, orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
}
