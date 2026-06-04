import XCTest
import CoreDomain
@testable import CorePersistence

/// 홈 버킷 분기: `listAnalyzing`(분석 전) vs `listNeedsReview`(분석됨 & 모찌가 확신 못 함) 검증 (InMemory).
final class AmbiguousAnalyzingBucketTests: XCTestCase {

    private func inst(_ intent: Intent) -> IntentInstance { IntentInstance(intentType: intent) }

    private func analyzed(
        needsReview: Bool,
        _ instances: [IntentInstance],
        reviewOptions: [ReviewOption] = []
    ) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: "s",
            instances: instances,
            needsReview: needsReview,
            reviewOptions: reviewOptions,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .medium,
            modelVersion: "test",
            analyzedAt: .init()
        )
    }

    func test_unanalyzed_item_is_analyzing_not_needsReview() async throws {
        let repo = InMemoryMochiItemRepository()
        let item = MochiItem(source: IngestSource(channel: .appDirectInput, text: "대기 중"))
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let needsReview = try await repo.listNeedsReview(limit: 10)
        XCTAssertEqual(analyzing.map(\.id), [item.id])
        XCTAssertTrue(needsReview.isEmpty)
    }

    func test_uncertain_analyzed_item_is_needsReview_not_analyzing() async throws {
        let repo = InMemoryMochiItemRepository()
        let analysis = analyzed(needsReview: true, [inst(.memo)])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .analyzed)
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let needsReview = try await repo.listNeedsReview(limit: 10)
        XCTAssertTrue(analyzing.isEmpty)
        XCTAssertEqual(needsReview.map(\.id), [item.id])
    }

    func test_confident_analyzed_item_is_in_neither_bucket() async throws {
        let repo = InMemoryMochiItemRepository()
        let analysis = analyzed(needsReview: false, [inst(.schedule)])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .analyzed)
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let needsReview = try await repo.listNeedsReview(limit: 10)
        XCTAssertTrue(analyzing.isEmpty)
        XCTAssertTrue(needsReview.isEmpty)
    }

    func test_requeueForAnalysis_returns_demoted_item_to_analyzing() async throws {
        let repo = InMemoryMochiItemRepository()
        // 강등 상태 모사: needsReview=true + reviewOptions 비어 있음(의견 없음).
        let demoted = analyzed(needsReview: true, [inst(.knowledge)])
        let serverID = UUID()
        let item = MochiItem(
            source: IngestSource(channel: .appShareSheet, url: URL(string: "https://youtu.be/x")),
            analysis: demoted,
            lifecycleState: .analyzed,
            syncState: .uploaded(serverID: serverID, at: Date())
        )
        try await repo.upsert(item)

        let needsReviewBefore = try await repo.listNeedsReview(limit: 10)
        XCTAssertEqual(needsReviewBefore.map(\.id), [item.id])
        XCTAssertTrue(needsReviewBefore.first?.analysis?.reviewOptions.isEmpty ?? false)

        try await repo.requeueForAnalysis(mochiItemID: item.id)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let needsReviewAfter = try await repo.listNeedsReview(limit: 10)
        XCTAssertEqual(analyzing.map(\.id), [item.id])
        XCTAssertTrue(needsReviewAfter.isEmpty)
        let reloaded = try await repo.find(id: item.id)
        XCTAssertNil(reloaded?.analysis)
        // serverID 는 보존되어야 재폴링이 가능.
        guard case let .uploaded(sid, _) = reloaded?.syncState else {
            return XCTFail("requeue 후에도 .uploaded(serverID:) 여야 함")
        }
        XCTAssertEqual(sid, serverID)
    }

    func test_setIntent_clears_needsReview() async throws {
        let repo = InMemoryMochiItemRepository()
        let analysis = analyzed(needsReview: true, [inst(.memo), inst(.todo)])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .analyzed)
        try await repo.upsert(item)
        let beforeCount = try await repo.listNeedsReview(limit: 10).count
        XCTAssertEqual(beforeCount, 1)

        try await repo.setIntent(mochiItemID: item.id, intent: .todo)

        let afterNeedsReview = try await repo.listNeedsReview(limit: 10)
        XCTAssertTrue(afterNeedsReview.isEmpty)
        let confirmed = try await repo.find(id: item.id)
        XCTAssertEqual(confirmed?.representativeIntent, .todo)
        XCTAssertFalse(confirmed?.needsReview ?? true)
    }
}
