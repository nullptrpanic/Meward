import UIKit
import XCTest
@testable import Meward

final class RedactionTests: XCTestCase {
    func testNumbersAcrossOCRFragmentsAndLabelledNames() throws {
        let lines = [
            fragment("+86 １３８", 0.10, 0.10, 0.16), fragment("0000-0000", 0.27, 0.10, 0.20),
            fragment("99000020000101008x", 0.10, 0.30, 0.49),
            fragment("姓 名", 0.10, 0.50, 0.10), fragment("林小禾", 0.25, 0.50, 0.16),
            fragment("订单 8813800000000123", 0.10, 0.80, 0.60)
        ]
        let covers = try RedactionDetector.covers(in: lines)
        XCTAssertEqual(covers.count, 3)
        let phone = covers.first { $0.kind == .phone }
        XCTAssertEqual(phone?.needsReview, false)
        XCTAssertTrue(phone?.rect.contains(CGPoint(x: 0.46, y: 0.12)) == true)
        XCTAssertTrue(phone?.rect.contains(CGPoint(x: 0.11, y: 0.12)) == true)
        XCTAssertEqual(covers.first { $0.kind == .identity }?.needsReview, false)
        XCTAssertTrue(covers.first { $0.kind == .name }?.rect.contains(CGPoint(x: 0.33, y: 0.52)) == true)
    }

    func testLabelProtectsAValueWithAnOCRErrorOnTheNextLine() throws {
        let covers = try RedactionDetector.covers(in: [
            fragment("公民身份号码", 0.10, 0.10, 0.22),
            fragment("99O00020000101008X", 0.10, 0.16, 0.53),
            fragment("普通说明文字", 0.10, 0.60, 0.35)
        ])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers.first?.kind, .identity)
        XCTAssertEqual(covers.first?.needsReview, true)
        XCTAssertTrue(covers.first?.rect.contains(CGPoint(x: 0.62, y: 0.18)) == true)
    }

    private func personalDataCard(fields: [String] = ["姓名：林小禾", "手机号：138 0000 0000", "身份证号：99000020000101008X"]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1100, height: 700)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (index, text) in fields.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 65, y: 100 + index * 170),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 54), .foregroundColor: UIColor.black])
            }
        }
    }

    func testVisionFindsPersonalDataOnTheDevice() throws {
        let photo = try EditorPhoto(capture: personalDataCard())
        let covers = try RedactionDetector.scan(photo)
        for (kind, point) in [(Redaction.Kind.name, CGPoint(x: 0.27, y: 0.19)),
                              (.phone, CGPoint(x: 0.45, y: 0.44)),
                              (.identity, CGPoint(x: 0.56, y: 0.68))] {
            XCTAssertTrue(covers.contains { $0.kind == kind && $0.rect.contains(point) }, "Missing cover for \(kind)")
        }
    }

    func testVisionCoversUnlabelledChatNamesIndividually() throws {
        let photo = try EditorPhoto(capture: personalDataCard(fields: [
            "林小禾", "请陈嘉宁明天回复", "周末见"
        ]))
        let names = try RedactionDetector.scan(photo).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 2)
        let sender = try XCTUnwrap(names.first { $0.rect.contains(CGPoint(x: 0.13, y: 0.19)) })
        let mention = try XCTUnwrap(names.first { $0.rect.contains(CGPoint(x: 0.20, y: 0.44)) })
        XCTAssertNotEqual(sender.id, mention.id)
        XCTAssertTrue(names.allSatisfy { $0.isEnabled && $0.needsReview })
        XCTAssertTrue(mention.rect.contains(CGPoint(x: 0.12, y: 0.44)))
        XCTAssertTrue(mention.rect.contains(CGPoint(x: 0.24, y: 0.44)))
        XCTAssertFalse(mention.rect.contains(CGPoint(x: 0.075, y: 0.44)))
        XCTAssertFalse(mention.rect.contains(CGPoint(x: 0.35, y: 0.44)))
        XCTAssertFalse(names.contains { $0.rect.contains(CGPoint(x: 0.13, y: 0.68)) })
    }

    func testNameSpansPreserveChatPunctuationAndUTF16Offsets() throws {
        let recognizer = try ChineseNameRecognizer()
        let cases: [(String, [String])] = [
            ("🙂 麻烦把材料转给贺予安，谢谢。", ["贺予安"]),
            ("林小禾，林小禾", ["林小禾", "林小禾"]),
            ("许知夏和王小明", ["许知夏", "王小明"]),
            ("09:41 欧阳星禾", ["欧阳星禾"]),
            ("今天下午三点在上海市人民医院见。", []),
            ("请注意查收文件", [])
        ]
        for (text, expected) in cases {
            let ranges = recognizer.ranges(in: text)
            XCTAssertEqual(ranges.map((text as NSString).substring(with:)), expected, text)
            XCTAssertEqual(ranges, ranges.sorted { $0.location < $1.location })
            XCTAssertEqual(Set(ranges).count, ranges.count)
        }
    }

    func testInstructionTextDoesNotCreateNameCovers() throws {
        let recognizer = try ChineseNameRecognizer()
        let cases: [(String, [String])] = [
            ("严格", []),
            ("请严格", []),
            ("遵照医嘱。", []),
            ("请严格遵照医嘱。", []),
            ("常见副作用 口苦、恶心、黑便", []),
            ("1. 严格遵医嘱，禁止自行购药或调整剂", []),
            ("严格按照规定办理。", []),
            ("即使以前不过敏，也可能发生过敏。", []),
            ("普通说明文字", []),
            ("复查时机 停药满1个月后，复查呼气试验。", []),
            ("30分钟服用。", []),
            ("注意口腔卫生。", []),
            ("请林小禾明天回复，务必遵照说明。", ["林小禾"]),
            ("请陈嘉宁确认材料后严格执行。", ["陈嘉宁"])
        ]
        for (text, expected) in cases {
            XCTAssertEqual(recognizer.ranges(in: text).map((text as NSString).substring(with:)), expected, text)
        }
    }

    func testModelDistinguishesMigrationQuestionsFromPeople() throws {
        let recognizer = try ChineseNameRecognizer()
        let cases: [(String, [String])] = [
            ("何时由何地迁来本市", []), ("何时、由何地迁来本址", []),
            ("何时由 来本市", []), ("何时由 来本址", []), ("何时", []), ("何地", []), ("何时 何地", []),
            ("何时 何地 办理入学", []),
            ("承办人签章：祝映棠", ["祝映棠"]), ("祝映棠", ["祝映棠"]),
            ("何明远何时到达？", ["何明远"]), ("姓名：何时", ["何时"]), ("收件人：何地", ["何地"]),
            ("请陈嘉宁明天回复", ["陈嘉宁"]),
            ("收件人：未提供", []), ("姓名：待填写", [])
        ]
        for (text, expected) in cases {
            XCTAssertEqual(recognizer.ranges(in: text).map((text as NSString).substring(with:)), expected, text)
        }
    }

    func testNameFieldWithPlaceholderDoesNotHideTheRestOfTheRow() throws {
        let names = try RedactionDetector.covers(in: [
            fragment("收件人：请在此填写", 0.06, 0.10, 0.40),
            fragment("姓名：未提供", 0.06, 0.30, 0.28), fragment("林小禾", 0.47, 0.30, 0.14)
        ]).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.needsReview)
        XCTAssertTrue(name.rect.contains(CGPoint(x: 0.54, y: 0.32)))
        XCTAssertFalse(name.rect.contains(CGPoint(x: 0.26, y: 0.32)))
    }

    func testModelCoversAnAmbiguousWordInAPersonContext() throws {
        let names = try RedactionDetector.covers(in: [
            fragment("姓名", 0.10, 0.12, 0.10), fragment("严格", 0.24, 0.12, 0.11),
            fragment("请严格遵守规定", 0.10, 0.60, 0.40)
        ]).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 1)
        let field = try XCTUnwrap(names.first)
        XCTAssertTrue(field.needsReview)
        XCTAssertTrue(field.rect.contains(CGPoint(x: 0.29, y: 0.14)))
    }

    func testVisionFindsThePersonInAnInstructionSheet() throws {
        let photo = try EditorPhoto(capture: personalDataCard(fields: [
            "请严格遵照医嘱。", "请陈嘉宁明天回复", "口苦、恶心、黑便"
        ]))
        let names = try RedactionDetector.scan(photo).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 1)
        let mention = try XCTUnwrap(names.first)
        XCTAssertTrue(mention.rect.contains(CGPoint(x: 0.20, y: 0.44)))
        XCTAssertFalse(mention.rect.contains(CGPoint(x: 0.35, y: 0.44)))
    }

    func testVisionCoversTheSignerWithoutCoveringMigrationQuestions() throws {
        let photo = try EditorPhoto(capture: personalDataCard(fields: [
            "承办人签章：祝映棠", "何时由何地迁来本市", "何时由何地迁来本址"
        ]))
        let names = try RedactionDetector.scan(photo).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 1)
        let signer = try XCTUnwrap(names.first)
        XCTAssertTrue(signer.needsReview)
        XCTAssertTrue(signer.rect.contains(CGPoint(x: 0.38, y: 0.19)))
        XCTAssertTrue(signer.rect.contains(CGPoint(x: 0.48, y: 0.19)))
        XCTAssertFalse(signer.rect.contains(CGPoint(x: 0.27, y: 0.19)))
    }

    func testNumberAndNameOnTheSameRowHaveSeparateCovers() throws {
        let covers = try RedactionDetector.covers(in: [
            fragment("手机号", 0.01, 0.10, 0.10), fragment("13800000000", 0.14, 0.10, 0.24),
            fragment("姓名", 0.43, 0.10, 0.09), fragment("林小禾", 0.58, 0.10, 0.13)
        ])
        XCTAssertEqual(covers.count, 2)
        let phone = try XCTUnwrap(covers.first { $0.kind == .phone })
        let name = try XCTUnwrap(covers.first { $0.kind == .name })
        XCTAssertTrue(phone.rect.contains(CGPoint(x: 0.26, y: 0.12)))
        XCTAssertFalse(phone.rect.intersects(name.rect))
        XCTAssertTrue(name.rect.contains(CGPoint(x: 0.64, y: 0.12)))
    }

    func testDamagedIDOnAFormKeepsItsOwnCover() throws {
        let covers = try RedactionDetector.covers(in: [
            fragment("证件号码", 0.01, 0.10, 0.10), fragment("99O00020000101008X", 0.14, 0.10, 0.34),
            fragment("姓名：", 0.52, 0.10, 0.10), fragment("林小禾", 0.66, 0.10, 0.13)
        ])
        let id = try XCTUnwrap(covers.first { $0.kind == .identity })
        let name = try XCTUnwrap(covers.first { $0.kind == .name })
        XCTAssertTrue(id.needsReview)
        XCTAssertTrue(id.rect.contains(CGPoint(x: 0.46, y: 0.12)))
        XCTAssertLessThan(id.rect.maxX, 0.52)
        XCTAssertTrue(name.rect.contains(CGPoint(x: 0.72, y: 0.12)))
    }

    func testEmptyIDFieldDoesNotCoverANameAndYearOnTheNextLine() throws {
        let covers = try RedactionDetector.covers(in: [
            fragment("证件号码", 0.10, 0.10, 0.17),
            fragment("姓名：林小禾 2024年", 0.10, 0.16, 0.37)
        ])
        XCTAssertFalse(covers.contains { $0.kind == .identity })
        XCTAssertTrue(covers.contains { $0.kind == .name })
    }

    func testNameSplitByVisionAndLabelledNameOnNextLineGetOneCoverEach() throws {
        let names = try RedactionDetector.covers(in: [
            fragment("林", 0.10, 0.10, 0.04), fragment("小禾", 0.145, 0.10, 0.08),
            fragment("收件人", 0.10, 0.40, 0.12), fragment("欧阳星禾", 0.10, 0.47, 0.17)
        ]).filter { $0.kind == .name }
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy(\.needsReview))
        let split = try XCTUnwrap(names.first { $0.rect.contains(CGPoint(x: 0.13, y: 0.12)) })
        XCTAssertLessThan(split.rect.minX, 0.10)
        XCTAssertGreaterThan(split.rect.maxX, 0.22)
        XCTAssertTrue(names.contains { $0.rect.contains(CGPoint(x: 0.16, y: 0.49)) })
    }

    @MainActor
    func testTwoNamesInOneFieldCanBeRevealedSeparately() async throws {
        let editor = WatermarkEditor()
        editor.acceptCapture(personalDataCard(fields: ["收件人：林小禾、陈嘉宁"]))
        try await waitFor { editor.busy == nil }
        editor.selectTool(.redact)
        try await waitFor { editor.scanState == .finished }
        let names = editor.covers.filter { $0.kind == .name }.sorted { $0.rect.minX < $1.rect.minX }
        XCTAssertEqual(names.count, 2)
        guard names.count == 2 else { return }
        XCTAssertLessThan(names[0].rect.maxX, names[1].rect.minX)
        XCTAssertTrue(names.allSatisfy(\.needsReview))
        editor.toggleCover(names[0].id)
        XCTAssertEqual(editor.covers, [names[1]])
        editor.toggleCover(names[0].id)
        XCTAssertEqual(Set(editor.covers.map(\.id)), Set(names.map(\.id)))
    }

    @MainActor
    func testEachCoverCanBeEditedAndRemovedEvenWhenOCRFinishesAfterAManualEdit() async throws {
        let editor = WatermarkEditor()
        editor.acceptCapture(personalDataCard())
        try await waitFor { editor.busy == nil }
        editor.selectTool(.redact)
        editor.addCover()
        let manual = try XCTUnwrap(editor.selectedCover)
        try await waitFor { editor.scanState == .finished }
        XCTAssertTrue(editor.covers.contains(manual))
        let auto = editor.covers.filter { $0.kind != .manual }
        XCTAssertTrue(auto.contains { $0.kind == .phone })
        XCTAssertTrue(auto.contains { $0.kind == .identity })
        editor.removeCover(manual.id)
        XCTAssertEqual(editor.covers, auto)
        XCTAssertFalse(editor.regions.contains { $0.id == manual.id })

        let id = try XCTUnwrap(auto.first { $0.kind == .identity }).id
        editor.selectedCoverID = id
        let adjusted = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.26)
        editor.updateCover(id, to: adjusted)
        editor.selectTool(.watermark)
        editor.selectTool(.redact)
        XCTAssertEqual(editor.covers.first { $0.id == id }?.rect, adjusted)
        editor.removeCover(id)
        XCTAssertEqual(editor.covers, auto.filter { $0.id != id })
        XCTAssertNil(editor.selectedCover)
        editor.toggleCover(id)
        XCTAssertEqual(editor.covers.first { $0.id == id }?.rect, adjusted)
    }

    @MainActor
    func testTogglingOneOfTwoPhoneNumbersOnlyRevealsThatNumberInTheExport() async throws {
        let editor = WatermarkEditor()
        editor.acceptCapture(personalDataCard(fields: ["手机号：138 0000 0000", "手机号：139 0000 0000"]))
        try await waitFor { editor.busy == nil }
        editor.selectTool(.redact)
        try await waitFor { editor.scanState == .finished }
        let phones = editor.covers.filter { $0.kind == .phone }.sorted { $0.rect.midY < $1.rect.midY }
        XCTAssertEqual(phones.count, 2)
        guard phones.count == 2 else { return }
        for visible in [true, false] {
            editor.toggleCover(phones[0].id)
            editor.share()
            try await waitFor { editor.busy == nil }
            guard case let .share(file) = editor.sheet else { return XCTFail("Expected a shareable image") }
            let image = try XCTUnwrap(UIImage(contentsOfFile: file.url.path)?.cgImage)
            for (i, phone) in phones.enumerated() {
                let rect = phone.rect.applying(CGAffineTransform(scaleX: CGFloat(image.width), y: CGFloat(image.height)))
                let sample = try XCTUnwrap(image.cropping(to: rect.insetBy(dx: 3, dy: 3).integral))
                var gray = [UInt8](repeating: 0, count: 128)
                try gray.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 16, height: 8,
                        bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                    context.draw(sample, in: CGRect(x: 0, y: 0, width: 16, height: 8))
                }
                XCTAssertEqual(gray.contains { $0 > 100 }, i == 0 && visible)
            }
            editor.sheet = nil
        }
        for phone in phones { editor.removeCover(phone.id) }
        XCTAssertFalse(editor.canExport)
        XCTAssertEqual(editor.regions.count, 2)
    }

    @MainActor
    func testOverlappingManualCoversCanBeSelectedAndRemovedIndividually() async throws {
        let editor = WatermarkEditor()
        editor.acceptCapture(personalDataCard())
        try await waitFor { editor.busy == nil }
        editor.addCover()
        let first = try XCTUnwrap(editor.selectedCover)
        editor.addCover()
        let second = try XCTUnwrap(editor.selectedCover)
        editor.selectCover(at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(editor.selectedCoverID, first.id)
        editor.removeCover(first.id)
        XCTAssertEqual(editor.covers, [second])
    }

    @MainActor
    func testNewPhotoDiscardsThePreviousScanAndAllCovers() async throws {
        let editor = WatermarkEditor()
        editor.acceptCapture(personalDataCard())
        try await waitFor { editor.busy == nil }
        let old = editor.photo?.id
        editor.selectTool(.redact)
        editor.addCover()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 400, height: 200)
        let blank = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        editor.mark.text = ""
        editor.acceptCapture(blank)
        try await waitFor { editor.photo?.id != old && editor.busy == nil && editor.scanState == .finished }
        XCTAssertTrue(editor.covers.isEmpty)
        XCTAssertTrue(editor.regions.isEmpty)
        XCTAssertFalse(editor.canExport)
        XCTAssertNil(editor.errorMessage)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition())
    }

    private func fragment(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> OCRFragment {
        OCRFragment(text: text, rect: CGRect(x: x, y: y, width: width, height: 0.045))
    }
}
