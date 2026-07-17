import CoreAgentClient
import SwiftUI
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

    func test_ascii_bracket_marker_also_becomes_badge() {
        // flash-lite 가 canonical 전각 「【】」 대신 반각 「[]」 으로 흘려도 뱃지로 치환된다.
        let raw = "여기가 좋아요[item:\(itemID.uuidString.lowercased())]. 가보세요."
        let segments = ChatMarkup.segments(raw: raw, citations: [citation()], isStreaming: false)
        XCTAssertEqual(segments, [.text("여기가 좋아요"), .badge(index: 1), .text(". 가보세요.")])
    }

    func test_short_marker_uniquely_matching_citation_becomes_badge() {
        let shortID = String(itemID.uuidString.lowercased().prefix(8))
        let raw = "여기가 좋아요[item:\(shortID)]."
        let segments = ChatMarkup.segments(raw: raw, citations: [citation(index: 3)], isStreaming: false)
        XCTAssertEqual(segments, [.text("여기가 좋아요"), .badge(index: 3), .text(".")])
    }

    func test_ascii_trailing_partial_marker_is_trimmed_only_while_streaming() {
        let raw = "여기가 좋아요[item:1111"
        let streaming = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.text("여기가 좋아요")])

        // 스트림 종료 후엔 자르지 않는다.
        let done = ChatMarkup.segments(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(done, [.text("여기가 좋아요[item:1111")])
    }

    func test_plain_ascii_bracket_is_not_trimmed_while_streaming() {
        // 본문의 흔한 대괄호(`배열[0]`)는 「[item:」 가 아니므로 스트리밍 중에도 보존된다.
        let raw = "배열[0"
        let streaming = ChatMarkup.segments(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.text("배열[0")])
    }

    func test_bold_markdown_renders_as_style_not_raw_asterisks() throws {
        let attributed = ChatMarkup.attributedText(raw: "이건 **중요**해요", citations: [], isStreaming: false)
        XCTAssertEqual(String(attributed.characters), "이건 중요해요")

        let bold = try XCTUnwrap(attributed.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertEqual(String(attributed.characters[bold.range]), "중요")
    }

    func test_bold_with_quotes_and_particle_still_renders_bold() throws {
        // CommonMark flanking 규칙으로는 닫는 `**` 가 따옴표 뒤·글자 앞이라 구분자로
        // 인정되지 않는 한국어 빈발 패턴(`**'…'**라고`) — 자체 굵게 파싱으로 스타일이
        // 적용돼야 한다.
        let attributed = ChatMarkup.attributedText(
            raw: "그건 **'어쩌고 저쩌고'**라고 했어요", citations: [], isStreaming: false
        )
        XCTAssertEqual(String(attributed.characters), "그건 '어쩌고 저쩌고'라고 했어요")

        let bold = try XCTUnwrap(attributed.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertEqual(String(attributed.characters[bold.range]), "'어쩌고 저쩌고'")
    }

    func test_unpaired_bold_marker_stays_literal() {
        // 짝 없는 `**` 는 자체 파싱 대상이 아니다 — 시스템 파서가 원문으로 둔다.
        let attributed = ChatMarkup.attributedText(raw: "별표 ** 하나는 그대로", citations: [], isStreaming: false)
        XCTAssertEqual(String(attributed.characters), "별표 ** 하나는 그대로")
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

    func test_resolvingBold_sets_explicit_font_only_on_bold_runs() throws {
        // intent 만으로는 medium 베이스 한글 글리프에서 굵게 대비가 거의 없다(ImageRenderer
        // 실측, 2026-06-13) — 표시 직전 명시 폰트가 박혀야 한다.
        let attributed = ChatMarkup.attributedText(raw: "이건 **중요**해요", citations: [], isStreaming: false)
        let resolved = ChatMarkup.resolvingBold(attributed, size: 14.5)

        let bold = try XCTUnwrap(resolved.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertNotNil(bold.font)
        XCTAssertEqual(String(resolved.characters[bold.range]), "중요")

        let plain = try XCTUnwrap(resolved.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) != true
        })
        XCTAssertNil(plain.font) // 본문 폰트는 환경(.font modifier)이 계속 소유한다
    }

    func test_resolvingBold_keeps_citation_badge_font() throws {
        // 뱃지 런은 자체 폰트(13.5 heavy)를 이미 가진다 — bold 해석이 덮어쓰면 안 된다.
        let raw = "**중요**【item:\(itemID.uuidString)】"
        let attributed = ChatMarkup.attributedText(raw: raw, citations: [citation()], isStreaming: false)
        let resolved = ChatMarkup.resolvingBold(attributed, size: 14.5)
        let badge = try XCTUnwrap(resolved.runs.first {
            String(resolved.characters[$0.range]) == "¹"
        })
        XCTAssertNotNil(badge.font)
        XCTAssertNil(badge.inlinePresentationIntent)
    }

    func test_plainText_strips_markers_and_inline_markdown() {
        let raw = "**'어쩌고 저쩌고'**라고 했어요【item:\(itemID.uuidString)】. 끝."
        let plain = ChatMarkup.plainText(raw: raw, citations: [citation()])
        XCTAssertEqual(plain, "'어쩌고 저쩌고'라고 했어요. 끝.")
    }

    func test_superscript_mapping() {
        XCTAssertEqual(ChatMarkup.superscript(1), "¹")
        XCTAssertEqual(ChatMarkup.superscript(12), "¹²")
    }

    // MARK: - 블록 마크다운 (리스트·헤딩·인용·구분선)

    func test_bullet_lines_become_list_block_without_raw_asterisks() throws {
        let raw = "추천드려요.\n*   **카키 코우죠**: 라면집이에요.\n- 쿠촐로 서울\n끝!"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(blocks.count, 3)

        guard case let .list(items) = blocks[1] else {
            return XCTFail("두 번째 블록이 리스트가 아님: \(blocks[1])")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].ordinal)
        // 마커(`*`)는 사라지고 인라인 굵게는 스타일로 해석된다.
        XCTAssertEqual(String(items[0].text.characters), "카키 코우죠: 라면집이에요.")
        XCTAssertEqual(String(items[1].text.characters), "쿠촐로 서울")
    }

    func test_numbered_and_nested_bullet_depth() throws {
        let raw = "1. 첫째\n2) 둘째\n  - 둘째의 세부"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .list(items) = blocks.first, blocks.count == 1 else {
            return XCTFail("리스트 1개여야 함: \(blocks)")
        }
        XCTAssertEqual(items.map(\.ordinal), ["1", "2", nil])
        XCTAssertEqual(items.map(\.depth), [0, 0, 1])
    }

    func test_heading_quote_divider_become_blocks() throws {
        let raw = "## 정리\n> 메모해 둔 말\n---"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        XCTAssertEqual(blocks.count, 3)

        guard case let .heading(level, text) = blocks[0] else {
            return XCTFail("헤딩이 아님: \(blocks[0])")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(String(text.characters), "정리")

        guard case let .quote(quote) = blocks[1] else {
            return XCTFail("인용이 아님: \(blocks[1])")
        }
        XCTAssertEqual(String(quote.characters), "메모해 둔 말")

        XCTAssertEqual(blocks[2], .divider)
    }

    func test_citation_marker_inside_bullet_becomes_badge() throws {
        let raw = "* 좋아요【item:\(itemID.uuidString)】"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [citation()], isStreaming: false)
        guard case let .list(items) = blocks.first else {
            return XCTFail("리스트여야 함: \(blocks)")
        }
        XCTAssertEqual(String(try XCTUnwrap(items.first).text.characters), "좋아요¹")
    }

    func test_bold_line_start_is_not_mistaken_for_bullet() {
        // `**굵게**` 로 시작하는 문단 — `*` 뒤에 공백이 없으니 불릿이 아니다.
        let raw = "**중요**: 꼭 확인하세요"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .paragraph(text) = blocks.first, blocks.count == 1 else {
            return XCTFail("문단 1개여야 함: \(blocks)")
        }
        XCTAssertEqual(String(text.characters), "중요: 꼭 확인하세요")
    }

    func test_asterisk_rule_is_not_a_divider() {
        // `***` 는 divider 로 지원하지 않는다 — 스트리밍의 미닫힘 `**` 트림과 충돌하기
        // 때문(아래 streaming 케이스). 종료 후엔 문단 원문으로 남는다.
        let raw = "A\n***\nB"
        let streaming = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.paragraph(AttributedString("A"))])

        let done = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .paragraph(text) = done.first, done.count == 1 else {
            return XCTFail("문단 1개여야 함: \(done)")
        }
        XCTAssertEqual(String(text.characters), "A\n***\nB")
    }

    func test_trailing_number_line_is_not_hidden_while_streaming() {
        // 단독 숫자는 정상 본문일 수 있다 — 구두점(`1.`)까지 와야 리스트 마커 꼬리다.
        let raw = "정답은\n404"
        let blocks = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: true)
        guard case let .paragraph(text) = blocks.first, blocks.count == 1 else {
            return XCTFail("문단 1개여야 함: \(blocks)")
        }
        XCTAssertEqual(String(text.characters), "정답은\n404")
    }

    func test_trailing_bare_marker_hidden_only_while_streaming() {
        // 마커만 도착하고 텍스트가 아직인 꼬리 줄 — 원문 조각을 노출하지 않는다.
        let raw = "추천드려요.\n*"
        let streaming = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: true)
        XCTAssertEqual(streaming, [.paragraph(AttributedString("추천드려요."))])

        let done = ChatMarkup.blocks(raw: raw, citations: [], isStreaming: false)
        guard case let .paragraph(text) = done.first, done.count == 1 else {
            return XCTFail("문단 1개여야 함: \(done)")
        }
        XCTAssertEqual(String(text.characters), "추천드려요.\n*")
    }
}
