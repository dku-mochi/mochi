import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking

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
        /// 삭제 확인 alert — confirm 시 서버 soft delete + 로컬 hard delete 후 화면 pop.
        @Presents public var deleteAlert: AlertState<Action.Alert>?

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
        // 삭제 — 더보기 메뉴 → 확인 alert → 서버 soft delete + 로컬 hard delete → 화면 pop.
        case deleteButtonTapped
        case deleteAlert(PresentationAction<Alert>)
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete
        }
        public enum Delegate: Equatable, Sendable {
            case deleted
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient

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

            case .deleteButtonTapped:
                state.deleteAlert = AlertState {
                    TextState("기록을 삭제할까요?")
                } actions: {
                    ButtonState(role: .destructive, action: .confirmDelete) { TextState("삭제") }
                    ButtonState(role: .cancel) { TextState("취소") }
                } message: {
                    TextState("삭제한 기록은 되돌릴 수 없어요.")
                }
                return .none

            case .deleteAlert(.presented(.confirmDelete)):
                guard let item = state.mochiItem else { return .none }
                let localID = item.id
                // 업로드된(서버에 존재하는) 항목만 서버 soft delete. 미업로드면 로컬만 지운다.
                let serverID: UUID? = {
                    if case let .uploaded(sid, _) = item.syncState { return sid }
                    return nil
                }()
                return .run { send in
                    do {
                        if let serverID {
                            try await apiClient.deleteMochiItem(mochiServerID: serverID)
                        }
                        try await repository.delete(id: localID)
                        await send(.delegate(.deleted))
                    } catch {
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .deleteAlert:
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$deleteAlert, action: \.deleteAlert)
    }
}
