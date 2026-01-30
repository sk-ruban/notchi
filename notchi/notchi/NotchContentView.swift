import SwiftUI

struct NotchContentView: View {
    let notchSize: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: notchSize.height / 2)
            .fill(Color.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                print("Notchi clicked")
            }
    }
}
