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
                        IntentBadge(intent: analysis.intent)
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
                Section("라이프사이클") {
                    if mochiItem.intent == .schedule {
                        Button("이벤트 종료로 아카이브", role: .destructive) {
                            store.send(.archiveTapped(.scheduleEnded))
                        }
                    }
                    if mochiItem.intent == .todo {
                        Button("완료로 아카이브", role: .destructive) {
                            store.send(.archiveTapped(.todoCompleted))
                        }
                    }
                    Button("직접 아카이브", role: .destructive) {
                        store.send(.archiveTapped(.userManual))
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
}
