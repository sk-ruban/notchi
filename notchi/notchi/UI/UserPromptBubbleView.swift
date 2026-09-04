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

    private static let collapsedLineLimit = 3

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
        .panelFont(size: 13)
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(TerminalColors.iMessageBlue)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded = hovering
            }
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

    private var promptText: Text? {
        let body = text.map(chippedText)
        guard hasOtherAttachments else { return body }

        let label = Text("Attached file").bold()
        return body.map { label + Text("\n") + $0 } ?? label
    }

    private func chippedText(_ prompt: String) -> Text {
        FileChipText.render(
            markdown: prompt,
            surface: .userBubble,
            baseColor: .white,
            fontSize: 13,
            fontScale: PanelTypography.fontScale(panelScale: panelScale)
        )
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
