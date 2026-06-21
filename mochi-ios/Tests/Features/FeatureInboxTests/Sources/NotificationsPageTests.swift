import XCTest
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
@testable import FeatureInbox

/// 알림 페이지 reducer 테스트 — 로드(예정/지난 둘 다), 탭 전환, veto 낙관 제거,
/// reschedule 낙관 반영(+원안 보존·재정렬). 예정 로직은 홈에서 이 feature 로 옮겨왔다.
@MainActor
final class NotificationsPageTests: XCTestCase {

    private func upcoming(
        eventID: UUID,
        fireAt: Date,
        kind: String = "deadline",
        title: String = "리포트 제출",
        originalFireAt: Date? = nil
    ) -> UpcomingNotificationDTO {
        UpcomingNotificationDTO(
            eventID: eventID,
            kind: kind,
            fireAt: fireAt,
            title: title,
            body: "내일이 마감이에요",
            originalFireAt: originalFireAt
        )
    }

    private func sent(
        eventID: UUID,
        sentAt: Date,
        openedAt: Date? = nil,
        dismissedAt: Date? = nil
    ) -> SentNotificationDTO {
        SentNotificationDTO(
            eventID: eventID,
            kind: "deadline",
            sentAt: sentAt,
            openedAt: openedAt,
            dismissedAt: dismissedAt,
            title: "리포트 제출",
            body: "어제가 마감이었어요"
        )
    }

    func test_onAppear_예정과_지난을_둘다_로드한다() async {
        let up = upcoming(eventID: UUID(1), fireAt: Date(timeIntervalSince1970: 10_000))
        let se = sent(eventID: UUID(2), sentAt: Date(timeIntervalSince1970: 5_000), openedAt: Date(timeIntervalSince1970: 5_100))
        let api = NotificationsStubAPIClient(upcoming: [up], sent: [se])

        let store = TestStore(initialState: NotificationsPageFeature.State()) {
            NotificationsPageFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.onAppear) { $0.isLoading = true }
        await store.receive(\.upcomingLoaded) {
            $0.isLoading = false
            $0.upcoming = [up]
        }
        await store.receive(\.sentLoaded) {
            $0.isLoading = false
            $0.sent = [se]
        }
    }

    func test_탭_전환() async {
        let store = TestStore(initialState: NotificationsPageFeature.State()) {
            NotificationsPageFeature()
        }
        await store.send(.binding(.set(\.selectedTab, .sent))) {
            $0.selectedTab = .sent
        }
    }

    func test_upcomingVetoed_낙관적_즉시제거_후_서버보고() async {
        let api = NotificationsStubAPIClient()
        let e1 = upcoming(eventID: UUID(1), fireAt: Date(timeIntervalSince1970: 1_000))
        let e2 = upcoming(eventID: UUID(2), fireAt: Date(timeIntervalSince1970: 2_000), title: "치과 예약")

        var initial = NotificationsPageFeature.State()
        initial.upcoming = [e1, e2]
        let store = TestStore(initialState: initial) {
            NotificationsPageFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
        }

        await store.send(.upcomingVetoed(eventID: UUID(1))) {
            $0.upcoming = [e2]
        }
        await store.finish()
        let vetoed = await api.vetoed
        XCTAssertEqual(vetoed, [UUID(1)])
    }

    func test_upcomingVetoed_spaced도_동일경로로_낙관제거() async {
        // spaced 도 예정 목록에 섞여 들어오고, veto 시 reducer 는 deadline 과 동일 경로
        // (낙관 제거 + 서버 보고)로 다룬다. "이번 회차만" 의미 분기는 백엔드가 담당.
        let api = NotificationsStubAPIClient()
        let deadline = upcoming(eventID: UUID(1), fireAt: Date(timeIntervalSince1970: 1_000))
        let spaced = upcoming(
            eventID: UUID(2),
            fireAt: Date(timeIntervalSince1970: 2_000),
            kind: "spaced",
            title: "Swift Concurrency 정리"
        )

        var initial = NotificationsPageFeature.State()
        initial.upcoming = [deadline, spaced]
        let store = TestStore(initialState: initial) {
            NotificationsPageFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
        }

        await store.send(.upcomingVetoed(eventID: UUID(2))) {
            $0.upcoming = [deadline]
        }
        await store.finish()
        let vetoed = await api.vetoed
        XCTAssertEqual(vetoed, [UUID(2)])
    }

    func test_upcomingRescheduled_낙관적_새시각_반영_원안보존_재정렬() async {
        let api = NotificationsStubAPIClient()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 3_000)
        let newer = Date(timeIntervalSince1970: 5_000)
        let e1 = upcoming(eventID: UUID(1), fireAt: early)
        let e2 = upcoming(eventID: UUID(2), fireAt: late, title: "치과 예약")

        var initial = NotificationsPageFeature.State()
        initial.upcoming = [e1, e2]
        let store = TestStore(initialState: initial) {
            NotificationsPageFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
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

private actor NotificationsStubAPIClient: MochiAPIClient {
    private let upcomingFeed: [UpcomingNotificationDTO]
    private let sentFeed: [SentNotificationDTO]
    private(set) var vetoed: [UUID] = []
    private(set) var rescheduled: [RescheduleCall] = []

    init(upcoming: [UpcomingNotificationDTO] = [], sent: [SentNotificationDTO] = []) {
        self.upcomingFeed = upcoming
        self.sentFeed = sent
    }

    func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO] { upcomingFeed }
    func sentNotifications(limit: Int) async throws -> [SentNotificationDTO] { sentFeed }
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
    func logItemAccess(mochiServerID: UUID, source: ItemAccessSource) async throws {
        try await unimplemented.logItemAccess(mochiServerID: mochiServerID, source: source)
    }
    func updateMochiItem(mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO) async throws -> MochiItemDTO {
        try await unimplemented.updateMochiItem(mochiServerID: mochiServerID, request)
    }
    func upcomingActionables() async throws -> [UpcomingActionableDTO] {
        try await unimplemented.upcomingActionables()
    }
    func monthlyDigest(monthStart: Date) async throws -> MonthlyDigestDTO {
        try await unimplemented.monthlyDigest(monthStart: monthStart)
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
