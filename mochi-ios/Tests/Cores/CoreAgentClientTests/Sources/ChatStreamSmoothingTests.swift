import XCTest

@testable import CoreAgentClient

/// 타자기 스무딩 — 블록 delta 를 글자 단위로 풀되 비-텍스트 이벤트의 순서를 보존한다.
final class ChatStreamSmoothingTests: XCTestCase {
    private func upstream(_ events: [ChatStreamEvent]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func test_block_delta_is_split_into_characters_preserving_event_order() async throws {
        let doneID = UUID()
        let events: [ChatStreamEvent] = [
            .toolStarted(name: "search_items", label: "찾는 중"),
            .messageDelta("안녕하세요"),
            .done(messageID: doneID),
        ]

        var collected: [ChatStreamEvent] = []
        for try await event in ChatStreamSmoothing.smoothed(upstream(events)) {
            collected.append(event)
        }

        // 블록 1개 → 글자 5개. tool 은 앞, done 은 텍스트가 모두 풀린 뒤 — 순서 보존.
        XCTAssertEqual(collected.first, .toolStarted(name: "search_items", label: "찾는 중"))
        let deltas = collected.compactMap { event -> String? in
            if case let .messageDelta(text) = event { return text }
            return nil
        }
        XCTAssertEqual(deltas, ["안", "녕", "하", "세", "요"])
        XCTAssertEqual(collected.last, .done(messageID: doneID))
    }

    func test_delay_accelerates_with_backlog_but_never_below_minimum() {
        let base = ChatStreamSmoothing.delay(backlog: 0)
        let mid = ChatStreamSmoothing.delay(backlog: 160)
        let deep = ChatStreamSmoothing.delay(backlog: 10_000)
        XCTAssertEqual(base, .milliseconds(ChatStreamSmoothing.baseDelayMilliseconds))
        XCTAssertLessThan(mid, base)
        XCTAssertEqual(deep, .milliseconds(ChatStreamSmoothing.minDelayMilliseconds))
        XCTAssertGreaterThan(deep, .zero)
    }
}
