import SwiftUI

struct WatermarkPreview: View {
    let image: UIImage
    let position: WatermarkPosition?
    let hasCovers: Bool
    let close: () -> Void
    @State private var zoomed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(hasCovers ? "Redaction preview" : (position == nil ? "Photo preview" : "Watermark preview"))
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(zoomed ? "Fit to screen" : "Zoom 2×") { zoomed.toggle() }
                    .frame(minHeight: 44)
                Button("Done", action: close).fontWeight(.semibold).frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(Color(white: 0.085))
            GeometryReader { proxy in
                let viewport = proxy.size
                let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
                let scale = zoomed ? fit * 2 : fit
                let anchor = (position ?? .center).anchor
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .frame(minWidth: viewport.width, minHeight: viewport.height)
                        .accessibilityLabel("Photo preview")
                        .onTapGesture(count: 2) { zoomed.toggle() }
                }
                .defaultScrollAnchor(UnitPoint(x: anchor.x, y: anchor.y))
                .scrollIndicators(.hidden)
                .scrollDisabled(!zoomed)
            }
        }
        .foregroundStyle(.white).tint(.white)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
