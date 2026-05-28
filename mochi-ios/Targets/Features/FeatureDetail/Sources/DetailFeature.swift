import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreIntegrations

@Reducer
public struct DetailFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var captureID: UUID
        public var capture: Capture?
        public var isSyncing: Bool = false
        public var lastError: String?

        public init(captureID: UUID) { self.captureID = captureID }
    }

    public enum Action: Sendable {
        case onAppear
        case loaded(Capture?)
        case archiveTapped(LifecycleState.ArchiveReason)
        case syncToCalendarTapped
        case operationFailed(String)
    }

    @Dependency(\.captureRepository) var repository
    @Dependency(\.calendarSyncer)    var calendar

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { [id = state.captureID] send in
                    let capture = try await repository.find(id: id)
                    await send(.loaded(capture))
                }

            case let .loaded(capture):
                state.capture = capture
                return .none

            case let .archiveTapped(reason):
                guard let capture = state.capture else { return .none }
                return .run { send in
                    do {
                        try await repository.updateLifecycle(captureID: capture.id, to: .archived(reason: reason))
                    } catch {
                        await send(.operationFailed(String(describing: error)))
                    }
                }

            case .syncToCalendarTapped:
                guard let capture = state.capture,
                      let analysis = capture.analysis,
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
