import CoreDomain
import CoreNetworking
import Foundation

/// ``ChatStreamClient`` 라이브 구현 — `POST /api/v1/conversations/{id}/messages` (POST-as-SSE).
///
/// 생성 클라이언트는 스트리밍 응답을 다루지 못해 raw URLSession 으로 소비한다
/// (`LiveAgentStreamClient` 전례 — ARCHITECTURE §3.6 ⓪ 예외). wire format 은 서버
/// `conversations/presentation/router.py` docstring 이 정본:
/// `message_delta`/`tool_started`/`tool_finished`/`citation`/`proposal`/`done`/`error`.
///
/// **워치독 75초**: 서버 run 상한 60초 + 전달 여유. 서버가 끝(done/error)을 영영 안 주는
/// 경우(프록시 행 등)에도 사용자가 빈 화면에 갇히지 않게 클라이언트가 끊는다 — 복귀는
/// 스냅샷 재조회가 메운다.
public struct LiveChatStreamClient: ChatStreamClient {
    private let baseURL: URL
    private let tokenProvider: any AuthTokenProvider
    private let session: URLSession
    private let watchdogSeconds: Double

    public init(
        baseURL: URL,
        tokenProvider: any AuthTokenProvider,
        session: URLSession = .shared,
        watchdogSeconds: Double = 75
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.watchdogSeconds = watchdogSeconds
    }

    public func send(conversationID: UUID, text: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await self.run(
                                conversationID: conversationID, text: text, continuation: continuation
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(self.watchdogSeconds * 1_000_000_000))
                            throw DomainError.networkFailed(
                                reason: "chat stream watchdog timeout", transientRetryAfter: nil
                            )
                        }
                        // 첫 완료 승자 — 본체가 먼저 끝나면 워치독 취소, 워치독이 먼저면 throw.
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        conversationID: UUID,
        text: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: messagesURL(for: conversationID))
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        request.timeoutInterval = watchdogSeconds + 30
        if let token = await tokenProvider.bearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 409 = 같은 대화에 진행 중 run — 복귀 폴링/재시도가 메운다. 그 외도 동일 에러 경로.
            throw DomainError.networkFailed(
                reason: "chat stream HTTP \(http.statusCode)", transientRetryAfter: nil
            )
        }

        var parser = SSEEventParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let (event, data) = parser.consume(line: line) {
                if try dispatch(event: event, data: data, continuation: continuation) {
                    return  // done — 정상 종결
                }
            }
        }
        if let (event, data) = parser.flush() {
            _ = try dispatch(event: event, data: data, continuation: continuation)
        }
    }

    /// 한 이벤트 처리 — 종결(done)이면 true. `error` 이벤트는 서버 메시지 그대로 throw.
    private func dispatch(
        event: String,
        data: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) throws -> Bool {
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        switch event {
        case "message_delta":
            if let text = json["text"] as? String {
                continuation.yield(.messageDelta(text))
            }
        case "tool_started":
            continuation.yield(
                .toolStarted(
                    name: json["name"] as? String ?? "",
                    label: json["label"] as? String ?? ""
                )
            )
        case "tool_finished":
            continuation.yield(
                .toolFinished(
                    name: json["name"] as? String ?? "",
                    summary: json["summary"] as? String ?? ""
                )
            )
        case "citation":
            if let index = json["index"] as? Int,
               let itemID = UUID(uuidString: json["item_id"] as? String ?? "") {
                continuation.yield(
                    .citation(
                        ChatCitation(
                            index: index,
                            mochiItemID: itemID,
                            title: json["title"] as? String,
                            snippet: json["snippet"] as? String
                        )
                    )
                )
            }
        case "proposal":
            if let id = UUID(uuidString: json["id"] as? String ?? ""),
               let type = json["type"] as? String,
               let payload = json["payload"] as? [String: Any],
               let proposal = ChatProposal(id: id, type: type, payload: payload) {
                continuation.yield(.proposal(proposal))
            }
            // 파싱 불가 proposal 은 버린다 — 깨진 카드를 보여주느니 답변 본문만.
        case "done":
            if let messageID = UUID(uuidString: json["message_id"] as? String ?? "") {
                continuation.yield(.done(messageID: messageID))
            }
            return true
        case "error":
            throw DomainError.networkFailed(
                reason: json["message"] as? String ?? "chat run failed", transientRetryAfter: nil
            )
        default:
            break  // 미래 이벤트 — 무시(전방 호환)
        }
        return false
    }

    private func messagesURL(for conversationID: UUID) -> URL {
        baseURL
            .appendingPathComponent("api/v1/conversations")
            .appendingPathComponent(conversationID.uuidString.lowercased())
            .appendingPathComponent("messages")
    }
}
