import XCTest
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
@testable import FeatureInbox

/// 홈 "예정된 알림" reducer 테스트 — 로드 반영, veto 낙관 제거, reschedule 낙관 반영(+원안 보존·재정렬).
@MainActor
final class MochiHomeUpcomingTests: XCTestCase {

    private func entry(
        eventID: UUID,
        fireAt: Date,
        title: String = "리포트 제출",
        originalFireAt: Date? = nil
    ) -> UpcomingNotificationDTO {
        UpcomingNotificationDTO(
            eventID: eventID,
            kind: "deadline",
            fireAt: fireAt,
            title: title,
            body: "내일이 마감이에요",
            originalFireAt: originalFireAt
        )
    }

    func test_upcomingLoaded_상태에_반영된다() async {
        let store = TestStore(initialState: MochiHomeFeature.State()) {
            MochiHomeFeature()
        } withDependencies: {
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let e = entry(eventID: UUID(1), fireAt: Date(timeIntervalSince1970: 1_000))
        await store.send(.upcomingLoaded([e])) {
            $0.upcoming = [e]
        }
    }

    func test_upcomingVetoed_낙관적_즉시제거_후_서버보고() async {
        let api = UpcomingStubAPIClient()
        let e1 = entry(eventID: UUID(1), fireAt: Date(timeIntervalSince1970: 1_000))
        let e2 = entry(eventID: UUID(2), fireAt: Date(timeIntervalSince1970: 2_000), title: "치과 예약")

        var initial = MochiHomeFeature.State()
        initial.upcoming = [e1, e2]
        let store = TestStore(initialState: initial) {
            MochiHomeFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }

        await store.send(.upcomingVetoed(eventID: UUID(1))) {
            // 낙관적 — 즉시 제거(서버 응답 기다리지 않음).
            $0.upcoming = [e2]
        }
        await store.finish()
        let vetoed = await api.vetoed
        XCTAssertEqual(vetoed, [UUID(1)])
    }

    func test_upcomingRescheduled_낙관적_새시각_반영_원안보존_재정렬() async {
        let api = UpcomingStubAPIClient()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 3_000)
        let newer = Date(timeIntervalSince1970: 5_000)
        let e1 = entry(eventID: UUID(1), fireAt: early)
        let e2 = entry(eventID: UUID(2), fireAt: late, title: "치과 예약")

        var initial = MochiHomeFeature.State()
        initial.upcoming = [e1, e2]
        let store = TestStore(initialState: initial) {
            MochiHomeFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }

        // e1 을 e2 보다 뒤로 옮기면: 새 시각 반영 + 원안(early) 보존 + fire_at 오름차순 재정렬.
        await store.send(.upcomingRescheduled(eventID: UUID(1), fireAt: newer)) {
            let moved = UpcomingNotificationDTO(
                eventID: UUID(1),
                kind: "deadline",
                fireAt: newer,
                title: "리포트 제출",
                body: "내일이 마감이에요",
                originalFireAt: early
            )
            $0.upcoming = [e2, moved]
        }
        await store.finish()
        let rescheduled = await api.rescheduled
        XCTAssertEqual(rescheduled.count, 1)
        XCTAssertEqual(rescheduled.first?.eventID, UUID(1))
        XCTAssertEqual(rescheduled.first?.fireAt, newer)
    }
}

// MARK: - Stub

private struct RescheduleCall: Equatable {
    let eventID: UUID
    let fireAt: Date
}

private actor UpcomingStubAPIClient: MochiAPIClient {
    private(set) var vetoed: [UUID] = []
    private(set) var rescheduled: [RescheduleCall] = []

    func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO] { [] }
    func vetoUpcoming(eventID: UUID) async throws { vetoed.append(eventID) }
    func rescheduleUpcoming(eventID: UUID, fireAt: Date) async throws {
        rescheduled.append(RescheduleCall(eventID: eventID, fireAt: fireAt))
    }

    // 미사용 표면 — 호출되면 드러나게 NotConfigured 에 위임.
    private let unimplemented = NotConfiguredAPIClient()
    func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        try await unimplemented.ingestMochiItem(request, idempotencyKey: idempotencyKey)
    }
    func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        try await unimplemented.presignCaptureUpload(sha256: sha256, mimeType: mimeType)
    }
    func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws {
        try await unimplemented.putCaptureImage(uploadURL: uploadURL, data: data, mimeType: mimeType)
    }
    func getMochiItem(id: UUID) async throws -> MochiItemDTO { try await unimplemented.getMochiItem(id: id) }
    func listMochiItems(limit: Int) async throws -> [MochiItemDTO] { try await unimplemented.listMochiItems(limit: limit) }
    func presignCaptureDownload(objectKey: String) async throws -> URL {
        try await unimplemented.presignCaptureDownload(objectKey: objectKey)
    }
    func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        try await unimplemented.search(query: query, scope: scope)
    }
    func similarItems(serverID: UUID, limit: Int) async throws -> [SimilarItemRef] {
        try await unimplemented.similarItems(serverID: serverID, limit: limit)
    }
    func registerPushToken(token: String, kind: PushTokenKind, environment: PushEnvironment, mochiItemID: UUID?) async throws {
        try await unimplemented.registerPushToken(token: token, kind: kind, environment: environment, mochiItemID: mochiItemID)
    }
    func reanalyzeMochiItem(id: UUID, userHint: String) async throws {
        try await unimplemented.reanalyzeMochiItem(id: id, userHint: userHint)
    }
    func updateInstanceLifecycle(mochiServerID: UUID, instanceID: UUID, to newState: InstanceLifecycle) async throws -> MochiItemDTO {
        try await unimplemented.updateInstanceLifecycle(mochiServerID: mochiServerID, instanceID: instanceID, to: newState)
    }
    func deleteMochiItem(mochiServerID: UUID) async throws {
        try await unimplemented.deleteMochiItem(mochiServerID: mochiServerID)
    }
    func setFavorite(mochiServerID: UUID, isFavorite: Bool) async throws -> MochiItemDTO {
        try await unimplemented.setFavorite(mochiServerID: mochiServerID, isFavorite: isFavorite)
    }
    func updateMochiItem(mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO) async throws -> MochiItemDTO {
        try await unimplemented.updateMochiItem(mochiServerID: mochiServerID, request)
    }
    func upcomingActionables() async throws -> [UpcomingActionableDTO] {
        try await unimplemented.upcomingActionables()
    }
    func weeklyDigest(weekStart: Date) async throws -> WeeklyDigestDTO {
        try await unimplemented.weeklyDigest(weekStart: weekStart)
    }
    func recallFeed(limit: Int) async throws -> [RecallFeedEntryDTO] {
        try await unimplemented.recallFeed(limit: limit)
    }
    func recallLanding(eventID: UUID) async throws -> RecallFeedEntryDTO {
        try await unimplemented.recallLanding(eventID: eventID)
    }
    func recordRecallReaction(eventID: UUID, reaction: RecallReaction) async throws {
        try await unimplemented.recordRecallReaction(eventID: eventID, reaction: reaction)
    }
}
