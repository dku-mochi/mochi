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
            ForEach(store.mochiItems) { mochiItem in
                row(mochiItem)
                    .onTapGesture { store.send(.mochiItemTapped(mochiItem.id)) }
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
        .refreshable { await store.send(.refresh).finish() }
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private func row(_ mochiItem: MochiItem) -> some View {
        VStack(alignment: .leading, spacing: MochiTheme.Spacing.xs) {
            HStack {
                if let intent = mochiItem.representativeIntent {
                    IntentBadge(intent: intent)
                }
                Spacer()
                Text(mochiItem.createdAt, style: .relative)
                    .font(MochiTheme.Typography.caption)
                    .foregroundStyle(MochiTheme.Palette.textSecondary)
            }
            Text(mochiItem.analysis?.summary ?? mochiItem.source.text ?? mochiItem.source.url?.absoluteString ?? "(분석 대기 중)")
                .font(MochiTheme.Typography.body)
                .lineLimit(2)
        }
        .padding(.vertical, MochiTheme.Spacing.xs)
    }
}
