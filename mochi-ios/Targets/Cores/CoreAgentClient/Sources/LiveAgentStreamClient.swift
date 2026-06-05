import Foundation
import CoreDomain
import CoreNetworking

/// `AgentStreamClient` 의 라이브 구현 — 백엔드 `GET /api/v1/mochi_items/{id}/stream` SSE 를 구독한다.
///
/// **계약(백엔드 `agent/presentation/router.py`)**: 스트림은 처리상태 전이만 흘리고 **분석 결과는 안 보낸다**.
/// - `event: node`  / `data: {"mochi_item_id","lifecycle_kind"}` → 진행 표시
/// - `event: final` / `data: {"mochi_item_id","lifecycle_kind":"analyzed"}` → 완료 신호
/// - `event: failed`/ `data: {"mochi_item_id","message"}` → 실패
///
/// `final` 수신 시 ``MochiAPIClient/getMochiItem(id:)`` 로 재조회해 `MochiItemDTO → MochiItemAnalysis`
/// (단일 매핑 `toMochiItemAnalysis()`)로 변환하고 ``AgentEvent/finalAnalysis(_:)`` 를 emit 후 종료한다.
/// 이중 직렬화(SSE 에 결과를 또 싣기)를 피하는 PR-B 결정.
///
/// **id 규약**: `stream(mochiItemID:)` 의 인자는 **serverID**(백엔드 PK)다 — 로컬 id 로 호출하면 404.
public struct LiveAgentStreamClient: AgentStreamClient {
    private let baseURL: URL
    private let tokenProvider: any AuthTokenProvider
    private let apiClient: any MochiAPIClient
    private let session: URLSession

    public init(
        baseURL: URL,
        tokenProvider: any AuthTokenProvider,
        apiClient: any MochiAPIClient,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.apiClient = apiClient
        self.session = session
    }

    public func stream(mochiItemID: UUID) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(mochiItemID: mochiItemID, continuation: continuation)
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
        mochiItemID: UUID,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: streamURL(for: mochiItemID))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600
        if let token = await tokenProvider.bearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 401·404 등 — 폴링 fallback 이 메우도록 에러로 종료.
            throw DomainError.networkFailed(reason: "stream HTTP \(http.statusCode)", transientRetryAfter: nil)
        }

        var event: String?
        var data = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if try await dispatch(event: event, data: data, mochiItemID: mochiItemID, continuation: continuation) {
                    return  // 종결 이벤트(final/failed) — 스트림 종료.
                }
                event = nil
                data = ""
                continue
            }
            if line.hasPrefix(":") { continue }  // 코멘트(": stream-open")
            if let value = Self.fieldValue(line, prefix: "event:") {
                event = value
            } else if let value = Self.fieldValue(line, prefix: "data:") {
                data += data.isEmpty ? value : "\n" + value
            }
        }
        // 스트림이 boundary 없이 끝난 경우 잔여 dispatch.
        _ = try await dispatch(event: event, data: data, mochiItemID: mochiItemID, continuation: continuation)
    }

    /// 누적된 한 이벤트를 처리. 종결 이벤트(final/failed)면 `true` 를 반환해 run 루프를 끝낸다.
    private func dispatch(
        event: String?,
        data: String,
        mochiItemID: UUID,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> Bool {
        guard let event, !data.isEmpty else { return false }
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        switch event {
        case "node":
            let kind = json["lifecycle_kind"] as? String ?? "ingested"
            continuation.yield(.nodeEntered(AgentNode(rawValue: kind) ?? .ingested))
            return false
        case "final":
            let dto = try await apiClient.getMochiItem(id: mochiItemID)
            continuation.yield(.finalAnalysis(dto.toMochiItemAnalysis()))
            return true
        case "failed":
            let message = json["message"] as? String ?? "failed"
            continuation.yield(.failed(node: .failed, message: message))
            return true
        default:
            return false
        }
    }

    private func streamURL(for mochiItemID: UUID) -> URL {
        baseURL
            .appendingPathComponent("api/v1/mochi_items")
            .appendingPathComponent(mochiItemID.uuidString.lowercased())
            .appendingPathComponent("stream")
    }

    /// `"data: {...}"` → `"{...}"`. 콜론 뒤 선행 공백 1개만 제거(SSE 규약).
    private static func fieldValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var rest = Substring(line.dropFirst(prefix.count))
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }
}
