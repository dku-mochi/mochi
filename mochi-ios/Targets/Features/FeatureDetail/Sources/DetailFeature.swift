import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

@Reducer
public struct DetailFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var mochiItemID: UUID
        public var mochiItem: MochiItem?
        /// 제목 인라인 교정 중 여부 — RecallHeader 가 Text ↔ TextField 전환.
        public var isEditingTitle: Bool = false
        public var titleDraft: String = ""
        public var lastError: String?

        public init(mochiItemID: UUID) { self.mochiItemID = mochiItemID }
    }

    public enum Action: Sendable {
        case onAppear
        case loaded(MochiItem?)
        case archiveTapped(instanceID: UUID, reason: InstanceLifecycle.ArchiveReason)
        // 제목 인라인 교정 — 로컬 userTitle 오버라이드 (백엔드 재추론 아님).
        case titleTapped
        case titleDraftChanged(String)
        case titleCommitted
        case titleEditCancelled
        case operationFailed(String)
    }

    @Dependency(\.mochiItemRepository) var repository

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { [id = state.mochiItemID] send in
                    let mochiItem = try await repository.find(id: id)
                    await send(.loaded(mochiItem))
                }

            case let .loaded(mochiItem):
                state.mochiItem = mochiItem
                return .none

            case let .archiveTapped(instanceID, reason):
                guard let mochiItem = state.mochiItem else { return .none }
                return .run { send in
                    do {
                        try await repository.updateInstanceLifecycle(mochiItemID: mochiItem.id, instanceID: instanceID, to: .archived(reason: reason))
                    } catch {
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .titleTapped:
                state.titleDraft = state.mochiItem?.displayHeadline ?? ""
                state.isEditingTitle = true
                return .none

            case let .titleDraftChanged(text):
                state.titleDraft = text
                return .none

            case .titleCommitted:
                guard let id = state.mochiItem?.id else { return .none }
                let trimmed = state.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let newTitle = trimmed.isEmpty ? nil : trimmed
                state.isEditingTitle = false
                state.mochiItem?.userTitle = newTitle   // 낙관적 로컬 반영 (상세는 observe 미구독)
                return .run { send in
                    do {
                        try await repository.setUserTitle(mochiItemID: id, title: newTitle)
                    } catch {
                        // 저장 실패 시 낙관 반영을 DB 진실로 되돌린다 (상세는 observe 미구독이라 자동 복구 안 됨).
                        await send(.loaded(try? await repository.find(id: id)))
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .titleEditCancelled:
                state.isEditingTitle = false
                state.titleDraft = ""
                return .none

            case let .operationFailed(message):
                state.lastError = message
                return .none
            }
        }
    }
}
