import SwiftUI

private enum Ink {
    static let upper = Color(white: 0.035)
    static let lower = Color(white: 0.085)
    static let field = Color(white: 0.125)
    static let line = Color(white: 0.23)
    static let muted = Color(white: 0.69)
    static let paper = Color(white: 0.94)
}

struct EditorView: View {
    @StateObject private var editor = WatermarkEditor()
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(geometry.size.width, 680)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 0) { brand; Spacer(minLength: 10); sources }
                            VStack(alignment: .leading, spacing: 10) { brand; sources }
                        }
                        photoPanel(width: contentWidth - 36, availableHeight: geometry.size.height)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 13)
                    .background(Ink.upper)

                    VStack(alignment: .leading, spacing: editor.tool == .watermark ? 6 : 10) {
                        tools
                        if editor.tool == .watermark {
                            textField
                            positions
                        } else {
                            RedactionControls(editor: editor)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !typing {
                    actions
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(maxWidth: contentWidth)
                        .background(Ink.lower)
                }
            }
        }
        .background(Ink.lower.ignoresSafeArea())
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                Ink.upper.frame(height: proxy.safeAreaInsets.top).offset(y: -proxy.safeAreaInsets.top)
            }.allowsHitTesting(false)
        }
        .foregroundStyle(Ink.paper)
        .tint(Ink.paper)
        .task { editor.loadSample() }
        .sheet(item: $editor.sheet) { sheet in
            switch sheet {
            case .library: PhotoPicker(selected: editor.select).ignoresSafeArea()
            case .share(let file): FileShareSheet(file: file)
            case .privacy: PrivacyPolicyView()
            }
        }
        .fullScreenCover(item: $editor.cover) { cover in
            switch cover {
            case .camera: CameraPicker(captured: editor.acceptCapture).ignoresSafeArea()
            case .preview(let image):
                WatermarkPreview(image: image, position: editor.visibleWatermarkPosition,
                                 hasCovers: !editor.covers.isEmpty) { editor.cover = nil }
            }
        }
        .alert("Meward", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(editor.errorMessage ?? "") }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image("BrandMark").resizable().frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.line) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Meward").font(.system(.title2, design: .serif, weight: .semibold))
                    .accessibilityLabel("Meward photo editor")
                    .accessibilityAddTraits(.isHeader)
                Button { editor.sheet = .privacy } label: {
                    Label("Privacy policy", systemImage: "lock")
                        .font(.caption).foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("privacy-policy")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sources: some View {
        HStack(spacing: 7) {
            Button { typing = false; editor.openCamera() } label: {
                Image(systemName: "camera").frame(width: 44, height: 44)
            }.accessibilityLabel("Take photo").accessibilityIdentifier("camera")
            Button { typing = false; editor.sheet = .library } label: {
                Text("Choose photo").fixedSize().padding(.horizontal, 14).frame(minHeight: 44)
            }.accessibilityIdentifier("choose")
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(SurfaceButton())
        .disabled(editor.busy != nil)
    }

    private func photoPanel(width: CGFloat, availableHeight: CGFloat) -> some View {
        let size = editor.photo?.size ?? CGSize(width: 1080, height: 720)
        let height = min(max(110, width * size.height / size.width), max(180, min(410, availableHeight * 0.43)))
        let fit = min(width / size.width, height / size.height)
        let display = CGSize(width: size.width * fit, height: size.height * fit)
        return VStack(spacing: 9) {
            ZStack {
                Color.black
                if let photo = editor.photo {
                    ZStack {
                        Image(decorative: photo.thumbnail, scale: 1).resizable()
                        RedactionCanvas(editor: editor, size: display).id(photo.id)
                        if let layer = editor.watermarkLayer {
                            Image(uiImage: layer).resizable().allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .frame(width: display.width, height: display.height)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityElement(children: editor.tool == .redact ? .contain : .ignore)
            .accessibilityLabel("Live photo preview")
            .accessibilityValue(editor.covers.isEmpty ? (editor.visibleWatermarkPosition?.label ?? "Original photo") : "\(editor.covers.count) areas covered")
            if let photo = editor.photo {
                HStack {
                    Text(verbatim: photo.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Int(photo.size.width)) × \(Int(photo.size.height))").font(.system(.caption2, design: .monospaced))
                        .accessibilityIdentifier("dimensions")
                }.font(.caption).foregroundStyle(Ink.muted)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 4) {
            toolButton(.watermark, "Watermark", icon: "textformat", id: "watermark-tool")
            toolButton(.redact, "Redact", icon: "rectangle.dashed", id: "redact-tool")
        }
        .padding(3)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .disabled(editor.busy != nil)
    }

    private func toolButton(_ tool: WatermarkEditor.Tool, _ title: String, icon: String, id: String) -> some View {
        let selected = editor.tool == tool
        return Button {
            typing = false
            editor.selectTool(tool)
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(selected ? Ink.paper : Ink.muted)
                .background(selected ? Ink.line : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var textField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watermark text").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            HStack(spacing: 0) {
                TextField("Enter text", text: $editor.mark.text)
                    .textFieldStyle(.plain).focused($typing).submitLabel(.done)
                    .frame(minHeight: 48)
                    .accessibilityLabel("Watermark text").accessibilityIdentifier("watermark-text")
                    .onSubmit { typing = false }
                if !editor.mark.text.isEmpty {
                    Button { editor.mark.text = "" } label: {
                        Image(systemName: "xmark").font(.subheadline).frame(width: 44, height: 44)
                    }.accessibilityLabel("Clear watermark text").foregroundStyle(Ink.muted)
                }
            }
            .padding(.leading, 14).padding(.trailing, 2)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(typing ? Ink.paper : Ink.line).allowsHitTesting(false) }
        }
        .disabled(editor.busy != nil)
    }

    private var positions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Position").font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                positionGrid(columns: 6)
                positionGrid(columns: 3)
                positionGrid(columns: 2)
                positionGrid(columns: 1)
            }
            if editor.mark.position == .tile {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    tileSlider("Angle", value: $editor.mark.tileAngle, range: 8...30, unit: "°",
                               initial: Watermark.defaultTileAngle, id: "tile-angle")
                    tileSlider("Opacity", value: $editor.mark.tileOpacity, range: 12...55, unit: "%",
                               initial: Watermark.defaultTileOpacity, id: "tile-opacity")
                }
            }
        }
        .disabled(editor.busy != nil)
    }

    private func positionGrid(columns: Int) -> some View {
        // Keep the four corners in their photo positions beside Tile and Center.
        let options: [WatermarkPosition] = columns == 3
            ? [.tile, .topLeft, .topRight, .center, .bottomLeft, .bottomRight]
            : WatermarkPosition.allCases
        return Grid(horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(0..<((options.count + columns - 1) / columns), id: \.self) { row in
                GridRow {
                    ForEach(options.dropFirst(row * columns).prefix(columns), id: \.self) { position in
                        positionButton(position)
                    }
                }
            }
        }
    }

    private func positionButton(_ position: WatermarkPosition) -> some View {
        let selected = editor.mark.position == position
        return Button {
            typing = false
            editor.mark.position = position
        } label: {
            VStack(spacing: 4) {
                Image("position-" + position.rawValue).resizable().renderingMode(.template)
                    .scaledToFit().frame(width: 21, height: 15).accessibilityHidden(true)
                Text(position.label).font(.subheadline.weight(.medium))
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(SurfaceButton(primary: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(position.rawValue)
    }

    private func tileSlider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>,
                            unit: String, initial: Double, id: String) -> some View {
        let readout = "\(Int(value.wrappedValue))\(unit)"
        return GridRow {
            Text(name).font(.subheadline).accessibilityHidden(true)
            Slider(value: value, in: range, step: 1) { Text(name) }
                .labelsHidden()
                .frame(minHeight: 44)
                .accessibilityValue(readout)
                .accessibilityIdentifier(id)
            Text(verbatim: readout).font(.subheadline.monospacedDigit())
                .gridColumnAlignment(.trailing).accessibilityHidden(true)
            Button {
                value.wrappedValue = initial
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.subheadline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reset \(name.lowercased())")
            .disabled(value.wrappedValue == initial)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let message = editor.busy ?? editor.feedback {
                HStack(spacing: 7) {
                    if editor.busy != nil { ProgressView().controlSize(.small) }
                    Text(message).font(.footnote)
                }.foregroundStyle(Ink.muted).accessibilityIdentifier("feedback")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(spacing: 8) { actionButtons }
            }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        action("Preview", icon: "arrow.up.left.and.arrow.down.right", id: "preview",
               enabled: editor.canPreview, run: editor.preview)
        action("Save", icon: "arrow.down.to.line", id: "save", primary: true,
               enabled: editor.canExport, run: editor.save)
        action("Share", icon: "square.and.arrow.up", id: "share", enabled: editor.canExport, run: editor.share)
    }

    private func action(_ name: String, icon: String, id: String, primary: Bool = false, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(name, systemImage: icon)
                .font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 49)
        }
        .buttonStyle(SurfaceButton(primary: primary))
        .disabled(!enabled).accessibilityIdentifier(id)
    }
}

struct SurfaceButton: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.black : Ink.paper)
            .background(primary ? Ink.paper : Ink.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(primary ? Ink.paper : Ink.line) }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.38)
    }
}
