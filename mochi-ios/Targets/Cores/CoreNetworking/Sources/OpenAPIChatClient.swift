import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// 생성 클라이언트(`openapi.json` ⓪계약)를 ``ChatAPIClient`` 로 감싸는 어댑터.
///
/// 메시지 전송(POST-as-SSE)은 생성 클라이언트가 스트리밍을 다루지 못해 여기 없다 —
/// `LiveChatStreamClient`(CoreAgentClient, raw URLSession) 소관. ARCHITECTURE §3.6 ⓪ 예외.
public final class OpenAPIChatClient: ChatAPIClient, @unchecked Sendable {
    private let client: Client

    public init(baseURL: URL, tokenProvider: any AuthTokenProvider) {
        self.client = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: MochiDateTranscoder()),
            transport: URLSessionTransport(),
            middlewares: [AuthMiddleware(tokenProvider: tokenProvider)]
        )
    }

    public func listConversations(limit: Int) async throws -> [ChatConversationDTO] {
        let output = try await client.list_conversations_api_v1_conversations_get(
            .init(query: .init(limit: limit))
        )
        switch output {
        case let .ok(response):
            return try (response.body.json.conversations ?? []).map(Self.mapConversation)
        case let .undocumented(status, payload):
            throw await Self.error(status: status, payload: payload)
        }
    }

    public func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
        let output = try await client.get_conversation_snapshot_api_v1_conversations__conversation_id__messages_get(
            .init(path: .init(conversation_id: id.uuidString))
        )
        switch output {
        case let .ok(response):
            let dto = try response.body.json
            return ChatSnapshotDTO(
                conversation: try Self.mapConversation(dto.conversation),
                messages: (dto.messages ?? []).compactMap(Self.mapMessage)
            )
        case let .undocumented(status, payload):
            throw await Self.error(status: status, payload: payload)
        }
    }

    public func deleteConversation(id: UUID) async throws {
        let output = try await client.delete_conversation_api_v1_conversations__conversation_id__delete(
            .init(path: .init(conversation_id: id.uuidString))
        )
        switch output {
        case .noContent: return
        case let .undocumented(status, payload):
            throw await Self.error(status: status, payload: payload)
        }
    }

    // MARK: - 매핑

    private static func mapConversation(
        _ dto: Components.Schemas.ConversationResponse
    ) throws -> ChatConversationDTO {
        guard let id = UUID(uuidString: dto.id) else {
            throw APIErrorEnvelope(
                code: "client.invalid_uuid", message: dto.id, requestID: "n/a", retryAfter: nil
            )
        }
        return ChatConversationDTO(
            id: id, title: dto.title, createdAt: dto.createdAt, updatedAt: dto.updatedAt
        )
    }

    /// 행 1개 매핑 — id 가 깨진 행만 버리고 나머지는 보존한다.
    private static func mapMessage(
        _ dto: Components.Schemas.MessageResponse
    ) -> ChatSnapshotMessageDTO? {
        guard let id = UUID(uuidString: dto.id) else { return nil }

        // tool_payload(자유 jsonb)는 Codable 컨테이너 → JSON dict 로 풀어 summary 만 쓴다.
        // label 은 서버가 영속하지 않는다(스트림 전용) — fold 가 summary/이름으로 표시.
        let toolPayload = dto.toolPayload.flatMap(Self.jsonObject)
        let proposals: [ChatProposalEnvelopeDTO] = (dto.proposals ?? []).compactMap { raw in
            guard let object = Self.jsonObject(raw),
                  let proposalID = UUID(uuidString: object["id"] as? String ?? ""),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let payloadJSON = try? JSONSerialization.data(withJSONObject: payload)
            else { return nil }
            return ChatProposalEnvelopeDTO(id: proposalID, type: type, payloadJSON: payloadJSON)
        }

        return ChatSnapshotMessageDTO(
            id: id,
            role: dto.role,
            content: dto.content,
            toolName: dto.toolName,
            toolLabel: nil,
            toolSummary: toolPayload?["summary"] as? String,
            runStatus: dto.runStatus,
            citations: (dto.citations ?? []).compactMap { citation in
                guard let itemID = UUID(uuidString: citation.mochiItemId) else { return nil }
                return ChatCitationDTO(
                    index: citation.index, mochiItemID: itemID,
                    title: citation.title, snippet: citation.snippet
                )
            },
            proposals: proposals
        )
    }

    /// 임의 jsonb Codable 컨테이너 → [String: Any] (encode 후 재파싱 — 컨테이너 내부 표현 비의존).
    private static func jsonObject(_ container: some Encodable) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(container) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func error(
        status: Int, payload: OpenAPIRuntime.UndocumentedPayload
    ) async -> APIErrorEnvelope {
        if let body = payload.body,
           let data = try? await Data(collecting: body, upTo: 1 << 16),
           let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return envelope
        }
        return APIErrorEnvelope(
            code: "http.\(status)", message: "HTTP \(status)", requestID: "n/a", retryAfter: nil
        )
    }
}
