import CoreDomain
import Dependencies
import Foundation

public enum ChatStreamClientKey: DependencyKey {
    public static let liveValue: any ChatStreamClient = NotConfiguredChatStreamClient()
    public static let testValue: any ChatStreamClient = NotConfiguredChatStreamClient()
    public static let previewValue: any ChatStreamClient = MockChatStreamClient()
}

public extension DependencyValues {
    var chatStreamClient: any ChatStreamClient {
        get { self[ChatStreamClientKey.self] }
        set { self[ChatStreamClientKey.self] = newValue }
    }
}

/// 라이브 클라이언트가 주입되지 않은 채 호출되면 명확한 에러를 던지는 sentinel.
public struct NotConfiguredChatStreamClient: ChatStreamClient {
    public init() {}
    public func send(conversationID: UUID, text: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DomainError.networkFailed(reason: "ChatStreamClient not configured", transientRetryAfter: nil))
        }
    }
}

/// 백엔드 배선 전 데모/프리뷰용 — 검색 툴이 도는 듯한 canned 시퀀스를 타이핑 속도로 흘린다.
/// 서버 어댑터(LiveChatStreamClient) 교체 시 시그니처 동일 (PR-5).
public struct MockChatStreamClient: ChatStreamClient {
    let delayFactor: Double

    public init(delayFactor: Double = 1.0) {
        self.delayFactor = delayFactor
    }

    public func send(conversationID: UUID, text: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                func sleep(_ seconds: Double) async throws {
                    try await Task.sleep(nanoseconds: UInt64(seconds * delayFactor * 1_000_000_000))
                }
                do {
                    let citedID = UUID()
                    try await sleep(0.4)
                    continuation.yield(.toolStarted(name: "search_items", label: "기록을 뒤지고 있어요"))
                    try await sleep(1.1)
                    continuation.yield(.toolFinished(name: "search_items", summary: "기록 3개를 찾았어요"))
                    try await sleep(0.3)
                    // 본문 마커는 서버와 동일하게 raw 로 흘린다 — 표시 치환은 클라이언트 책임 (PR-2).
                    let answer = "남겨두신 기록을 봤어요. 지난주에 저장한 카페 두 곳이 있는데, 그중 한강 근처 베이커리 카페가 분위기 메모와 가장 잘 맞아요【item:\(citedID.uuidString.lowercased())】. 지도 스크린샷도 같이 남겨두셨더라고요."
                    for character in answer {
                        continuation.yield(.messageDelta(String(character)))
                        try await sleep(0.012)
                    }
                    continuation.yield(
                        .citation(
                            ChatCitation(
                                index: 1,
                                mochiItemID: citedID,
                                title: "한강 베이커리 카페",
                                snippet: "통창 뷰가 좋다고 메모"
                            )
                        )
                    )
                    continuation.yield(.done(messageID: UUID()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
