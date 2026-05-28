import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

@Reducer
public struct InboxFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var captures: IdentifiedArrayOf<Capture> = []
        public var filter: Intent? = nil
        public var isLoading: Bool = false
        public var lastError: String?

        public init() {}
    }

    public enum Action: Sendable {
        case onAppear
        case filterChanged(Intent?)
        case capturesLoaded([Capture])
        case loadFailed(String)
        case captureTapped(Capture.ID)
    }

    @Dependency(\.captureRepository) var repository

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { [filter = state.filter] send in
                    do {
                        let list: [Capture]
                        if let filter {
                            list = try await repository.listByIntent(filter, limit: 100)
                        } else {
                            list = try await repository.listRecent(limit: 100)
                        }
                        await send(.capturesLoaded(list))
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .filterChanged(intent):
                state.filter = intent
                return .send(.onAppear)

            case let .capturesLoaded(list):
                state.isLoading = false
                state.captures = IdentifiedArray(uniqueElements: list)
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case .captureTapped:
                return .none      // Navigation은 상위 RootFeature가 처리
            }
        }
    }
}

// Dependency key는 CorePersistence/Sources/CaptureRepositoryDI.swift에서 정의.
