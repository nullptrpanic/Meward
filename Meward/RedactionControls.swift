import SwiftUI

struct RedactionControls: View {
    @ObservedObject var editor: WatermarkEditor
    @ScaledMetric(relativeTo: .subheadline) private var minimumChipWidth = 120.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if editor.scanState == .scanning { ProgressView().controlSize(.small) }
                Text(status).font(.subheadline.weight(.semibold)).accessibilityIdentifier("redaction-status")
                Spacer(minLength: 0)
                if editor.scanState == .failed {
                    Button("Retry", action: editor.scan).font(.subheadline.weight(.semibold))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumChipWidth), spacing: 8)], spacing: 8) {
                ForEach(detectedFields, id: \.region.id) { field in
                    let region = field.region
                    Button { editor.toggleCover(region.id) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: region.isEnabled ? "checkmark.circle.fill" : "circle")
                            Text(field.title)
                            if region.needsReview && region.isEnabled { Image(systemName: "exclamationmark.circle") }
                        }
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(SurfaceButton())
                    .accessibilityLabel(field.title)
                    .accessibilityValue(region.isEnabled ? "Covered" : "Visible")
                    .accessibilityHint(region.isEnabled ? "Show this field in the photo" : "Cover this field in the photo")
                    .accessibilityAddTraits(region.isEnabled ? .isSelected : [])
                }
                Button { editor.addCover() } label: {
                    Label("Add cover", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(SurfaceButton(primary: true)).accessibilityIdentifier("add-cover")
            }
            .font(.subheadline.weight(.medium))
            Text(editHint).font(.subheadline).foregroundStyle(Color(white: 0.75))
                .fixedSize(horizontal: false, vertical: true)
            if editor.selectedCover?.needsReview == true {
                Button("Confirm cover", action: editor.confirmSelectedCover)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .disabled(editor.busy != nil || editor.photo == nil)
    }

    private var detectedFields: [(region: Redaction, title: String)] {
        let detected = editor.regions.filter { $0.kind != .manual }
        let groups = Dictionary(grouping: detected, by: \.kind)
        var ordinals: [Redaction.Kind: Int] = [:]
        return detected.map { region in
            let number = ordinals[region.kind, default: 0] + 1
            ordinals[region.kind] = number
            let title = (groups[region.kind]?.count ?? 0) > 1 ? "\(region.kind.rawValue) \(number)" : region.kind.rawValue
            return (region, title)
        }
    }

    private var editHint: String {
        if editor.selectedCover != nil { return "Drag the box to move it. Use ↘ to resize or × to remove it." }
        if editor.regions.contains(where: { $0.kind != .manual }) {
            return "Tap a field to show or cover it. Tap a box on the photo to edit it."
        }
        return "Drag on the photo to draw a cover. Tap a box to edit it."
    }

    private var status: String {
        switch editor.scanState {
        case .idle: return "Choose a photo to scan."
        case .scanning: return "Finding personal information…"
        case .failed: return "Scan unavailable. Add covers manually."
        case .finished:
            let count = editor.covers.count
            if editor.regions.isEmpty { return "No covers. Check the photo for missed details." }
            let review = editor.covers.filter(\.needsReview).count
            let total = count == 1 ? "1 area covered" : "\(count) areas covered"
            return review == 0 ? total : "\(total) · \(review) to review"
        }
    }

}

struct RedactionCanvas: View {
    @ObservedObject var editor: WatermarkEditor
    let size: CGSize
    @GestureState private var drag: DragGesture.Value?
    @State private var dragStartCover: Redaction?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if editor.tool == .redact {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($drag) { value, state, _ in
                            // An OCR result arriving mid-stroke must not turn drawing a new box into moving it.
                            if state == nil { dragStartCover = editor.cover(at: normalized(value.startLocation)) }
                            state = value
                        }
                        .onEnded(finishDrag))
                if let drag, dragStartCover == nil {
                    let drawing = drawnRect(from: drag.startLocation, to: drag.location)
                    Rectangle().fill(.black)
                        .frame(width: drawing.width, height: drawing.height)
                        .position(x: drawing.midX, y: drawing.midY)
                        .allowsHitTesting(false)
                }
            }
            ForEach(editor.covers) { cover in
                let rect = dragStartCover?.id == cover.id ? moved(cover.rect, by: drag?.translation ?? .zero) : cover.rect
                EditableCover(cover: cover, rect: rect, size: size, editable: editor.tool == .redact,
                              selected: editor.tool == .redact && editor.selectedCoverID == cover.id,
                              select: { editor.selectedCoverID = cover.id },
                              remove: { editor.removeCover(cover.id) },
                              commit: { editor.updateCover(cover.id, to: $0) })
                    .zIndex(editor.selectedCoverID == cover.id ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(editor.tool == .redact && editor.busy == nil)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    private func moved(_ rect: CGRect, by offset: CGSize) -> CGRect {
        var result = rect
        result.origin.x = min(1 - rect.width, max(0, rect.minX + offset.width / size.width))
        result.origin.y = min(1 - rect.height, max(0, rect.minY + offset.height / size.height))
        return result
    }

    private func finishDrag(_ value: DragGesture.Value) {
        defer { dragStartCover = nil }
        let start = normalized(value.startLocation)
        if hypot(value.translation.width, value.translation.height) < 4 {
            editor.selectCover(at: start)
        } else if let touched = dragStartCover {
            editor.selectedCoverID = touched.id
            editor.updateCover(touched.id, to: moved(touched.rect, by: value.translation))
        } else {
            let rect = drawnRect(from: value.startLocation, to: value.location)
            if rect.width >= 5 && rect.height >= 5 {
                editor.addCover(rect.applying(CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height)))
            }
        }
    }

    private func drawnRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(CGRect(origin: .zero, size: size))
    }
}

private struct EditableCover: View {
    let cover: Redaction
    let rect: CGRect
    let size: CGSize
    let editable: Bool
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    let commit: (CGRect) -> Void
    @GestureState private var growth: CGSize = .zero

    var body: some View {
        let frame = resized(by: growth).applying(CGAffineTransform(scaleX: size.width, y: size.height))
        let name = cover.kind == .manual ? "Manual cover on photo" : "\(cover.kind.rawValue) cover on photo"
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black)
                .overlay {
                    if selected {
                        Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, select)
                .accessibilityAction(named: "Remove cover", remove)
                .position(x: frame.midX, y: frame.midY)
            if selected {
                handle(for: frame, removes: true)
                handle(for: frame, removes: false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityHidden(!editable)
        .allowsHitTesting(editable)
    }

    private func handle(for box: CGRect, removes: Bool) -> some View {
        let point = removes ? box.origin : CGPoint(x: box.maxX, y: box.maxY)
        let w = min(size.width, 44), h = min(size.height, 44)
        let radius = min(10, w / 2, h / 2)
        let x = max(0, min(point.x - (removes ? w - radius : radius), size.width - w))
        let y = max(0, min(point.y - (removes ? h - radius : radius), size.height - h))
        var target = CGRect(x: x, y: y, width: w, height: h)
        // On a short field, move the handle outside if its touch target would intercept a drag from the middle.
        if target.insetBy(dx: -2, dy: -2).contains(CGPoint(x: box.midX, y: box.midY)) {
            let above = CGPoint(x: x, y: box.minY - h), below = CGPoint(x: x, y: box.maxY)
            let left = CGPoint(x: box.minX - w, y: y), right = CGPoint(x: box.maxX, y: y)
            let candidates = removes ? [above, left, right, below] : [below, right, left, above]
            let bounds = CGRect(origin: .zero, size: size)
            if let origin = candidates.first(where: { bounds.contains(CGRect(origin: $0, size: target.size)) }) {
                target.origin = origin
            }
        }
        let icon = Image(systemName: removes ? "xmark" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            .frame(width: 2 * radius, height: 2 * radius)
            .background(.white, in: RoundedRectangle(cornerRadius: removes ? 10 : 4))
            .overlay { RoundedRectangle(cornerRadius: removes ? 10 : 4).strokeBorder(.black.opacity(0.7)) }
            .position(x: min(w - radius, max(radius, point.x - target.minX)),
                      y: min(h - radius, max(radius, point.y - target.minY)))
            .frame(width: w, height: h).contentShape(Rectangle())
        return Group {
            if removes {
                Button(action: remove) { icon }.buttonStyle(.plain)
                    .accessibilityLabel("Remove cover").accessibilityIdentifier("remove-cover")
            } else {
                icon.gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($growth) { value, state, _ in state = value.translation }
                    .onEnded { value in commit(resized(by: value.translation)) })
                    .accessibilityHidden(true)
            }
        }
        .position(x: target.midX, y: target.midY)
    }

    private func resized(by offset: CGSize) -> CGRect {
        guard offset != .zero else { return rect }
        let minWidth = min(14 / size.width, rect.width), minHeight = min(14 / size.height, rect.height)
        var result = rect
        result.size.width = min(1 - rect.minX, max(minWidth, rect.width + offset.width / size.width))
        result.size.height = min(1 - rect.minY, max(minHeight, rect.height + offset.height / size.height))
        return result
    }
}
