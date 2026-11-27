import SwiftUI

enum NotchConstants {
    static let expandedPanelSize = CGSize(width: 450, height: 450)
    static let expandedPanelHorizontalPadding: CGFloat = 19 * 2
    static let expandedPanelContentInset: CGFloat = 48
    static let expandedPanelHitTestSlack: CGFloat = 48
    static let expandedPanelVerticalInset: CGFloat = 24

    static var expandedPanelContentWidth: CGFloat {
        expandedPanelSize.width - expandedPanelContentInset
    }

    static func expandedContentHeight(notchHeight: CGFloat) -> CGFloat {
        expandedPanelSize.height - notchHeight - expandedPanelVerticalInset
    }

    static var scalablePanelHeight: CGFloat {
        expandedPanelSize.height - expandedPanelVerticalInset
    }

    static func panelSize(scale: CGFloat) -> CGSize {
        CGSize(
            width: expandedPanelContentWidth * scale + expandedPanelHorizontalPadding + expandedPanelHitTestSlack,
            height: scalablePanelHeight * scale + expandedPanelVerticalInset
        )
    }
}

enum PanelTypography {
    static let enlargedFontScale: CGFloat = 1.125

    static func fontScale(panelScale: CGFloat) -> CGFloat {
        panelScale > 1 ? enlargedFontScale : 1
    }
}

private struct PanelScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var panelScale: CGFloat {
        get { self[PanelScaleKey.self] }
        set { self[PanelScaleKey.self] = newValue }
    }
}

extension View {
    func panelIcon(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(PanelIconModifier(size: size, weight: weight))
    }

    func panelFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        transform: @escaping (Font) -> Font = { $0 }
    ) -> some View {
        modifier(PanelFontModifier(size: size, weight: weight, design: design, transform: transform))
    }
}

struct PanelIconModifier: ViewModifier {
    @Environment(\.panelScale) private var panelScale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * panelScale, weight: weight))
    }
}

struct PanelFontModifier: ViewModifier {
    @Environment(\.panelScale) private var panelScale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let transform: (Font) -> Font

    func body(content: Content) -> some View {
        let scaledSize = size * PanelTypography.fontScale(panelScale: panelScale)
        return content.font(transform(.system(size: scaledSize, weight: weight, design: design)))
    }
}

extension Notification.Name {
    static let notchiShouldCollapse = Notification.Name("notchiShouldCollapse")
    static let notchiQuestionOptionShortcut = Notification.Name("notchiQuestionOptionShortcut")
}
