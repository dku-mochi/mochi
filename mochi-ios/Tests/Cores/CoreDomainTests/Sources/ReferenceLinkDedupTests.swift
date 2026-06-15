import XCTest
@testable import CoreDomain

/// 관련 링크 중복 제거의 도메인 단일 원천 검증.
///
/// 상세 "지금 할 수 있어요"의 원본 링크(``MochiItem.primaryActionURL``)와 같은 자료가 관련 링크에도
/// 있으면 표시단에서 숨긴다(백엔드 dedup 의 안전망). 비교 키는 ``URLCanonical`` 단일 기준 —
/// youtu.be ↔ watch?v= ↔ shorts/ 를 같은 영상으로 본다. (유튜브 쇼츠 복원 URL 중복 문제, 2026-06-15.)
final class URLCanonicalTests: XCTestCase {
    private func key(_ s: String) -> String { URLCanonical.key(URL(string: s)!) }

    func test_equatesYouTubeVideoForms() {
        let keys: Set<String> = [
            key("https://youtu.be/aRnD-jOINlM"),
            key("https://www.youtube.com/watch?v=aRnD-jOINlM"),
            key("https://m.youtube.com/watch?v=aRnD-jOINlM"),
            key("https://youtube.com/shorts/aRnD-jOINlM"),
            key("https://www.youtube.com/embed/aRnD-jOINlM"),
        ]
        XCTAssertEqual(keys, ["youtube:aRnD-jOINlM"])
    }

    func test_distinguishesDifferentVideos() {
        XCTAssertNotEqual(key("https://youtu.be/aaa"), key("https://youtu.be/bbb"))
    }

    func test_stripsShareAndPlaylistParams() {
        // 공유 링크(youtu.be ?si=)와 watch ?v=…&list=&t= 가 같은 영상으로 묶여야 실제 중복이 잡힌다.
        XCTAssertEqual(key("https://youtu.be/abc?si=xY"), "youtube:abc")
        XCTAssertEqual(key("https://www.youtube.com/watch?v=abc&list=PL1&t=10s"), "youtube:abc")
    }

    func test_preservesQueryCaseForNonYouTube() {
        // host·path 는 소문자, query 토큰/ID 는 대소문자 보존.
        XCTAssertEqual(key("https://Shop.example.com/Goods?id=AbC"), "shop.example.com/goods?id=AbC")
    }
}

final class MochiItemPrimaryActionURLTests: XCTestCase {
    private func item(
        sourceURL: URL? = nil,
        payloadURL: String? = nil,
        actionURL: URL? = nil
    ) -> MochiItem {
        let instances = payloadURL.map { [IntentInstance(intentType: .memo, payload: IntentPayload(url: $0))] } ?? []
        let candidates: [MochiItemAnalysis.ActionCandidate] = actionURL.map { [.openURL($0)] } ?? []
        let analysis = MochiItemAnalysis(
            summary: "s",
            instances: instances,
            entities: [],
            actionCandidates: candidates,
            tags: [],
            importance: .medium,
            modelVersion: "v",
            analyzedAt: Date()
        )
        return MochiItem(source: IngestSource(channel: .screenshot, url: sourceURL), analysis: analysis)
    }

    func test_prefersSourceURL() {
        let i = item(sourceURL: URL(string: "https://a.com")!, payloadURL: "https://b.com", actionURL: URL(string: "https://c.com")!)
        XCTAssertEqual(i.primaryActionURL, URL(string: "https://a.com"))
    }

    func test_fallsBackToPayloadURL() {
        let i = item(payloadURL: "https://b.com", actionURL: URL(string: "https://c.com")!)
        XCTAssertEqual(i.primaryActionURL, URL(string: "https://b.com"))
    }

    func test_fallsBackToActionCandidate() {
        let i = item(actionURL: URL(string: "https://c.com")!)
        XCTAssertEqual(i.primaryActionURL, URL(string: "https://c.com"))
    }

    func test_nilWhenNoActionURL() {
        XCTAssertNil(item().primaryActionURL)
    }
}
