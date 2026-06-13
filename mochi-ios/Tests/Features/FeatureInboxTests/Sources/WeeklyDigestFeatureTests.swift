import XCTest
@testable import FeatureInbox

/// `immediateGreeting` — 1단계(local-first)에서 LLM 없이 greeting 을 확정할지,
/// 아니면 서버 보강(nil)이 필요한지 가르는 판정. 이 분기가 캐시 히트 시 즉시 표시 / 미스 시
/// 말풍선 skeleton 을 결정하므로 회귀 위험이 가장 크다.
final class WeeklyDigestFeatureTests: XCTestCase {

    private func cache(week: String, count: Int, greeting: String = "지난주의 한마디") -> WeeklyDigestCache.Entry {
        WeeklyDigestCache.Entry(weekKey: week, itemCount: count, greeting: greeting)
    }

    func test_immediateGreeting_그주3건미만이면_LLM없이_정적폴백() {
        let result = WeeklyDigestFeature.immediateGreeting(cache: nil, weekKey: "2026-W24", count: 2)
        XCTAssertEqual(result, WeeklyDigestCache.staticGreeting)
    }

    func test_immediateGreeting_캐시없으면_서버보강필요() {
        let result = WeeklyDigestFeature.immediateGreeting(cache: nil, weekKey: "2026-W24", count: 5)
        XCTAssertNil(result)
    }

    func test_immediateGreeting_주가다르면_서버보강필요() {
        let stale = cache(week: "2026-W23", count: 5)
        let result = WeeklyDigestFeature.immediateGreeting(cache: stale, weekKey: "2026-W24", count: 5)
        XCTAssertNil(result)
    }

    func test_immediateGreeting_같은주_증가3미만이면_캐시히트() {
        let hit = cache(week: "2026-W24", count: 5)
        let result = WeeklyDigestFeature.immediateGreeting(cache: hit, weekKey: "2026-W24", count: 7)
        XCTAssertEqual(result, "지난주의 한마디")
    }

    func test_immediateGreeting_같은주라도_증가3이상이면_서버보강필요() {
        let hit = cache(week: "2026-W24", count: 5)
        let result = WeeklyDigestFeature.immediateGreeting(cache: hit, weekKey: "2026-W24", count: 8)
        XCTAssertNil(result)
    }
}
