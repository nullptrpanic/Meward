import AVFoundation
import SwiftUI
import Vision

@MainActor
final class WatermarkEditor: ObservableObject {
    enum Tool { case watermark, redact }
    enum ScanState { case idle, scanning, finished, failed }
    enum Sheet: Identifiable {
        case library, share(WatermarkedFile), privacy
        var id: String { switch self { case .library: "library"; case .share: "share"; case .privacy: "privacy" } }
    }
    enum Cover: Identifiable {
        case camera, preview(UIImage)
        var id: String { switch self { case .camera: "camera"; case .preview: "preview" } }
    }

    @Published var mark = Watermark() {
        didSet { if mark != oldValue { invalidateOutput() } }
    }
    @Published private(set) var tool = Tool.watermark
    @Published private(set) var scanState = ScanState.idle
    @Published private(set) var regions: [Redaction] = [] {
        didSet { invalidateOutput() }
    }
    @Published var selectedCoverID: UUID?
    private var scanRequest: VNRecognizeTextRequest?
    @Published private(set) var photo: EditorPhoto?
    @Published private(set) var watermarkLayer: UIImage?
    @Published private(set) var busy: String?
    @Published private(set) var feedback: String?
    @Published var errorMessage: String?
    @Published var sheet: Sheet?
    @Published var cover: Cover?
    private var cachedFile: WatermarkedFile?
    private var drawing: Task<Void, Never>?

    var visibleWatermarkPosition: WatermarkPosition? { mark.trimmedText.isEmpty ? nil : mark.position }
    private var hasEdits: Bool { visibleWatermarkPosition != nil || !covers.isEmpty }
    var canPreview: Bool { photo != nil && busy == nil && scanState != .scanning }
    var canExport: Bool { canPreview && hasEdits && !(tool == .redact && scanState == .failed && covers.isEmpty) }
    var covers: [Redaction] { regions.filter(\.isEnabled) }
    var selectedCover: Redaction? { regions.first { $0.id == selectedCoverID && $0.isEnabled } }

    func selectTool(_ value: Tool) {
        tool = value
        if value == .redact && scanState == .idle { scan() }
    }

    func scan() {
        guard let photo, scanState == .idle || scanState == .failed else { return }
        let request = VNRecognizeTextRequest()
        scanRequest = request
        scanState = .scanning
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RedactionDetector.scan(photo, request: request) }
            }.value
            guard self.photo?.id == photo.id, scanRequest === request else { return }
            scanRequest = nil
            switch result {
            case .success(let found):
                if !found.isEmpty { regions = found + regions }
                scanState = .finished
            case .failure:
                scanState = .failed
            }
        }
    }

    func addCover(_ rect: CGRect = CGRect(x: 0.28, y: 0.43, width: 0.44, height: 0.14)) {
        let cover = Redaction(.manual, rect: rect)
        guard photo != nil, !cover.rect.isEmpty else { return }
        regions.append(cover)
        selectedCoverID = cover.id
    }

    func cover(at point: CGPoint) -> Redaction? {
        if let selectedCover, selectedCover.rect.contains(point) { return selectedCover }
        return regions.last { $0.isEnabled && $0.rect.contains(point) }
    }

    func selectCover(at point: CGPoint) {
        let hits = covers.reversed().filter { $0.rect.contains(point) }
        if let i = hits.firstIndex(where: { $0.id == selectedCoverID }) {
            selectedCoverID = hits[(i + 1) % hits.count].id
        } else {
            selectedCoverID = hits.first?.id
        }
    }

    func updateCover(_ id: UUID, to rect: CGRect) {
        let bounded = rect.standardized.intersection(Redaction.imageBounds)
        guard !bounded.isEmpty, let i = regions.firstIndex(where: { $0.id == id && $0.isEnabled }),
              regions[i].rect != bounded else { return }
        regions[i].rect = bounded
    }

    func confirmSelectedCover() {
        guard let i = regions.firstIndex(where: { $0.id == selectedCoverID && $0.isEnabled && $0.needsReview }) else { return }
        regions[i].needsReview = false
    }

    func toggleCover(_ id: UUID) {
        guard let i = regions.firstIndex(where: { $0.id == id && $0.kind != .manual }) else { return }
        if regions[i].isEnabled {
            removeCover(id)
        } else {
            regions[i].isEnabled = true
            selectedCoverID = id
        }
    }

    func removeCover(_ id: UUID) {
        guard let i = regions.firstIndex(where: { $0.id == id && $0.isEnabled }) else { return }
        if regions[i].kind == .manual {
            regions.remove(at: i)
        } else {
            // Keep the detected field and its edited rectangle so it can be covered again.
            regions[i].isEnabled = false
        }
        if selectedCoverID == id { selectedCoverID = nil }
    }

    func loadSample() {
        guard photo == nil else { return }
        perform("Opening sample photo…") {
            let example = try await Task.detached {
                guard let url = Bundle.main.url(forResource: "Sample", withExtension: "jpg") else { throw PhotoError.unreadable }
                return try EditorPhoto(data: Data(contentsOf: url), name: "Sample photo")
            }.value
            self.install(example)
        }
    }

    func select(_ provider: NSItemProvider?) {
        sheet = nil
        guard let provider else { return }
        perform("Opening photo…") {
            let data = try await PhotoLibrary.read(provider)
            let name = provider.suggestedName ?? "Selected photo"
            let selected = try await Task.detached { try EditorPhoto(data: data, name: name) }.value
            self.install(selected)
        }
    }

    func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = PhotoError.cameraUnavailable.localizedDescription
            return
        }
        perform("Opening camera…") {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw PhotoError.cameraDenied }
            self.cover = .camera
        }
    }

    func acceptCapture(_ image: UIImage?) {
        cover = nil
        guard let image else { return }
        let applyWatermark = tool == .watermark && !mark.trimmedText.isEmpty
        perform(applyWatermark ? "Adding watermark…" : "Opening photo…") {
            let captured = try await Task.detached { try EditorPhoto(capture: image) }.value
            self.install(captured)
            if applyWatermark {
                _ = try await self.output(for: captured)
                self.feedback = "Watermarked photo ready to save or share."
            }
        }
    }

    func preview() {
        guard let photo, canPreview else { return }
        perform("Preparing preview…") {
            let image: UIImage
            if !self.hasEdits {
                image = try await Task.detached { try photo.fullImage() }.value
            } else {
                let file = try await self.output(for: photo)
                guard let rendered = UIImage(contentsOfFile: file.url.path) else { throw PhotoError.render }
                image = rendered
            }
            self.cover = .preview(image)
        }
    }

    func save() {
        guard canExport, let photo else { return }
        perform("Saving copy…") {
            let file = try await self.output(for: photo)
            try await PhotoLibrary.save(file)
            self.feedback = "Copy saved to Photos."
        }
    }

    func share() {
        guard canExport, let photo else { return }
        perform("Preparing to share…") {
            let file = try await self.output(for: photo)
            self.sheet = .share(file)
        }
    }

    private func install(_ photo: EditorPhoto) {
        scanRequest?.cancel()
        scanRequest = nil
        scanState = .idle
        selectedCoverID = nil
        self.photo = photo
        watermarkLayer = nil
        regions = []
        if tool == .redact { scan() }
    }

    private func invalidateOutput() {
        cachedFile = nil
        feedback = nil
        drawing?.cancel()
        guard let photo else { return }
        let mark = self.mark
        guard !mark.trimmedText.isEmpty else { watermarkLayer = nil; return }
        let covers = self.covers
        drawing = Task {
            do {
                // Coalesce keystrokes before compositing the live image.
                try await Task.sleep(for: .milliseconds(45))
                let result = try await Task.detached(priority: .userInitiated) {
                    try WatermarkRenderer.watermarkLayer(photo, mark: mark, covers: covers)
                }.value
                try Task.checkCancellation()
                watermarkLayer = UIImage(cgImage: result)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func output(for photo: EditorPhoto) async throws -> WatermarkedFile {
        if let cachedFile { return cachedFile }
        let mark = self.mark, covers = self.covers
        let file = try await Task.detached(priority: .userInitiated) {
            try WatermarkRenderer.export(photo, mark: mark, covers: covers)
        }.value
        guard self.photo?.id == photo.id, self.mark == mark, self.covers == covers else { throw CancellationError() }
        cachedFile = file
        return file
    }

    private func perform(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = message
        feedback = nil
        Task {
            defer { busy = nil }
            do { try await work() }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }
}
