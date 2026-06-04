import XCTest
@testable import CorePersistence

/// 출처앱 sentinel 분해/구성 — 자동신호(`text`) ↔ 사용자의도(`user_memo`) 2채널 경계 검증.
final class CaptureContextSentinelTests: XCTestCase {

    // MARK: decode

    func test_decode_extracts_sourceApp() {
        let ctx = CaptureContextSentinel.decode(#"{"__mochi_ctx__":{"sourceApp":"Safari"}}"#)
        XCTAssertEqual(ctx?.sourceApp, "Safari")
    }

    func test_decode_plain_text_returns_nil() {
        XCTAssertNil(CaptureContextSentinel.decode("그냥 사용자가 입력한 메모"))
        XCTAssertNil(CaptureContextSentinel.decode("[출처앱: Safari]"))  // 평문 마커는 sentinel 아님
    }

    func test_decode_tolerates_surrounding_whitespace() {
        let ctx = CaptureContextSentinel.decode("  \n{\"__mochi_ctx__\":{\"sourceApp\":\"YouTube\"}}\n ")
        XCTAssertEqual(ctx?.sourceApp, "YouTube")
    }

    func test_decode_sentinel_without_sourceApp_yields_nil_sourceApp() {
        let ctx = CaptureContextSentinel.decode(#"{"__mochi_ctx__":{}}"#)
        XCTAssertNotNil(ctx)
        XCTAssertNil(ctx?.sourceApp)
    }

    func test_decode_empty_sourceApp_is_normalized_to_nil() {
        let ctx = CaptureContextSentinel.decode(#"{"__mochi_ctx__":{"sourceApp":""}}"#)
        XCTAssertNil(ctx?.sourceApp)
    }

    func test_decode_whitespace_only_sourceApp_is_normalized_to_nil() {
        XCTAssertNil(CaptureContextSentinel.decode(#"{"__mochi_ctx__":{"sourceApp":"   "}}"#)?.sourceApp)
    }

    func test_decode_collapses_internal_whitespace_to_single_line() {
        // sentinel 은 신뢰 경계가 아니므로 내부 개행/연속 공백을 single space 로 접어 마커 1줄 보장.
        let ctx = CaptureContextSentinel.decode(#"{"__mochi_ctx__":{"sourceApp":" My  App\n"}}"#)
        XCTAssertEqual(ctx?.sourceApp, "My App")
    }

    func test_decode_broken_json_returns_nil() {
        XCTAssertNil(CaptureContextSentinel.decode(#"{"__mochi_ctx__":{"sourceApp":"#))
    }

    // MARK: compose

    func test_sourceAppMarker_format() {
        XCTAssertEqual(CaptureContextSentinel.sourceAppMarker("Safari"), "[출처앱: Safari]")
    }

    func test_composeText_sourceApp_only() {
        XCTAssertEqual(
            CaptureContextSentinel.composeText(sourceApp: "Safari", base: nil),
            "[출처앱: Safari]"
        )
    }

    func test_composeText_sourceApp_and_base_joins_marker_first() {
        XCTAssertEqual(
            CaptureContextSentinel.composeText(sourceApp: "YouTube", base: "OCR 본문"),
            "[출처앱: YouTube]\nOCR 본문"
        )
    }

    func test_composeText_base_only_passes_through() {
        XCTAssertEqual(CaptureContextSentinel.composeText(sourceApp: nil, base: "공유 텍스트"), "공유 텍스트")
    }

    func test_composeText_all_nil_returns_nil() {
        XCTAssertNil(CaptureContextSentinel.composeText(sourceApp: nil, base: nil))
        XCTAssertNil(CaptureContextSentinel.composeText(sourceApp: nil, base: ""))
    }
}
