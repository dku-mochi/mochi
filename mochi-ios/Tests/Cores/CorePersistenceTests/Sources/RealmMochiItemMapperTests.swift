import XCTest
import CoreDomain
@testable import CorePersistence

/// 도메인 ↔ Realm round-trip 무손실 검증 (2026-06-04 빅뱅: 복수 instance + typed payload + needsReview).
///
/// LLM 출력(intent instance 배열) → `toRealm`(평탄화) → `toDomain`(복원) 왕복에서 instance·payload·
/// lifecycle·needsReview·reviewOptions 가 보존되어야 한다. Realm 파일 없이 unmanaged 객체로 검증한다.
final class RealmMochiItemMapperTests: XCTestCase {

    func test_roundtrip_preserves_multiple_instances_payload_and_lifecycle() {
        let instances = [
            IntentInstance(
                intentType: .schedule,
                payload: IntentPayload(title: "팀 회의", date: "2026-06-10", time: "15:00", person: "박세현"),
                label: "회의 일정",
                reasoning: "캘린더 등록 권장",
                lifecycle: .active
            ),
            IntentInstance(
                intentType: .todo,
                payload: IntentPayload(deadline: "2026-06-12"),
                label: "보고서 제출",
                lifecycle: .archived(reason: .todoCompleted)
            ),
            IntentInstance(intentType: .todo, lifecycle: .active),  // 같은 type 다중 허용
        ]
        let analysis = MochiItemAnalysis(
            summary: "요약",
            instances: instances,
            needsReview: true,
            reviewOptions: [ReviewOption(intentType: .knowledge, label: "지식?", reasoning: "참고용")],
            entities: [],
            actionCandidates: [],
            tags: ["회의"],
            importance: .high,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let original = MochiItem(
            source: IngestSource(channel: .screenshot, text: "원본"),
            analysis: analysis,
            lifecycleState: .analyzed
        )

        let restored = RealmMochiItemMapper.toDomain(RealmMochiItemMapper.toRealm(original))

        XCTAssertEqual(restored.lifecycleState, .analyzed)
        XCTAssertEqual(restored.analysis?.needsReview, true)
        XCTAssertEqual(restored.analysis?.instances.count, 3)

        let schedule = restored.analysis?.instances.first { $0.intentType == .schedule }
        XCTAssertEqual(schedule?.payload.title, "팀 회의")
        XCTAssertEqual(schedule?.payload.person, "박세현")
        XCTAssertEqual(schedule?.label, "회의 일정")
        XCTAssertEqual(schedule?.lifecycle, .active)

        let archivedTodo = restored.analysis?.instances.first { $0.lifecycle == .archived(reason: .todoCompleted) }
        XCTAssertEqual(archivedTodo?.intentType, .todo)
        XCTAssertEqual(archivedTodo?.payload.deadline, "2026-06-12")

        // 같은 type(todo) 다중 보존
        XCTAssertEqual(restored.analysis?.instances.filter { $0.intentType == .todo }.count, 2)

        XCTAssertEqual(restored.analysis?.reviewOptions.first?.intentType, .knowledge)
        XCTAssertEqual(restored.analysis?.reviewOptions.first?.label, "지식?")

        // 대표 intent = 고정 우선순위 → schedule
        XCTAssertEqual(restored.representativeIntent, .schedule)
    }

    func test_roundtrip_unanalyzed_item_has_no_analysis() {
        let original = MochiItem(source: IngestSource(channel: .appDirectInput, text: "분석 전"))
        let restored = RealmMochiItemMapper.toDomain(RealmMochiItemMapper.toRealm(original))
        XCTAssertNil(restored.analysis)
        XCTAssertEqual(restored.lifecycleState, .ingested)
    }

    func test_roundtrip_preserves_analysis_ocr_text() {
        // ephemeral OCR 은 drain~업로드 사이 SyncWorker 가 읽어야 하므로 Realm round-trip 으로 보존돼야 한다.
        let original = MochiItem(
            source: IngestSource(channel: .screenshot, analysisOcrText: "화면 OCR transcript 예매번호 A1234")
        )
        let restored = RealmMochiItemMapper.toDomain(RealmMochiItemMapper.toRealm(original))
        XCTAssertEqual(restored.source.analysisOcrText, "화면 OCR transcript 예매번호 A1234")
    }
}
