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

    func test_updateInstanceLifecycle_rejects_illegal_transition_for_memo() async throws {
        let repo = InMemoryMochiItemRepository()
        let source = IngestSource(channel: .appDirectInput, text: "memo")
        let memoInstance = IntentInstance(intentType: .memo)
        let analysis = MochiItemAnalysis(
            summary: "s", instances: [memoInstance], needsReview: false, reviewOptions: [],
            entities: [], actionCandidates: [], tags: [], importance: .medium,
            modelVersion: "test", analyzedAt: .init()
        )
        let mochiItem = MochiItem(source: source, analysis: analysis, lifecycleState: .analyzed)
        try await repo.upsert(mochiItem)

        do {
            // memo 는 active → archived 만 허용 — reviewRequested 로 전이될 수 없다.
            try await repo.updateInstanceLifecycle(mochiItemID: mochiItem.id, instanceID: memoInstance.id, to: .reviewRequested)
            XCTFail("memo는 reviewRequested로 전이될 수 없어야 함")
        } catch {
            XCTAssertTrue(error is DomainError)
        }
    }

    func test_clearAnalysisOCR_removes_ocr_and_keeps_updatedAt() async throws {
        let repo = InMemoryMochiItemRepository()
        let source = IngestSource(channel: .screenshot, analysisOcrText: "카드 1234-5678 화면 transcript")
        try await repo.upsert(MochiItem(source: source))
        // upsert 가 updatedAt 을 bump 하므로 clear 직전의 실제 값을 기준으로 비교한다(MochiItem.id == source.id).
        let updatedBefore = try await repo.find(id: source.id)?.updatedAt

        try await repo.clearAnalysisOCR(mochiItemID: source.id)

        let cleared = try await repo.find(id: source.id)
        XCTAssertNil(cleared?.source.analysisOcrText, "업로드 후 OCR 은 비워져야 함")
        XCTAssertEqual(cleared?.updatedAt, updatedBefore, "OCR clear 는 updatedAt 을 bump 하지 않아야 함")
    }

    func test_clearAnalysisOCR_is_noop_when_already_nil() async throws {
        let repo = InMemoryMochiItemRepository()
        let item = MochiItem(source: IngestSource(channel: .screenshot))
        try await repo.upsert(item)
        // OCR 이 없으면 no-op — 예외 없이 통과.
        try await repo.clearAnalysisOCR(mochiItemID: item.id)
        let found = try await repo.find(id: item.id)
        XCTAssertNil(found?.source.analysisOcrText)
    }
}
