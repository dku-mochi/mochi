import XCTest
import CoreDomain
@testable import CorePersistence

final class InMemoryRepositoryTests: XCTestCase {
    func test_upsert_and_listRecent_returns_inserted_capture() async throws {
        let repo = InMemoryMochiItemRepository()
        let mochiItem = MochiItem(source: IngestSource(channel: .appDirectInput, text: "hello"))
        try await repo.upsert(mochiItem)
        let recent = try await repo.listRecent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.source.text, "hello")
    }

    func test_updateLifecycle_rejects_illegal_transition_for_memo() async throws {
        let repo = InMemoryMochiItemRepository()
        let source = IngestSource(channel: .appDirectInput, text: "memo")
        let analysis = MochiItemAnalysis(
            summary: "s", intent: .memo, entities: [], actionCandidates: [],
            tags: [], importance: .medium, confidence: 0.9,
            modelVersion: "test", analyzedAt: .init()
        )
        let mochiItem = MochiItem(source: source, analysis: analysis, lifecycleState: .active)
        try await repo.upsert(mochiItem)

        do {
            try await repo.updateLifecycle(mochiItemID: mochiItem.id, to: .reviewRequested)
            XCTFail("memo는 reviewRequested로 전이될 수 없어야 함")
        } catch {
            XCTAssertTrue(error is DomainError)
        }
    }
}
