import XCTest

@testable import CoreAgentClient

/// SSE 파서 — **바이트 단위** 소비가 빈 줄(이벤트 경계)을 보존하는지 고정.
///
/// 회귀 배경(2026-06-10 리뷰 P1): `bytes.lines` 는 빈 줄을 방출하지 않아 이벤트 경계가
/// 사라지고 delta·done 이 한 건도 전달되지 않았다. 이 테스트는 실제 wire 바이트를 그대로
/// 먹여 그 회귀를 막는다.
final class SSEEventParserTests: XCTestCase {
    private func feed(_ wire: String) -> [(event: String, data: String)] {
        var parser = SSEEventParser()
        var events: [(String, String)] = []
        for byte in Array(wire.utf8) {
            if let event = parser.consume(byte: byte) {
                events.append(event)
            }
        }
        if let remainder = parser.flush() {
            events.append(remainder)
        }
        return events
    }

    func test_byte_stream_preserves_event_boundaries() {
        let wire = """
        : stream-open

        event: message_delta
        data: {"text":"안"}

        event: message_delta
        data: {"text":"녕"}

        event: done
        data: {"message_id":"x"}

        """
        let events = feed(wire)
        XCTAssertEqual(events.map(\.event), ["message_delta", "message_delta", "done"])
        XCTAssertEqual(events[0].data, #"{"text":"안"}"#)
        XCTAssertEqual(events[2].data, #"{"message_id":"x"}"#)
    }

    func test_crlf_lines_and_multiline_data() {
        let wire = "event: citation\r\ndata: {\"a\":1,\r\ndata: \"b\":2}\r\n\r\n"
        let events = feed(wire)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "citation")
        // data: 다중 행은 \n 으로 이어붙인다 (SSE 규약).
        XCTAssertEqual(events[0].data, "{\"a\":1,\n\"b\":2}")
    }

    func test_stream_ending_without_boundary_flushes_remainder() {
        // 서버가 마지막 빈 줄 없이 닫은 경우 — flush 가 잔여 이벤트를 회수한다.
        let wire = "event: error\ndata: {\"code\":\"x\"}"
        let events = feed(wire)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "error")
        XCTAssertEqual(events[0].data, #"{"code":"x"}"#)
    }

    func test_comment_and_data_without_event_are_ignored() {
        XCTAssertTrue(feed(": ping\n\n").isEmpty)
        XCTAssertTrue(feed("data: {}\n\n").isEmpty)   // event 이름 없는 data — 무시
    }
}
