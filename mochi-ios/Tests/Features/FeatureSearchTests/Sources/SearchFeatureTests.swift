import XCTest
import ComposableArchitecture
import CoreNetworking
@testable import FeatureSearch

@MainActor
final class SearchFeatureTests: XCTestCase {
    func test_empty_query_does_not_submit() async {
        let store = TestStore(initialState: SearchFeature.State()) { SearchFeature() }
        await store.send(.submit)   // 변경 없음
    }
}
