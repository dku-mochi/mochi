import Foundation
import ComposableArchitecture
import CoreDomain

@Reducer
public struct SettingsFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var serverEndpoint: String = "https://api.mochi.local/api/v1"
        public var calendarSyncEnabled: Bool = true
        public var reminderSyncEnabled: Bool = true
        public init() {}
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
    }
}
