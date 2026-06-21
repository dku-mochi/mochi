import XCTest
@testable import FeatureInbox

/// `immediateGreeting` — 1단계(local-first)에서 LLM 없이 greeting 을 확정할지,
/// 아니면 서버 보강(nil)이 필요한지 가르는 판정. 이 분기가 캐시 히트 시 즉시 표시 / 미스 시
/// 말풍선 skeleton 을 결정하므로 회귀 위험이 가장 크다.
final class MonthlyDigestFeatureTests: XCTestCase {

    private func cache(month: String, count: Int, greeting: String = "지난달의 한마디") -> MonthlyDigestCache.Entry {
        MonthlyDigestCache.Entry(monthKey: month, itemCount: count, greeting: greeting)
    }

    func test_immediateGreeting_그달3건미만이면_LLM없이_정적폴백() {
        let result = MonthlyDigestFeature.immediateGreeting(cache: nil, monthKey: "2026-6", count: 2)
        XCTAssertEqual(result, MonthlyDigestCache.staticGreeting)
    }

    func test_immediateGreeting_캐시없으면_서버보강필요() {
        let result = MonthlyDigestFeature.immediateGreeting(cache: nil, monthKey: "2026-6", count: 5)
        XCTAssertNil(result)
    }

    func test_immediateGreeting_달이다르면_서버보강필요() {
        let stale = cache(month: "2026-5", count: 5)
        let result = MonthlyDigestFeature.immediateGreeting(cache: stale, monthKey: "2026-6", count: 5)
        XCTAssertNil(result)
    }

    func test_immediateGreeting_같은달_증가3미만이면_캐시히트() {
        let hit = cache(month: "2026-6", count: 5)
        let result = MonthlyDigestFeature.immediateGreeting(cache: hit, monthKey: "2026-6", count: 7)
        XCTAssertEqual(result, "지난달의 한마디")
    }

    func test_immediateGreeting_같은달라도_증가3이상이면_서버보강필요() {
        let hit = cache(month: "2026-6", count: 5)
        let result = MonthlyDigestFeature.immediateGreeting(cache: hit, monthKey: "2026-6", count: 8)
        XCTAssertNil(result)
    }
}
