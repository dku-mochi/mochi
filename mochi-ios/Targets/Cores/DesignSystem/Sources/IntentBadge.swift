import SwiftUI
import CoreDomain

public struct IntentBadge: View {
    public let intent: Intent

    public init(intent: Intent) { self.intent = intent }

    public var body: some View {
        Label(intent.displayName, systemImage: intent.systemImageName)
            .font(MochiTheme.Typography.caption.weight(.semibold))
            .padding(.horizontal, MochiTheme.Spacing.s)
            .padding(.vertical, MochiTheme.Spacing.xs)
            .background(MochiTheme.Palette.surface, in: Capsule())
            .foregroundStyle(MochiTheme.Palette.textPrimary)
    }
}
