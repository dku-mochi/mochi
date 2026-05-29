import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

public struct MochiItemProgressView: View {
    @Bindable public var store: StoreOf<MochiItemFeature>

    public init(store: StoreOf<MochiItemFeature>) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: MochiTheme.Spacing.m) {
            Text("Agent 분석 중")
                .font(MochiTheme.Typography.headline)

            ForEach(AgentNode.allCases, id: \.self) { node in
                HStack {
                    Image(systemName: status(for: node).systemImage)
                        .foregroundStyle(status(for: node).color)
                    Text(node.rawValue)
                        .font(MochiTheme.Typography.body)
                    Spacer()
                }
            }

            if !store.partialSummary.isEmpty {
                Text(store.partialSummary)
                    .font(MochiTheme.Typography.body)
                    .foregroundStyle(MochiTheme.Palette.textSecondary)
                    .padding(.top, MochiTheme.Spacing.s)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .task { store.send(.startAnalysis) }
    }

    private struct StatusVM {
        let systemImage: String
        let color: Color
    }

    private func status(for node: AgentNode) -> StatusVM {
        let current = store.currentNode
        if node == current { return .init(systemImage: "circle.dotted", color: MochiTheme.Palette.primary) }
        if AgentNode.allCases.firstIndex(of: node) ?? 0 < (AgentNode.allCases.firstIndex(of: current) ?? 0) {
            return .init(systemImage: "checkmark.circle.fill", color: .green)
        }
        return .init(systemImage: "circle", color: MochiTheme.Palette.textSecondary)
    }
}
