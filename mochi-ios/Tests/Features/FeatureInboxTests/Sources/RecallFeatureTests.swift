import XCTest
import ComposableArchitecture
import CoreDomain
import CoreNetworking
@testable import FeatureInbox

/// 능동 회수 reducer 테스트 — 피드 로드(빈손/채움), 액션↔reaction 1:1 매핑, landing fetch, 상세 응답.
@MainActor
final class RecallFeatureTests: XCTestCase {

    private let itemID = UUID(1)
    private let eventID = UUID(2)

    private func entry(
        kind: String = "knowledge",
        reason: String = "fadingValue",
        recallEventID: UUID? = nil,
        relatedCount: Int = 1,
        gist: [String] = ["핵심 한 줄"]
    ) -> RecallFeedEntryDTO {
        RecallFeedEntryDTO(
            itemID: itemID, kind: kind, reason: reason,
            title: "RAG Hybrid", oneline: "한 달째 안 펼쳐보셨어요",
            source: "medium", savedAt: Date(timeIntervalSince1970: 0),
            gist: gist, related: [], relatedCount: relatedCount, recallEventID: recallEventID
        )
    }

    // MARK: - ② 목록 로드

    func test_list_onAppear_빈손이면_빈목록_정상() async {
        let api = RecallStubAPIClient(feed: [])
        let store = TestStore(initialState: RecallListFeature.State()) {
            RecallListFeature()
        } withDependencies: { $0.mochiAPIClient = api }

        await store.send(.onAppear) { $0.isLoading = true }
        await store.receive(\.feedLoaded) {
            $0.isLoading = false
            $0.entries = []
        }
    }

    func test_list_onAppear_피드를_로드한다() async {
        let e = entry()
        let api = RecallStubAPIClient(feed: [e])
        let store = TestStore(initialState: RecallListFeature.State()) {
            RecallListFeature()
        } withDependencies: { $0.mochiAPIClient = api }

        await store.send(.onAppear) { $0.isLoading = true }
        await store.receive(\.feedLoaded) {
            $0.isLoading = false
            $0.entries = [e]
        }
    }

    func test_list_entryTapped_상세열기_delegate() async {
        let e = entry()
        let store = TestStore(initialState: RecallListFeature.State(entries: [e])) {
            RecallListFeature()
        }
        // 이미 피드를 들고 있으면 isLoading 토글 없이 백그라운드 최신화만.
        await store.send(.entryTapped(e))
        await store.receive(\.delegate.openDetail)
    }

    // MARK: - ③ 상세 — 액션 ↔ reaction 1:1

    func test_detail_onAppear_탭진입은_opened로_보고() async {
        let api = RecallStubAPIClient(feed: [])
        let store = TestStore(initialState: RecallDetailFeature.State(entry: entry(recallEventID: eventID))) {
            RecallDetailFeature()
        } withDependencies: { $0.mochiAPIClient = api }

        await store.send(.onAppear)
        await store.receive(\.markReportedOpen) { $0.hasReportedOpen = true }
        await store.finish()
        let reactions = await api.reactions
        XCTAssertEqual(reactions, [Reaction(eventID: eventID, reaction: .opened)])
    }

    func test_detail_onAppear_recallEventID없으면_보고생략() async {
        let api = RecallStubAPIClient(feed: [])
        let store = TestStore(initialState: RecallDetailFeature.State(entry: entry(recallEventID: nil))) {
            RecallDetailFeature()
        } withDependencies: { $0.mochiAPIClient = api }

        await store.send(.onAppear)   // 효과 없음
        let reactions = await api.reactions
        XCTAssertTrue(reactions.isEmpty)
    }

    func test_detail_landing진입은_onAppear에서_중복보고_안함() async {
        // 알림 landing 은 탭 시점에 상위가 이미 opened 보고 → 상세 onAppear 는 중복 보고 생략.
        let api = RecallStubAPIClient(feed: [])
        let store = TestStore(
            initialState: RecallDetailFeature.State(entry: entry(recallEventID: eventID), alreadyReportedOpen: true)
        ) { RecallDetailFeature() } withDependencies: { $0.mochiAPIClient = api }

        await store.send(.onAppear)   // hasReportedOpen 이 이미 true → 효과 없음
        let reactions = await api.reactions
        XCTAssertTrue(reactions.isEmpty)
    }

    func test_detail_그만보기는_stop으로_보고() async {
        let api = RecallStubAPIClient(feed: [])
        let clock = TestClock()
        let store = TestStore(initialState: RecallDetailFeature.State(entry: entry(recallEventID: eventID))) {
            RecallDetailFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.continuousClock = clock
        }

        await store.send(.stopTapped) { $0.didStop = true }
        await store.receive(\.showToast) { $0.toast = "이 기억은 더 꺼내지 않을게요" }
        // 홈 회수 히어로에서 이 카드를 빼라는 제거 신호(상위가 recallDetailClosed 로 전달).
        await store.receive(\.delegate.stopped, itemID)
        await clock.advance(by: .seconds(1.6))
        await store.receive(\.dismissToast) { $0.toast = nil }

        let reactions = await api.reactions
        XCTAssertEqual(reactions, [Reaction(eventID: eventID, reaction: .stop)])
    }

    func test_detail_기억났어요는_opened로_보고() async {
        let api = RecallStubAPIClient(feed: [])
        let clock = TestClock()
        let store = TestStore(initialState: RecallDetailFeature.State(entry: entry(recallEventID: eventID))) {
            RecallDetailFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.continuousClock = clock
        }

        await store.send(.rememberedTapped)
        await store.receive(\.showToast) { $0.toast = "좋아요 · 다음엔 더 늦게 꺼낼게요" }
        await clock.advance(by: .seconds(1.6))
        await store.receive(\.dismissToast) { $0.toast = nil }

        let reactions = await api.reactions
        XCTAssertEqual(reactions, [Reaction(eventID: eventID, reaction: .opened)])
    }

    func test_detail_원본보기_delegate로_위임() async {
        let store = TestStore(initialState: RecallDetailFeature.State(entry: entry(recallEventID: nil))) {
            RecallDetailFeature()
        }
        await store.send(.openOriginalTapped)
        await store.receive(\.delegate.openOriginal)
    }

    func test_detail_그만보기는_중복탭_무시() async {
        let api = RecallStubAPIClient(feed: [])
        let clock = TestClock()
        var state = RecallDetailFeature.State(entry: entry(recallEventID: eventID))
        state.didStop = true   // 이미 그만 누른 상태
        let store = TestStore(initialState: state) {
            RecallDetailFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.continuousClock = clock
        }
        await store.send(.stopTapped)   // no-op
        let reactions = await api.reactions
        XCTAssertTrue(reactions.isEmpty)
    }

    // MARK: - reason 매핑

    func test_reason_미지의값은_fadingValue로_안전강등() {
        XCTAssertEqual(RecallReasonKind(reason: "wat"), .fadingValue)
        XCTAssertEqual(RecallReasonKind(reason: "linkedToRecent"), .linkedToRecent)
    }
}

// MARK: - Stub

private struct Reaction: Equatable {
    let eventID: UUID
    let reaction: RecallReaction
}

private actor RecallStubAPIClient: MochiAPIClient {
    let feed: [RecallFeedEntryDTO]
    let landing: RecallFeedEntryDTO?
    private(set) var reactions: [Reaction] = []

    init(feed: [RecallFeedEntryDTO], landing: RecallFeedEntryDTO? = nil) {
        self.feed = feed
        self.landing = landing
    }

    func recallFeed(limit: Int) async throws -> [RecallFeedEntryDTO] { feed }
    func recallLanding(eventID: UUID) async throws -> RecallFeedEntryDTO {
        guard let landing else { throw NotConfiguredAPIClient().asError() }
        return landing
    }
    func recordRecallReaction(eventID: UUID, reaction: RecallReaction) async throws {
        reactions.append(Reaction(eventID: eventID, reaction: reaction))
    }

    // 미사용 표면 — 호출되면 테스트가 드러나게 NotConfigured 에 위임.
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
    func monthlyDigest(monthStart: Date) async throws -> MonthlyDigestDTO {
        try await unimplemented.monthlyDigest(monthStart: monthStart)
    }
    func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO] {
        try await unimplemented.upcomingNotifications(limit: limit)
    }
    func rescheduleUpcoming(eventID: UUID, fireAt: Date) async throws {
        try await unimplemented.rescheduleUpcoming(eventID: eventID, fireAt: fireAt)
    }
    func vetoUpcoming(eventID: UUID) async throws {
        try await unimplemented.vetoUpcoming(eventID: eventID)
    }
    func sentNotifications(limit: Int) async throws -> [SentNotificationDTO] {
        try await unimplemented.sentNotifications(limit: limit)
    }
}

private extension NotConfiguredAPIClient {
    func asError() -> Error {
        APIErrorEnvelope(code: "test.not_configured", message: "", requestID: "n/a", retryAfter: nil)
    }
}
