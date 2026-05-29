import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

@Reducer
public struct InboxFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var mochiItems: IdentifiedArrayOf<MochiItem> = []
        public var filter: Intent? = nil
        public var isLoading: Bool = false
        public var lastError: String?

        public init() {}
    }

    public enum Action: Sendable {
        case onAppear
        case refresh
        case filterChanged(Intent?)
        case mochiItemsLoaded([MochiItem])
        case loadFailed(String)
        case mochiItemTapped(MochiItem.ID)
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.syncTrigger) var syncTrigger

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { [filter = state.filter] send in
                    do {
                        let list: [MochiItem]
                        if let filter {
                            list = try await repository.listByIntent(filter, limit: 100)
                        } else {
                            list = try await repository.listRecent(limit: 100)
                        }
                        await send(.mochiItemsLoaded(list))
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .refresh:
                // pull-to-refresh — sync worker 를 즉시 trigger 후 list 재조회.
                // 미인증 또는 네트워크 실패 시 worker 가 no-op 또는 .syncFailed marking 만.
                return .run { [filter = state.filter] send in
                    await syncTrigger.runOnce()
                    do {
                        let list: [MochiItem]
                        if let filter {
                            list = try await repository.listByIntent(filter, limit: 100)
                        } else {
                            list = try await repository.listRecent(limit: 100)
                        }
                        await send(.mochiItemsLoaded(list))
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .filterChanged(intent):
                state.filter = intent
                return .send(.onAppear)

            case let .mochiItemsLoaded(list):
                state.isLoading = false
                state.mochiItems = IdentifiedArray(uniqueElements: list)
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case .mochiItemTapped:
                return .none      // Navigation은 상위 RootFeature가 처리
            }
        }
    }
}

// Dependency key는 CorePersistence/Sources/MochiItemRepositoryDI.swift에서 정의.
