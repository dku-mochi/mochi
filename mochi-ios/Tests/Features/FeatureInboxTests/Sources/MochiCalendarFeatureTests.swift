import XCTest
import CoreDomain
@testable import FeatureInbox

final class MochiCalendarFeatureTests: XCTestCase {

    // MARK: - Helpers

    private func iso(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }

    private func item(intent: Intent?, capturedAt: Date, relativePath: String? = nil) -> MochiItem {
        var refs: [ImageRef] = []
        if let relativePath {
            refs = [ImageRef(relativePath: relativePath, mimeType: "image/jpeg", byteSize: 1, sha256: "a", objectKey: nil)]
        }
        let source = IngestSource(channel: .screenshot, imageRefs: refs, capturedAt: capturedAt)
        let analysis = intent.map { value in
            MochiItemAnalysis(
                summary: "s", instances: [IntentInstance(intentType: value)],
                needsReview: false, reviewOptions: [],
                entities: [], actionCandidates: [], tags: [],
                importance: .medium, modelVersion: "test", analyzedAt: capturedAt
            )
        }
        return MochiItem(source: source, analysis: analysis, lifecycleState: .analyzed)
    }

    private func todo(due: String?, capturedAt: Date) -> MochiItem {
        // 마감일은 active todo instance 의 payload.deadline 에 싣는다 (actionCandidate 는 iOS 응답에서 항상 빔).
        let analysis = MochiItemAnalysis(
            summary: "s",
            instances: [IntentInstance(intentType: .todo, payload: IntentPayload(deadline: due))],
            needsReview: false, reviewOptions: [],
            entities: [], actionCandidates: [], tags: [],
            importance: .medium, modelVersion: "test", analyzedAt: capturedAt
        )
        return MochiItem(source: IngestSource(channel: .appDirectInput, capturedAt: capturedAt), analysis: analysis, lifecycleState: .analyzed)
    }

    /// 여러 instance(intent·payload·lifecycle 지정)를 가진 item — 마감/일정 추출 테스트용.
    private func dueItem(_ instances: [IntentInstance], capturedAt: Date = Date()) -> MochiItem {
        let analysis = MochiItemAnalysis(
            summary: "s", instances: instances,
            needsReview: false, reviewOptions: [],
            entities: [], actionCandidates: [], tags: [],
            importance: .medium, modelVersion: "test", analyzedAt: capturedAt
        )
        return MochiItem(source: IngestSource(channel: .appDirectInput, capturedAt: capturedAt), analysis: analysis, lifecycleState: .analyzed)
    }

    private var kstCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    // MARK: - CalendarDaySummary.group

    func test_group_buckets_by_kst_day_with_priority_intent_and_thumbnail() {
        // 2026-06-01 KST: schedule 1 + todo 2 → 고정 우선순위 schedule>todo 라 대표는 schedule(최빈 아님).
        let items = [
            item(intent: .schedule, capturedAt: iso("2026-06-01T03:00:00Z")),   // KST 6/1 12:00
            item(intent: .knowledge, capturedAt: iso("2026-06-02T05:00:00Z")),  // KST 6/2 14:00
            item(intent: .todo, capturedAt: iso("2026-06-01T02:00:00Z")),       // KST 6/1 11:00
            item(intent: .todo, capturedAt: iso("2026-06-01T01:00:00Z"), relativePath: "captures/k1.heic"),
        ]
        // repository 는 capturedAt desc 로 준다.
        let sorted = items.sorted { $0.source.capturedAt > $1.source.capturedAt }

        let days = CalendarDaySummary.group(captured: sorted, due: [], calendar: kstCalendar)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (kstCalendar.dateComponents([.month, .day], from: $0.date).day ?? 0, $0) })

        XCTAssertEqual(byDay[1]?.count, 3)
        XCTAssertEqual(byDay[1]?.representativeIntent, .schedule)            // 고정 우선순위 최상위
        XCTAssertEqual(byDay[1]?.thumbnailRelativePath, "captures/k1.heic")  // 유일한 relativePath
        XCTAssertEqual(byDay[2]?.count, 1)
        XCTAssertNil(byDay[2]?.thumbnailRelativePath)
    }

    func test_group_kst_boundary_pushes_late_utc_into_next_day() {
        // 2026-05-31 15:30 UTC == 2026-06-01 00:30 KST → 6월 1일로 묶여야 한다.
        let items = [item(intent: .memo, capturedAt: iso("2026-05-31T15:30:00Z"))]
        let days = CalendarDaySummary.group(captured: items, due: [], calendar: kstCalendar)

        XCTAssertEqual(days.count, 1)
        let comps = kstCalendar.dateComponents([.year, .month, .day], from: days[0].date)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 1)
    }

    // MARK: - UpcomingTodoSorter

    func test_sort_orders_by_deadline_then_undated_last() {
        let base = iso("2026-06-01T00:00:00Z")
        let near = todo(due: "2026-06-10T00:00:00Z", capturedAt: base)
        let far = todo(due: "2026-12-31T00:00:00Z", capturedAt: base)
        let undated = todo(due: nil, capturedAt: base)

        let sorted = UpcomingTodoSorter.sort([far, undated, near])

        XCTAssertEqual(sorted.map(\.id), [near.id, far.id, undated.id])
    }

    func test_deadline_parses_iso8601_and_returns_nil_when_absent() {
        XCTAssertNotNil(UpcomingTodoSorter.deadline(of: todo(due: "2026-06-10T23:59:00Z", capturedAt: Date())))
        XCTAssertNil(UpcomingTodoSorter.deadline(of: todo(due: nil, capturedAt: Date())))
    }

    // MARK: - CalendarDueDate (마감/일정 추출·파싱)

    func test_dueDates_extracts_active_todo_and_schedule_and_excludes_archived() {
        let item = dueItem([
            IntentInstance(intentType: .todo, payload: IntentPayload(deadline: "2026-06-10")),
            IntentInstance(intentType: .schedule, payload: IntentPayload(date: "2026-06-15")),
            IntentInstance(intentType: .schedule, payload: IntentPayload(date: "2026-06-20"),
                           lifecycle: .archived(reason: .scheduleEnded)),
            IntentInstance(intentType: .memo, payload: IntentPayload(date: "2026-06-25")),
        ])
        let dues = CalendarDueDate.dueDates(of: item)
        // active todo(마감) + active schedule(일정) 둘만 — archived schedule·memo 는 제외.
        XCTAssertEqual(dues.count, 2)
        XCTAssertEqual(dues.filter { $0.intent == .todo }.count, 1)
        XCTAssertEqual(dues.filter { $0.intent == .schedule }.count, 1)
    }

    func test_parse_handles_iso_with_seconds_and_rejects_natural_language() {
        // payload 날짜 포맷 계약이 느슨해 TZ 없는 초 단위 ISO·날짜-only 도 KST 로 파싱, 자연어/nil 은 거른다.
        XCTAssertNotNil(CalendarDueDate.parse("2026-06-15T09:00:00"))
        XCTAssertNotNil(CalendarDueDate.parse("2026-06-15"))
        XCTAssertNil(CalendarDueDate.parse("회의 후"))
        XCTAssertNil(CalendarDueDate.parse(nil))
    }
}
