import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

public struct DetailView: View {
    @Bindable public var store: StoreOf<DetailFeature>

    public init(store: StoreOf<DetailFeature>) { self.store = store }

    public var body: some View {
        Form {
            if let mochiItem = store.mochiItem {
                Section("요약") {
                    if let analysis = mochiItem.analysis {
                        Text(analysis.summary).font(MochiTheme.Typography.body)
                        if !mochiItem.intentTypes.isEmpty {
                            HStack(spacing: MochiTheme.Spacing.xs) {
                                ForEach(mochiItem.intentTypes, id: \.self) { intent in
                                    IntentBadge(intent: intent)
                                }
                            }
                        }
                    } else {
                        Text("(분석 대기 중)")
                            .foregroundStyle(MochiTheme.Palette.textSecondary)
                    }
                }
                if let analysis = mochiItem.analysis,
                   analysis.actionCandidates.contains(where: { if case .createCalendarEvent = $0 { return true } else { return false } }) {
                    Section("자동 동기화") {
                        Button("캘린더에 등록", systemImage: "calendar.badge.plus") {
                            store.send(.syncToCalendarTapped)
                        }
                        .disabled(store.isSyncing)
                    }
                }
                let activeInstances = mochiItem.instances.filter { $0.lifecycle == .active }
                if !activeInstances.isEmpty {
                    Section("라이프사이클") {
                        ForEach(activeInstances) { instance in
                            lifecycleRow(for: instance)
                        }
                    }
                }
                if let error = store.lastError {
                    Section("오류") { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("기록 상세")
        .task { store.send(.onAppear) }
    }

    /// active intent instance 1건의 lifecycle 전이 버튼 (instance 단위 — 한 캡처의 여러 의도가 독립).
    @ViewBuilder
    private func lifecycleRow(for instance: IntentInstance) -> some View {
        VStack(alignment: .leading, spacing: MochiTheme.Spacing.xs) {
            Label(instance.displayLabel, systemImage: instance.intentType.systemImageName)
                .font(MochiTheme.Typography.caption.weight(.semibold))
            switch instance.intentType {
            case .schedule:
                Button("이벤트 종료로 아카이브", role: .destructive) {
                    store.send(.archiveTapped(instanceID: instance.id, reason: .scheduleEnded))
                }
            case .todo:
                Button("완료로 아카이브", role: .destructive) {
                    store.send(.archiveTapped(instanceID: instance.id, reason: .todoCompleted))
                }
            case .knowledge, .memo:
                EmptyView()
            }
            Button("직접 아카이브", role: .destructive) {
                store.send(.archiveTapped(instanceID: instance.id, reason: .userManual))
            }
        }
    }
}
