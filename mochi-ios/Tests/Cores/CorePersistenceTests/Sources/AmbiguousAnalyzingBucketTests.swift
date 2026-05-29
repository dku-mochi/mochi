import XCTest
import CoreDomain
@testable import CorePersistence

/// 홈 버킷 분기: `listAnalyzing`(분석 전) vs `listAmbiguous`(분석됨 & 불확실) 검증 (InMemory).
final class AmbiguousAnalyzingBucketTests: XCTestCase {

    private func analyzed(confidence: Double, _ candidates: [IntentCandidate]) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: "s",
            intent: candidates.first?.intent ?? .memo,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .medium,
            confidence: confidence,
            modelVersion: "test",
            analyzedAt: .init(),
            candidates: candidates
        )
    }

    func test_unanalyzed_item_is_analyzing_not_ambiguous() async throws {
        let repo = InMemoryMochiItemRepository()
        let item = MochiItem(source: IngestSource(channel: .appDirectInput, text: "대기 중"))
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let ambiguous = try await repo.listAmbiguous(limit: 10)
        XCTAssertEqual(analyzing.map(\.id), [item.id])
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func test_uncertain_analyzed_item_is_ambiguous_not_analyzing() async throws {
        let repo = InMemoryMochiItemRepository()
        // confidence 낮음 → 헷갈려요.
        let analysis = analyzed(confidence: 0.3, [IntentCandidate(label: nil, intent: .memo, applicability: 0.5)])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .active)
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let ambiguous = try await repo.listAmbiguous(limit: 10)
        XCTAssertTrue(analyzing.isEmpty)
        XCTAssertEqual(ambiguous.map(\.id), [item.id])
    }

    func test_confident_analyzed_item_is_in_neither_bucket() async throws {
        let repo = InMemoryMochiItemRepository()
        let analysis = analyzed(confidence: 0.95, [IntentCandidate(label: nil, intent: .schedule, applicability: 0.95)])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .active)
        try await repo.upsert(item)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let ambiguous = try await repo.listAmbiguous(limit: 10)
        XCTAssertTrue(analyzing.isEmpty)
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func test_requeueForAnalysis_returns_demoted_item_to_analyzing() async throws {
        let repo = InMemoryMochiItemRepository()
        // 강등 상태 모사: confidence 0 + 후보 없음 → 헷갈려요(의견 없음).
        let demoted = analyzed(confidence: 0, [])
        let serverID = UUID()
        let item = MochiItem(
            source: IngestSource(channel: .appShareSheet, url: URL(string: "https://youtu.be/x")),
            analysis: demoted,
            lifecycleState: .active,
            syncState: .uploaded(serverID: serverID, at: Date())
        )
        try await repo.upsert(item)

        let ambiguousBefore = try await repo.listAmbiguous(limit: 10)
        XCTAssertEqual(ambiguousBefore.map(\.id), [item.id])
        XCTAssertTrue(ambiguousBefore.first?.analysis?.reviewOpinions.isEmpty ?? false)

        try await repo.requeueForAnalysis(mochiItemID: item.id)

        let analyzing = try await repo.listAnalyzing(limit: 10)
        let ambiguousAfter = try await repo.listAmbiguous(limit: 10)
        XCTAssertEqual(analyzing.map(\.id), [item.id])
        XCTAssertTrue(ambiguousAfter.isEmpty)
        let reloaded = try await repo.find(id: item.id)
        XCTAssertNil(reloaded?.analysis)
        // serverID 는 보존되어야 재폴링이 가능.
        guard case let .uploaded(sid, _) = reloaded?.syncState else {
            return XCTFail("requeue 후에도 .uploaded(serverID:) 여야 함")
        }
        XCTAssertEqual(sid, serverID)
    }

    func test_setIntent_clears_ambiguity() async throws {
        let repo = InMemoryMochiItemRepository()
        let analysis = analyzed(confidence: 0.3, [
            IntentCandidate(label: nil, intent: .memo, applicability: 0.5),
            IntentCandidate(label: nil, intent: .todo, applicability: 0.45),
        ])
        let item = MochiItem(source: IngestSource(channel: .screenshot), analysis: analysis, lifecycleState: .active)
        try await repo.upsert(item)
        let beforeCount = try await repo.listAmbiguous(limit: 10).count
        XCTAssertEqual(beforeCount, 1)

        try await repo.setIntent(mochiItemID: item.id, intent: .todo)

        let afterAmbiguous = try await repo.listAmbiguous(limit: 10)
        XCTAssertTrue(afterAmbiguous.isEmpty)
        let confirmed = try await repo.find(id: item.id)
        XCTAssertEqual(confirmed?.intent, .todo)
        XCTAssertEqual(confirmed?.analysis?.confidence, 1.0)
    }
}
