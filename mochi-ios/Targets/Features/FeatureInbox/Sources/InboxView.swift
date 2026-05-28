import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

public struct InboxView: View {
    @Bindable public var store: StoreOf<InboxFeature>

    public init(store: StoreOf<InboxFeature>) {
        self.store = store
    }

    public var body: some View {
        List {
            ForEach(store.captures) { capture in
                row(capture)
                    .onTapGesture { store.send(.captureTapped(capture.id)) }
            }
        }
        .overlay {
            if store.isLoading { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Intent", selection: $store.filter.sending(\.filterChanged)) {
                    Text("전체").tag(Intent?.none)
                    ForEach(Intent.allCases, id: \.self) { intent in
                        Text(intent.displayName).tag(Intent?.some(intent))
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("받은 기록")
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private func row(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: MochiTheme.Spacing.xs) {
            HStack {
                if let intent = capture.intent {
                    IntentBadge(intent: intent)
                }
                Spacer()
                Text(capture.createdAt, style: .relative)
                    .font(MochiTheme.Typography.caption)
                    .foregroundStyle(MochiTheme.Palette.textSecondary)
            }
            Text(capture.analysis?.summary ?? capture.source.text ?? capture.source.url?.absoluteString ?? "(분석 대기 중)")
                .font(MochiTheme.Typography.body)
                .lineLimit(2)
        }
        .padding(.vertical, MochiTheme.Spacing.xs)
    }
}
