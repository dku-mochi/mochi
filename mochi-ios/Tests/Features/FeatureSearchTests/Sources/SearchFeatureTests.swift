import XCTest
import ComposableArchitecture
import CoreDomain
import CoreNetworking
@testable import FeatureSearch

@MainActor
final class SearchFeatureTests: XCTestCase {
    func test_empty_query_does_not_submit() async {
        let store = TestStore(initialState: SearchFeature.State()) { SearchFeature() }
        await store.send(.submit)   // 변경 없음
    }

    // MARK: - 카테고리 필터 (.idle)

    private func item(category: String?, source: IngestSource) -> MochiItem {
        let analysis = MochiItemAnalysis(
            summary: "s", category: category,
            instances: [IntentInstance(intentType: .memo)],
            needsReview: false, reviewOptions: [],
            entities: [], actionCandidates: [], tags: [],
            importance: .medium, modelVersion: "test", analyzedAt: Date()
        )
        return MochiItem(source: source, analysis: analysis, lifecycleState: .analyzed)
    }

    private var screenshotSource: IngestSource {
        IngestSource(channel: .screenshot,
                     imageRefs: [ImageRef(relativePath: "captures/a.jpg", mimeType: "image/jpeg",
                                          byteSize: 1, sha256: "a", objectKey: nil)],
                     capturedAt: Date())
    }
    private var linkSource: IngestSource {
        IngestSource(channel: .appShareSheet, url: URL(string: "https://example.com"), capturedAt: Date())
    }
    private var memoSource: IngestSource {
        IngestSource(channel: .appDirectInput, capturedAt: Date())
    }

    func test_availableCategories_distinct_by_count_desc_excluding_nil() {
        var state = SearchFeature.State()
        state.items = [
            item(category: "쇼핑", source: screenshotSource),
            item(category: "쇼핑", source: linkSource),
            item(category: "방문", source: memoSource),
            item(category: nil, source: memoSource),
        ]
        XCTAssertEqual(state.availableCategories, ["쇼핑", "방문"])   // 많은 순, nil 제외
    }

    func test_filteredItems_applies_type_and_category_as_AND() {
        var state = SearchFeature.State()
        state.items = [
            item(category: "쇼핑", source: screenshotSource),   // 쇼핑 + 스크린샷
            item(category: "쇼핑", source: linkSource),          // 쇼핑 + 링크
            item(category: "방문", source: memoSource),          // 방문 + 메모
            item(category: nil, source: memoSource),
        ]
        // 카테고리만
        state.selectedCategory = "쇼핑"
        XCTAssertEqual(state.filteredItems.count, 2)
        // 카테고리 ∧ 타입(AND)
        state.typeFilter = .screenshot
        XCTAssertEqual(state.filteredItems.count, 1)
        // 둘 다 전체
        state.typeFilter = .all
        state.selectedCategory = nil
        XCTAssertEqual(state.filteredItems.count, 4)
    }
}
