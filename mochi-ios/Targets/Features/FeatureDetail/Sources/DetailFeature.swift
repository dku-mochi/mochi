import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreIntegrations

@Reducer
public struct DetailFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var mochiItemID: UUID
        public var mochiItem: MochiItem?
        public var isSyncing: Bool = false
        public var lastError: String?

        public init(mochiItemID: UUID) { self.mochiItemID = mochiItemID }
    }

    public enum Action: Sendable {
        case onAppear
        case loaded(MochiItem?)
        case archiveTapped(instanceID: UUID, reason: InstanceLifecycle.ArchiveReason)
        case syncToCalendarTapped
        case operationFailed(String)
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.calendarSyncer)    var calendar

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

            case .syncToCalendarTapped:
                guard let mochiItem = state.mochiItem,
                      let analysis = mochiItem.analysis,
                      let candidate = analysis.actionCandidates.first(where: { if case .createCalendarEvent = $0 { return true } else { return false } })
                else { return .none }
                state.isSyncing = true
                return .run { send in
                    do {
                        try await calendar.requestEventAccess()
                        if case let .createCalendarEvent(title, startISO, endISO) = candidate {
                            let formatter = ISO8601DateFormatter()
                            guard let start = formatter.date(from: startISO) else {
                                await send(.operationFailed("invalid startISO"))
                                return
                            }
                            let end = endISO.flatMap(formatter.date(from:))
                            _ = try await calendar.createEvent(title: title, start: start, end: end)
                        }
                    } catch {
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case let .operationFailed(message):
                state.isSyncing = false
                state.lastError = message
                return .none
            }
        }
    }
}

// Dependency key는 CoreIntegrations/Sources/CalendarSyncerDI.swift에서 정의.
