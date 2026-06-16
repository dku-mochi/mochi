import XCTest
import CoreDomain
import CoreNetworking
@testable import CorePersistence

/// pull(서버→로컬 복구) ↔ upload 경합이 만든 로컬 중복 행 정리 회귀 테스트.
///
/// 근원: `uploadOne` 의 서버 commit 과 로컬 `updateSync(.uploaded)` 사이 actor reentrancy 틈에
/// `pullRemote` 가 같은 캡처를 "로컬에 없는 서버 항목"으로 오인해 server-id PK 행으로 한 번 더
/// insert 한다 — 같은 캡처가 로컬에 2행(서버 DB 3개 ↔ 로컬 5개, 2026-06-11 사용자 리포트).
final class MochiItemSyncWorkerDedupTests: XCTestCase {

    /// 업로드 완료 시점 정리: ingest 응답의 serverID 와 PK 가 같은 행(경합 pull 의 복제본)이
    /// 이미 있으면 지우고, 로컬 origin 행을 정본으로 남긴다.
    func test_uploadOne_removes_pull_duplicate_row_with_server_id_pk() async throws {
        let repo = InMemoryMochiItemRepository()
        let serverID = UUID()
        let localItem = MochiItem(source: IngestSource(channel: .appDirectInput, text: "너드킹 추천 리스트"))
        try await repo.upsert(localItem)
        // 경합 pull 이 미리 박아둔 복제 행 — 복구 항목 규약대로 server id 를 PK 로 채택한 형태.
        let duplicate = MochiItem(
            source: IngestSource(id: serverID, channel: .appDirectInput, text: "너드킹 추천 리스트"),
            syncState: .uploaded(serverID: serverID, at: Date())
        )
        try await repo.upsert(duplicate)

        let api = StubSyncAPIClient()
        await api.setIngestResult(Self.dto(id: serverID, text: "너드킹 추천 리스트"))
        let worker = MochiItemSyncWorker(repository: repo, apiClient: api, tokenProvider: FixedTokenProvider())
        await worker.runOnce()

        let remaining = try await repo.listRecent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [localItem.id], "복제 행은 사라지고 로컬 origin 행만 남아야 함")
        guard case let .uploaded(uploadedServerID, _)? = remaining.first?.syncState else {
            return XCTFail("로컬 origin 행이 uploaded(serverID) 로 전이돼야 함")
        }
        XCTAssertEqual(uploadedServerID, serverID)
    }

    /// pull 시점 정리: 과거 경합이 남긴 중복 쌍(로컬 origin 행 + 그 serverID 를 PK 로 쓰는 행)을
    /// 발견하면 복제본을 지우고, 같은 서버 항목을 다시 insert 하지 않는다.
    func test_pullRemote_heals_existing_duplicate_pair_and_skips_reinsert() async throws {
        let repo = InMemoryMochiItemRepository()
        let serverID = UUID()
        let localItem = MochiItem(
            source: IngestSource(channel: .appDirectInput, text: "너드킹 추천 리스트"),
            syncState: .uploaded(serverID: serverID, at: Date())
        )
        try await repo.upsert(localItem)
        let duplicate = MochiItem(
            source: IngestSource(id: serverID, channel: .appDirectInput, text: "너드킹 추천 리스트"),
            syncState: .uploaded(serverID: serverID, at: Date())
        )
        try await repo.upsert(duplicate)

        let api = StubSyncAPIClient()
        await api.setListResult([Self.dto(id: serverID, text: "너드킹 추천 리스트")])
        let worker = MochiItemSyncWorker(repository: repo, apiClient: api, tokenProvider: FixedTokenProvider())
        await worker.pullRemote()

        let remaining = try await repo.listRecent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [localItem.id], "복제 행 정리 후 재insert 도 없어야 함")
    }

    /// 진짜 복구 시나리오(재설치 — 로컬이 빈 상태)는 정리 로직의 영향 없이 그대로 insert 돼야 한다.
    func test_pullRemote_still_recovers_unknown_server_items() async throws {
        let repo = InMemoryMochiItemRepository()
        let serverID = UUID()
        let api = StubSyncAPIClient()
        await api.setListResult([Self.dto(id: serverID, text: "너드킹 추천 리스트")])
        let worker = MochiItemSyncWorker(repository: repo, apiClient: api, tokenProvider: FixedTokenProvider())
        await worker.pullRemote()

        let remaining = try await repo.listRecent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [serverID], "로컬에 없는 서버 항목은 server-id PK 로 복구돼야 함")
    }

    private static func dto(id: UUID, text: String) -> MochiItemDTO {
        MochiItemDTO(
            id: id, channel: .appDirectInput, url: nil, text: text, userMemo: nil,
            summary: nil, category: nil, importance: 2, intentInstances: [],
            needsReview: false, reviewOptions: [], lifecycleKind: "ingested", syncKind: "synced",
            imageRefs: [], capturedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

// MARK: - Stubs

private struct FixedTokenProvider: AuthTokenProvider {
    func bearerToken() async -> String? { "test-token" }
}

/// 필요한 메서드(ingest/list)만 제어하고 나머지는 NotConfigured 에러로 던지는 스텁.
private actor StubSyncAPIClient: MochiAPIClient {
    private var ingestResult: MochiItemDTO?
    private var listResult: [MochiItemDTO] = []

    func setIngestResult(_ dto: MochiItemDTO) { ingestResult = dto }
    func setListResult(_ dtos: [MochiItemDTO]) { listResult = dtos }

    func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        guard let ingestResult else {
            return try await unimplemented.ingestMochiItem(request, idempotencyKey: idempotencyKey)
        }
        return ingestResult
    }

    func listMochiItems(limit: Int) async throws -> [MochiItemDTO] { listResult }

    // 미사용 표면 — 호출되면 테스트가 즉시 드러나게 NotConfigured 에 위임.
    private let unimplemented = NotConfiguredAPIClient()
    func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        try await unimplemented.presignCaptureUpload(sha256: sha256, mimeType: mimeType)
    }
    func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws {
        try await unimplemented.putCaptureImage(uploadURL: uploadURL, data: data, mimeType: mimeType)
    }
    func getMochiItem(id: UUID) async throws -> MochiItemDTO {
        try await unimplemented.getMochiItem(id: id)
    }
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
    func updateMochiItem(mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO) async throws -> MochiItemDTO {
        try await unimplemented.updateMochiItem(mochiServerID: mochiServerID, request)
    }
    func deleteMochiItem(mochiServerID: UUID) async throws {
        try await unimplemented.deleteMochiItem(mochiServerID: mochiServerID)
    }
    func setFavorite(mochiServerID: UUID, isFavorite: Bool) async throws -> MochiItemDTO {
        try await unimplemented.setFavorite(mochiServerID: mochiServerID, isFavorite: isFavorite)
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
