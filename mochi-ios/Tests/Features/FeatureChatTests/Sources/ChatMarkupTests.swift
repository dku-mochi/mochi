import CoreAgentClient
import XCTest

@testable import FeatureChat

/// citation 마커 표시 변환 — raw 보관·표시 직전 치환 (journal 2026-06-10 설계 PR-2 절).
final class ChatMarkupTests: XCTestCase {
    private let itemID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func citation(index: Int = 1) -> ChatCitation {
        ChatCitation(index: index, mochiItemID: itemID, title: "제목", snippet: nil)
    }

    func test_marker_with_matching_citation_becomes_badge() {
        let raw = "여기가 좋아요【item:\(itemID.uuidString.lowercased())】. 가보세요."
        let segments = ChatMarkup.segments(raw: raw, citations: [citation()], isStreaming: false)
        XCTAssertEqual(segments, [.text("여기가 좋아요"), .badge(index: 1), .text(". 가보세요.")])
    }

    func test_marker_without_citation_is_hidden() {
        // 스트리밍 중(citation 이벤트는 본문 뒤에 옴)·미실재 id — 마커 원문을 노출하지 않는다.
        let raw = "여기가 좋아요【item:\(itemID.uuidString)】."
        let segments = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(segments, [.text("여기가 좋아요"), .text(".")])
    }

    func test_trailing_partial_marker_is_trimmed_only_while_streaming() {
        // delta 가 마커를 글자 단위로 쪼갠 순간 — 미완성 꼬리를 잘라 원문 조각 노출 방지.
        let raw = "여기가 좋아요【item:1111"
        let streaming = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.text("여기가 좋아요")])

        // 스트림 종료 후엔 자르지 않는다 — 본문에 진짜 「【」 가 있을 수 있다.
        let done = ChatMarkup.segments(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(done, [.text("여기가 좋아요【item:1111")])
    }

    func test_uppercase_marker_uuid_still_matches() {
        let raw = "근거【item:\(itemID.uuidString.uppercased())】"
        let segments = ChatMarkup.segments(raw: raw, citations: [citation(index: 2)], isStreaming: false)
        XCTAssertEqual(segments, [.text("근거"), .badge(index: 2)])
    }

    func test_superscript_mapping() {
        XCTAssertEqual(ChatMarkup.superscript(1), "¹")
        XCTAssertEqual(ChatMarkup.superscript(12), "¹²")
    }
}
