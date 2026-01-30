import SwiftUI

private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchContentView: View {
    let notchSize: CGSize
    @State private var isHovering = false
    @State private var bobOffset: CGFloat = 0

    private var sideWidth: CGFloat {
        max(0, notchSize.height - 12) + 10
    }

    private var topCornerRadius: CGFloat {
        isHovering ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        isHovering ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    var body: some View {
        VStack(spacing: 0) {
            notchContent
                .padding(.horizontal, cornerRadiusInsets.closed.bottom)
                .background(.black)
                .clipShape(NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                ))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1)
                        .padding(.horizontal, topCornerRadius)
                }
                .shadow(
                    color: isHovering ? .black.opacity(0.7) : .clear,
                    radius: 6
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        isHovering = hovering
                    }
                }
                .onTapGesture {
                    print("Notchi clicked")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                bobOffset = 3
            }
        }
    }

    @ViewBuilder
    private var notchContent: some View {
        HStack(spacing: 0) {
            // Black spacer for hardware notch area
            Rectangle()
                .fill(.black)
                .frame(width: notchSize.width - cornerRadiusInsets.closed.top)

            // Sprite on right side
            Image(systemName: "face.smiling")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .offset(y: bobOffset)
                .frame(width: sideWidth)
        }
        .frame(height: notchSize.height)
    }
}
