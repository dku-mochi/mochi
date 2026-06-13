import XCTest

@testable import CoreAgentClient

/// 텍스트 합치기 — 블록 delta 를 한 덩어리로 모으되 비-텍스트 이벤트의 순서를 보존한다.
final class ChatStreamSmoothingTests: XCTestCase {
    private func upstream(_ events: [ChatStreamEvent]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func test_text_blocks_are_coalesced_into_single_delta_preserving_event_order() async throws {
        let doneID = UUID()
        let events: [ChatStreamEvent] = [
            .toolStarted(name: "search_items", label: "찾는 중"),
            .messageDelta("안녕"),
            .messageDelta("하세요"),
            .messageDelta(" 반가워요"),
            .done(messageID: doneID),
        ]

        var collected: [ChatStreamEvent] = []
        for try await event in ChatStreamSmoothing.smoothed(upstream(events)) {
            collected.append(event)
        }

        // tool 은 텍스트 앞(버퍼 비어 그대로 통과), 여러 텍스트 블록은 done 직전에 단일
        // messageDelta 로 합쳐져 나온다 — 순서 보존.
        XCTAssertEqual(collected.first, .toolStarted(name: "search_items", label: "찾는 중"))
        let deltas = collected.compactMap { event -> String? in
            if case let .messageDelta(text) = event { return text }
            return nil
        }
        XCTAssertEqual(deltas, ["안녕하세요 반가워요"])
        XCTAssertEqual(collected.last, .done(messageID: doneID))
    }

    func test_text_is_flushed_before_each_non_text_event() async throws {
        let itemID = UUID()
        let events: [ChatStreamEvent] = [
            .messageDelta("본문"),
            .citation(ChatCitation(index: 1, mochiItemID: itemID, title: nil, snippet: nil)),
        ]

        var collected: [ChatStreamEvent] = []
        for try await event in ChatStreamSmoothing.smoothed(upstream(events)) {
            collected.append(event)
        }

        // 텍스트는 citation 보다 먼저 — 본문이 출처 카드 뒤로 밀리지 않는다.
        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected.first, .messageDelta("본문"))
        if case .citation = collected.last {} else {
            XCTFail("citation 이 텍스트 다음에 와야 한다")
        }
    }
}
