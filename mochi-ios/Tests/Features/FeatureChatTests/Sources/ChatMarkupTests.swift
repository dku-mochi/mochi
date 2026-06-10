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

    func test_bold_markdown_renders_as_style_not_raw_asterisks() throws {
        let attributed = ChatMarkup.attributedText(raw: "이건 **중요**해요", citations: [], isStreaming: false)
        XCTAssertEqual(String(attributed.characters), "이건 중요해요")

        let bold = try XCTUnwrap(attributed.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertEqual(String(attributed.characters[bold.range]), "중요")
    }

    func test_newlines_and_block_syntax_stay_literal() {
        // 인라인 전용 파싱 — 개행은 보존, 헤더·리스트 마커는 스타일로 해석하지 않는다.
        let attributed = ChatMarkup.attributedText(raw: "# 제목\n- 첫째\n- 둘째", citations: [], isStreaming: false)
        XCTAssertEqual(String(attributed.characters), "# 제목\n- 첫째\n- 둘째")
    }

    func test_trailing_unclosed_bold_is_trimmed_only_while_streaming() {
        // delta 가 굵게 구간을 쪼갠 순간 — 닫히기 전까지 `**` 원문을 노출하지 않는다.
        let raw = "결론은 **아직"
        let streaming = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.text("결론은 ")])

        // 스트림 종료 후엔 자르지 않는다 — 진짜 미닫힘 `**` 는 마크다운 파서가 원문으로 둔다.
        let done = ChatMarkup.segments(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(done, [.text("결론은 **아직")])
    }

    func test_closed_bold_pairs_are_not_trimmed_while_streaming() {
        let raw = "이건 **중요**하고 또 **급해요**"
        let segments = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(segments, [.text(raw)])
    }

    func test_table_between_paragraphs_becomes_table_block() throws {
        let raw = """
        비교해 봤어요.
        | 이름 | 가격 |
        | --- | --- |
        | 모찌 | **1,000원** |
        | 도넛 | 2,500원 |
        이 중에 골라보세요!
        """
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(blocks.count, 3)

        guard case let .table(header, rows) = blocks[1] else {
            return XCTFail("두 번째 블록이 표가 아님: \(blocks[1])")
        }
        XCTAssertEqual(header.map { String($0.characters) }, ["이름", "가격"])
        XCTAssertEqual(
            rows.map { row in row.map { String($0.characters) } },
            [["모찌", "1,000원"], ["도넛", "2,500원"]] // 셀 안 인라인 마크다운도 해석
        )

        guard case let .paragraph(tail) = blocks[2] else {
            return XCTFail("세 번째 블록이 문단이 아님: \(blocks[2])")
        }
        XCTAssertEqual(String(tail.characters), "이 중에 골라보세요!")
    }

    func test_pipe_lines_without_separator_stay_paragraph() {
        let raw = "| 그냥 파이프 문장 |\n다음 줄"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .paragraph(text) = blocks.first, blocks.count == 1 else {
            return XCTFail("문단 1개여야 함: \(blocks)")
        }
        XCTAssertEqual(String(text.characters), "| 그냥 파이프 문장 |\n다음 줄")
    }

    func test_short_rows_are_padded_to_header_width() throws {
        let raw = "| a | b |\n| --- | --- |\n| 하나 |"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .table(_, rows) = blocks.first else {
            return XCTFail("표여야 함: \(blocks)")
        }
        XCTAssertEqual(rows.map { row in row.map { String($0.characters) } }, [["하나", ""]])
    }

    func test_trailing_unconfirmed_table_candidate_hidden_only_while_streaming() {
        // 구분선이 아직 안 온 꼬리의 `|` 줄들 — 표로 확정되기 전엔 원문을 노출하지 않는다.
        let raw = "정리하면:\n| 이름 | 가격 |"
        let streaming = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.paragraph(AttributedString("정리하면:"))])

        let done = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .paragraph(text) = done.first, done.count == 1 else {
            return XCTFail("문단 1개여야 함: \(done)")
        }
        XCTAssertEqual(String(text.characters), "정리하면:\n| 이름 | 가격 |")
    }

    func test_citation_marker_inside_table_cell_becomes_badge() throws {
        let raw = "| 근거 |\n| --- |\n| 좋아요【item:\(itemID.uuidString)】 |"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [citation()], isStreaming: false)
        guard case let .table(_, rows) = blocks.first else {
            return XCTFail("표여야 함: \(blocks)")
        }
        XCTAssertEqual(String(try XCTUnwrap(rows.first?.first).characters), "좋아요¹")
    }

    func test_superscript_mapping() {
        XCTAssertEqual(ChatMarkup.superscript(1), "¹")
        XCTAssertEqual(ChatMarkup.superscript(12), "¹²")
    }
}
