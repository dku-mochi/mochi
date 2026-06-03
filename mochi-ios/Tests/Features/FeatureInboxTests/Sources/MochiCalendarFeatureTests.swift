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
                summary: "s", intent: value, entities: [], actionCandidates: [], tags: [],
                importance: .medium, confidence: 0.9, modelVersion: "test", analyzedAt: capturedAt
            )
        }
        return MochiItem(source: source, analysis: analysis, lifecycleState: .active)
    }

    private func todo(due: String?, capturedAt: Date) -> MochiItem {
        let actions: [MochiItemAnalysis.ActionCandidate] = due.map { [.createReminder(title: "t", dueISO8601: $0)] } ?? []
        let analysis = MochiItemAnalysis(
            summary: "s", intent: .todo, entities: [], actionCandidates: actions, tags: [],
            importance: .medium, confidence: 0.9, modelVersion: "test", analyzedAt: capturedAt
        )
        return MochiItem(source: IngestSource(channel: .appDirectInput, capturedAt: capturedAt), analysis: analysis, lifecycleState: .active)
    }

    private var kstCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    // MARK: - CalendarDaySummary.group

    func test_group_buckets_by_kst_day_with_most_common_intent_and_thumbnail() {
        // 2026-06-01 KST: todo 2 + schedule 1 → 대표 todo. 2026-06-02: knowledge 1.
        let items = [
            item(intent: .schedule, capturedAt: iso("2026-06-01T03:00:00Z")),   // KST 6/1 12:00
            item(intent: .knowledge, capturedAt: iso("2026-06-02T05:00:00Z")),  // KST 6/2 14:00
            item(intent: .todo, capturedAt: iso("2026-06-01T02:00:00Z")),       // KST 6/1 11:00
            item(intent: .todo, capturedAt: iso("2026-06-01T01:00:00Z"), relativePath: "captures/k1.heic"),
        ]
        // repository 는 capturedAt desc 로 준다.
        let sorted = items.sorted { $0.source.capturedAt > $1.source.capturedAt }

        let days = CalendarDaySummary.group(sorted, calendar: kstCalendar)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (kstCalendar.dateComponents([.month, .day], from: $0.date).day ?? 0, $0) })

        XCTAssertEqual(byDay[1]?.count, 3)
        XCTAssertEqual(byDay[1]?.representativeIntent, .todo)            // 최빈
        XCTAssertEqual(byDay[1]?.thumbnailRelativePath, "captures/k1.heic")  // 유일한 relativePath
        XCTAssertEqual(byDay[2]?.count, 1)
        XCTAssertNil(byDay[2]?.thumbnailRelativePath)
    }

    func test_group_kst_boundary_pushes_late_utc_into_next_day() {
        // 2026-05-31 15:30 UTC == 2026-06-01 00:30 KST → 6월 1일로 묶여야 한다.
        let items = [item(intent: .memo, capturedAt: iso("2026-05-31T15:30:00Z"))]
        let days = CalendarDaySummary.group(items, calendar: kstCalendar)

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
}
