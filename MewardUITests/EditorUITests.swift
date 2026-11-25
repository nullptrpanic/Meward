import UIKit
import XCTest

final class EditorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrivacyPolicyOpensFromTheEditor() {
        let app = XCUIApplication()
        app.launch()
        let privacy = app.buttons["privacy-policy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Photos and camera"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["watermark-text"].exists)
    }

    func testWatermarkTextAndRedactionsAreIndependentAcrossTabs() {
        let app = XCUIApplication()
        app.launch()
        let redact = app.buttons["redact-tool"]
        let watermark = app.buttons["watermark-tool"]
        let input = app.textFields["watermark-text"]
        let save = app.buttons["save"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["watermark-toggle"].exists)
        XCTAssertFalse(app.buttons["Clear watermark text"].exists)
        app.buttons["bottom-right"].tap()
        XCTAssertFalse(save.isEnabled)
        app.buttons["preview"].tap()
        XCTAssertTrue(app.staticTexts["Photo preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        redact.tap()
        XCTAssertFalse(app.switches["Include watermark"].exists)
        let add = app.buttons["add-cover"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let remove = app.buttons["remove-cover"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["delete-cover"].exists)
        XCTAssertFalse(app.buttons["undo-cover"].exists)
        XCTAssertTrue(save.isEnabled)
        watermark.tap()
        XCTAssertTrue(input.isEnabled)
        input.tap()
        input.typeText("Review\n")
        redact.tap()
        XCTAssertTrue(remove.exists)
        watermark.tap()
        XCTAssertEqual(input.value as? String, "Review")
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.buttons["bottom-right"].isSelected)
        app.buttons["Clear watermark text"].tap()
        XCTAssertTrue(save.isEnabled)
        redact.tap()
        remove.tap()
        XCTAssertFalse(save.isEnabled)
        add.tap()
        XCTAssertTrue(save.isEnabled)
        app.buttons["preview"].tap()
        XCTAssertTrue(app.staticTexts["Redaction preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testDrawMoveAndResizeAManualCover() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["redact-tool"].tap()
        let photo = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Live photo preview")
        ).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            photo.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func drag(_ start: XCUICoordinate, _ end: XCUICoordinate) {
            start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        func isBlack(_ x: CGFloat, _ y: CGFloat) throws -> Bool {
            let image = try XCTUnwrap(photo.screenshot().image.cgImage)
            let region = CGRect(x: floor(CGFloat(image.width) * x), y: floor(CGFloat(image.height) * y), width: 1, height: 1)
            let pixel = try XCTUnwrap(image.cropping(to: region))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba[0..<3].allSatisfy { $0 < 8 }
        }
        XCTAssertFalse(try isBlack(0.29, 0.29))
        drag(point(0.15, 0.18), point(0.45, 0.40))
        XCTAssertTrue(try isBlack(0.29, 0.29), "A drag across the photo must create a cover.")
        drag(point(0.29, 0.29), point(0.54, 0.52))
        XCTAssertFalse(try isBlack(0.29, 0.29))
        XCTAssertTrue(try isBlack(0.54, 0.52))
        drag(point(0.70, 0.63), point(0.90, 0.82))
        XCTAssertTrue(try isBlack(0.83, 0.75), "The corner handle must resize the selected cover.")
        XCTAssertTrue(app.buttons["save"].isEnabled, "A manual cover alone can be saved.")
        app.buttons["remove-cover"].tap()
        XCTAssertFalse(try isBlack(0.83, 0.75), "The selected box must be removable directly on the photo.")
        XCTAssertFalse(app.buttons["save"].isEnabled)

        // A short name may occupy just a few points. Its handles must leave its center draggable.
        for origin in [CGPoint(x: 0.30, y: 0.32), CGPoint(x: 0.02, y: 0.04)] {
            drag(point(origin.x, origin.y), point(origin.x + 0.04, origin.y + 0.06))
            XCTAssertTrue(app.buttons["remove-cover"].exists)
            drag(point(origin.x + 0.02, origin.y + 0.03), point(0.57, 0.68))
            point(0.85, 0.15).tap()
            XCTAssertTrue(try isBlack(0.57, 0.68), "A small cover must move when dragged from its center.")
            point(0.57, 0.68).tap()
            app.buttons["remove-cover"].tap()
            XCTAssertFalse(app.buttons["save"].isEnabled)
        }
    }

    func testTileControlsSurvivePositionChangesAndResetIndividually() {
        let app = XCUIApplication()
        app.launch()
        let angle = app.sliders["tile-angle"]
        let opacity = app.sliders["tile-opacity"]
        XCTAssertTrue(angle.waitForExistence(timeout: 5))
        XCTAssertEqual(angle.value as? String, "13°")
        XCTAssertEqual(opacity.value as? String, "46%")
        angle.adjust(toNormalizedSliderPosition: 0.85)
        opacity.adjust(toNormalizedSliderPosition: 0.20)
        let changedAngle = angle.value as? String
        let changedOpacity = opacity.value as? String
        XCTAssertNotEqual(changedAngle, "13°")
        XCTAssertNotEqual(changedOpacity, "46%")
        app.buttons["center"].tap()
        XCTAssertFalse(angle.exists)
        XCTAssertFalse(opacity.exists)
        app.buttons["tile"].tap()
        XCTAssertEqual(angle.value as? String, changedAngle)
        XCTAssertEqual(opacity.value as? String, changedOpacity)
        app.buttons["Reset angle"].tap()
        XCTAssertEqual(angle.value as? String, "13°")
        XCTAssertEqual(opacity.value as? String, changedOpacity)
        app.buttons["Reset opacity"].tap()
        XCTAssertEqual(opacity.value as? String, "46%")
    }

    func testEditPreviewAndClearWatermark() {
        let app = XCUIApplication()
        app.launch()
        let save = app.buttons["save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["choose"].label, "Choose photo")
        let corner = app.buttons["bottom-right"]
        let labelWidth = (corner.label as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline)]).width
        XCTAssertGreaterThanOrEqual(corner.frame.width, ceil(labelWidth) + 16, "The corner name needs room on one line.")
        XCTAssertEqual(save.label, "Save")
        XCTAssertFalse(save.isEnabled)

        corner.tap()
        let input = app.textFields["watermark-text"]
        input.tap()
        input.typeText("Private\n")
        XCTAssertTrue(save.isEnabled)
        app.buttons["preview"].tap()
        XCTAssertTrue(app.staticTexts["Watermark preview"].waitForExistence(timeout: 5))
        app.buttons["Zoom 2×"].tap()
        XCTAssertTrue(app.buttons["Fit to screen"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["bottom-right"].isSelected)

        app.buttons["Clear watermark text"].tap()
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(app.buttons["share"].isEnabled)
        XCTAssertTrue(app.buttons["preview"].isEnabled)
        input.tap()
        input.typeText("Meward\n")
        XCTAssertTrue(save.isEnabled)
    }

    #if targetEnvironment(simulator)
    func testSavePickAndShareLocalPhoto() {
        let app = XCUIApplication()
        app.launch()
        let save = app.buttons["save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        let input = app.textFields["watermark-text"]
        input.tap()
        input.typeText("Local copy\n")
        save.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(
            NSPredicate(format: "label IN %@", ["Allow", "允许", "允许添加照片", "Allow Adding Photos"])
        ).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let saved = app.staticTexts["Copy saved to Photos."]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["choose"].tap()
        let gridPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        let cell = app.collectionViews.cells.firstMatch
        let pickerReady = NSPredicate { _, _ in gridPhoto.exists || cell.exists }
        let ready = XCTNSPredicateExpectation(predicate: pickerReady, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        (gridPhoto.exists ? gridPhoto : cell).tap()
        let sample = app.staticTexts["Sample photo"]
        let imported = NSPredicate { _, _ in !sample.exists && save.exists && save.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: imported, object: app)], timeout: 10), .completed)

        app.sliders["tile-opacity"].adjust(toNormalizedSliderPosition: 0.80)
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.buttons["share"].tap()
        let localAction = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制", "Save to Files", "存储到“文件”"])).firstMatch
        XCTAssertTrue(localAction.waitForExistence(timeout: 8), app.debugDescription)
    }
    #endif
}
