import SwiftUI

// MARK: - Floating mascot (기본 빈 상태·empty 공용 — 아주 약한 둥둥)

struct FloatingMascot: View {
    let imageName: String
    let size: CGFloat
    @State private var isFloating = false

    var body: some View {
        Image(imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: isFloating ? -4 : 4)
            .animation(
                .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                value: isFloating
            )
            .onAppear { isFloating = true }
            .accessibilityHidden(true)
    }
}
