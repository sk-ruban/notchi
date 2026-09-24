import AppKit
import ImageIO
import SwiftUI

struct UserPromptBubbleView: View {
    let text: String?
    let hasOtherAttachments: Bool
    let imageAttachments: [UserPromptImageAttachment]

    @Environment(\.panelScale) private var panelScale
    @State private var isExpanded = false
    @State private var collapsedTextWidth: CGFloat?
    @State private var availableWidth: CGFloat = 0

    private static let collapsedLineLimit = 3
    private static let fontSize: CGFloat = 13
    private static let horizontalPadding: CGFloat = 14
    private var bubbleShape: RoundedRectangle { RoundedRectangle(cornerRadius: 18) }

    var body: some View {
        let renderedPrompt = promptText

        return VStack(alignment: .leading, spacing: renderedPrompt == nil ? 0 : 10 * panelScale) {
            imagePreviews

            if let renderedPrompt {
                renderedPrompt
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .truncationMode(.tail)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        if !isExpanded { collapsedTextWidth = width }
                    }
                    .frame(width: isExpanded ? collapsedTextWidth : nil, alignment: .leading)
            }
        }
        .panelFont(size: Self.fontSize)
        .foregroundColor(.white)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 10)
        .background(bubbleShape.fill(TerminalColors.iMessageBlue))
        // lineLimit isn't animatable: the text jumps to full height while the frame animates,
        // so clip to the animating frame to keep the overflow from painting outside the bubble.
        .clipShape(bubbleShape)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded = hovering
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    @ViewBuilder
    private var imagePreviews: some View {
        if imageAttachments.count == 1, let attachment = imageAttachments.first {
            UserPromptImagePreview(attachment: attachment, presentation: .single)
        } else if imageAttachments.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8 * panelScale) {
                    ForEach(imageAttachments, id: \.path) { attachment in
                        UserPromptImagePreview(attachment: attachment, presentation: .gallery)
                    }
                }
            }
            .frame(width: 300 * panelScale, height: 112 * panelScale)
        }
    }

    private var fontScale: CGFloat {
        PanelTypography.fontScale(panelScale: panelScale)
    }

    private var promptText: Text? {
        guard let attributed = promptAttributed else { return nil }
        return FileChipText.render(
            attributed: isExpanded ? attributed : collapsedPrompt(attributed),
            surface: .userBubble,
            baseColor: .white,
            fontSize: Self.fontSize,
            fontScale: fontScale
        )
    }

    private var promptAttributed: AttributedString? {
        let body = text.map { FileChipText.displayAttributed(FileChipText.inlineAttributed($0)) }
        guard hasOtherAttachments else { return body }

        var label = AttributedString(String(localized: "Attached file"))
        label.inlinePresentationIntent = .stronglyEmphasized
        guard let body else { return label }
        return label + AttributedString("\n") + body
    }

    private func collapsedPrompt(_ attributed: AttributedString) -> AttributedString {
        let textWidth = availableWidth - 2 * Self.horizontalPadding
        let collapsed = PromptTailTruncation.collapsed(
            attributed,
            width: textWidth,
            lineLimit: Self.collapsedLineLimit
        ) { candidate in
            FileChipText.measurementAttributedString(from: candidate, fontSize: Self.fontSize, fontScale: fontScale)
        }
        return collapsed ?? attributed
    }
}

private struct UserPromptImagePreview: View {
    enum Presentation {
        case single
        case gallery
    }

    let attachment: UserPromptImageAttachment
    let presentation: Presentation

    @Environment(\.panelScale) private var panelScale
    @State private var thumbnail: NSImage?
    @State private var didFinishLoading = false

    var body: some View {
        framed(content)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 10 * panelScale, style: .continuous))
            .accessibilityLabel(attachment.displayName)
            .task(id: attachment.path) {
                thumbnail = nil
                didFinishLoading = false
                let loaded = await UserPromptImageThumbnailLoader.thumbnail(for: attachment.path)
                guard !Task.isCancelled else { return }
                thumbnail = loaded
                didFinishLoading = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
        } else if didFinishLoading {
            Text("Attached file").bold()
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func framed(_ view: some View) -> some View {
        switch presentation {
        case .single where thumbnail != nil:
            view.frame(maxWidth: 300 * panelScale, maxHeight: 180 * panelScale)
        case .single, .gallery:
            view.frame(width: 146 * panelScale, height: 112 * panelScale)
        }
    }
}

private enum UserPromptImageThumbnailLoader {
    private nonisolated static let maxPixelSize = 600
    private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func thumbnail(for path: String) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { load(path) }.value
    }

    private nonisolated static func load(_ path: String) -> NSImage? {
        guard let cacheKey = cacheKey(for: path) else { return nil }
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let decoded = decodeThumbnail(at: path) else { return nil }

        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        cache.setObject(image, forKey: cacheKey, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    private nonisolated static func cacheKey(for path: String) -> NSString? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(modified)|\(size)" as NSString
    }

    private nonisolated static func decodeThumbnail(at path: String) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
