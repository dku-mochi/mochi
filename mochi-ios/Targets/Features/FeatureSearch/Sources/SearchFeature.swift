import Foundation
import ComposableArchitecture
import CoreDomain
import CoreNetworking

@Reducer
public struct SearchFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var query: String = ""
        /// `Store.scope(state:action:)` 메서드와 이름이 충돌하면 `@Bindable` 의 `$store.scope`
        /// 가 메서드 시그니처로 잘못 추론되어 컴파일 실패한다. 그래서 `selectedScope` 로 명명.
        public var selectedScope: SearchScope = .all
        public var response: SearchResponse?
        public var isSearching: Bool = false
        public var lastError: String?

        public init() {}
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case submit
        case response(Result<SearchResponse, APIErrorEnvelope>)
    }

    @Dependency(\.mochiAPIClient) var api

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
            case .submit:
                guard !state.query.isEmpty else { return .none }
                state.isSearching = true
                let query = state.query
                let scope = state.selectedScope
                return .run { send in
                    do {
                        let response = try await api.search(query: query, scope: scope)
                        await send(.response(.success(response)))
                    } catch let envelope as APIErrorEnvelope {
                        await send(.response(.failure(envelope)))
                    } catch {
                        await send(.response(.failure(.init(
                            code: "client.unknown",
                            message: String(describing: error),
                            requestID: "n/a",
                            retryAfter: nil
                        ))))
                    }
                }
            case let .response(.success(response)):
                state.isSearching = false
                state.response = response
                return .none
            case let .response(.failure(envelope)):
                state.isSearching = false
                state.lastError = "[\(envelope.code)] \(envelope.message)"
                return .none
            }
        }
    }
}

// Dependency key는 CoreNetworking/Sources/MochiAPIClientDI.swift에서 정의.
