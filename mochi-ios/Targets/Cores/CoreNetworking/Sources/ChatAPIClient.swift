import Dependencies
import Foundation

/// 채팅 세션 REST — `/conversations` 목록·스냅샷·삭제.
///
/// 메시지 *전송*은 여기 없다 — POST-as-SSE 라 `ChatStreamClient`(CoreAgentClient) 소관.
/// `MochiAPIClient` 와 분리해 채팅 UI(PR-4)가 mock 으로 백엔드 무관하게 진행되고,
/// live 어댑터(`OpenAPIChatClient`)는 live 배선 PR 에서 주입된다.
public protocol ChatAPIClient: Sendable {
    /// 히스토리 시트 — 마지막 활동 내림차순.
    func listConversations(limit: Int) async throws -> [ChatConversationDTO]
    /// 대화 메시지 전체 스냅샷 — 히스토리 재진입·포그라운드 복귀의 단일 데이터 소스.
    /// 404(soft delete 포함) 는 throw — 호출부가 새 대화로 폴백.
    func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO
    /// 스와이프 삭제 — 서버 soft delete.
    func deleteConversation(id: UUID) async throws
    /// proposal 카드 확정/취소 영속 — 확정 실행(REST/로컬 알림) **성공 후** 호출.
    /// 스냅샷 복귀 시 카드가 pending 으로 되살아나지 않게 하는 단일 원천. 404 = 이미 없는 카드.
    func setProposalStatus(
        conversationID: UUID, proposalID: UUID, status: ChatProposalStatusUpdate
    ) async throws
}

/// 영속 대상 상태 — confirmed/cancelled 만. expired·failed 는 재확정 시 결정적으로
/// 재현되는 일시 상태라 서버에 저장하지 않는다 (서버 schemas 와 1:1).
public enum ChatProposalStatusUpdate: String, Sendable {
    case confirmed
    case cancelled
}

// MARK: - DTOs (서버 ConversationResponse/MessageResponse 와 1:1)

public struct ChatConversationDTO: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// 첫 user 메시지 40자 truncate (서버 생성).
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, title: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChatSnapshotDTO: Sendable, Equatable {
    public let conversation: ChatConversationDTO
    public let messages: [ChatSnapshotMessageDTO]

    public init(conversation: ChatConversationDTO, messages: [ChatSnapshotMessageDTO]) {
        self.conversation = conversation
        self.messages = messages
    }
}

public struct ChatSnapshotMessageDTO: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// "user" / "assistant" / "tool" (서버 MessageRole).
    public let role: String
    public let content: String?
    public let toolName: String?
    /// tool 행 payload 중 UI 가 쓰는 필드만 — label(동사형)·summary(완료 1줄).
    public let toolLabel: String?
    public let toolSummary: String?
    /// user 행의 run 상태 — "running" 이면 복귀 폴링 대상.
    public let runStatus: String?
    public let citations: [ChatCitationDTO]
    public let proposals: [ChatProposalEnvelopeDTO]

    public init(
        id: UUID, role: String, content: String?,
        toolName: String? = nil, toolLabel: String? = nil, toolSummary: String? = nil,
        runStatus: String? = nil,
        citations: [ChatCitationDTO] = [], proposals: [ChatProposalEnvelopeDTO] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolLabel = toolLabel
        self.toolSummary = toolSummary
        self.runStatus = runStatus
        self.citations = citations
        self.proposals = proposals
    }
}

public struct ChatCitationDTO: Sendable, Equatable {
    public let index: Int
    public let mochiItemID: UUID
    public let title: String?
    public let snippet: String?

    public init(index: Int, mochiItemID: UUID, title: String?, snippet: String?) {
        self.index = index
        self.mochiItemID = mochiItemID
        self.title = title
        self.snippet = snippet
    }
}

/// proposal 행의 운반체 — payload 는 **raw JSON bytes**. typed 파싱(`ChatProposal`)은
/// CoreAgentClient 소관이라(모듈 방향: CoreAgentClient → CoreNetworking) 여기선 통과만 시킨다.
public struct ChatProposalEnvelopeDTO: Sendable, Equatable {
    public let id: UUID
    public let type: String
    public let payloadJSON: Data
    /// 영속된 카드 상태 — "confirmed"/"cancelled", 없으면(pending) nil.
    public let status: String?

    public init(id: UUID, type: String, payloadJSON: Data, status: String? = nil) {
        self.id = id
        self.type = type
        self.payloadJSON = payloadJSON
        self.status = status
    }
}

// MARK: - DI

public enum ChatAPIClientKey: DependencyKey {
    public static let liveValue: any ChatAPIClient = NotConfiguredChatAPIClient()
    public static let testValue: any ChatAPIClient = NotConfiguredChatAPIClient()
    public static let previewValue: any ChatAPIClient = MockChatAPIClient()
}

public extension DependencyValues {
    var chatAPIClient: any ChatAPIClient {
        get { self[ChatAPIClientKey.self] }
        set { self[ChatAPIClientKey.self] = newValue }
    }
}

public struct NotConfiguredChatAPIClient: ChatAPIClient {
    public init() {}
    public func listConversations(limit: Int) async throws -> [ChatConversationDTO] { throw Self.error }
    public func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO { throw Self.error }
    public func deleteConversation(id: UUID) async throws { throw Self.error }
    public func setProposalStatus(
        conversationID: UUID, proposalID: UUID, status: ChatProposalStatusUpdate
    ) async throws { throw Self.error }
    private static let error = APIErrorEnvelope(
        code: "client.not_configured", message: "ChatAPIClient not wired", requestID: "n/a", retryAfter: nil
    )
}

/// 백엔드 배선 전 데모/프리뷰용 — canned 세션 2개와 그 스냅샷.
public struct MockChatAPIClient: ChatAPIClient {
    public init() {}

    public func listConversations(limit: Int) async throws -> [ChatConversationDTO] {
        [
            ChatConversationDTO(
                id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                title: "오늘 데이트 어디서 갈까?",
                createdAt: Date(timeIntervalSinceNow: -7200),
                updatedAt: Date(timeIntervalSinceNow: -7100)
            ),
            ChatConversationDTO(
                id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                title: "이번주 공부하려고 남긴 기록 알려줘",
                createdAt: Date(timeIntervalSinceNow: -90_000),
                updatedAt: Date(timeIntervalSinceNow: -89_000)
            ),
        ]
    }

    public func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
        ChatSnapshotDTO(
            conversation: ChatConversationDTO(
                id: id, title: "오늘 데이트 어디서 갈까?",
                createdAt: Date(timeIntervalSinceNow: -7200),
                updatedAt: Date(timeIntervalSinceNow: -7100)
            ),
            messages: [
                ChatSnapshotMessageDTO(id: UUID(), role: "user", content: "오늘 데이트 어디서 갈까?"),
                ChatSnapshotMessageDTO(
                    id: UUID(), role: "tool", content: nil,
                    toolName: "search_items", toolLabel: "기록을 뒤지고 있어요", toolSummary: "기록 3개를 찾았어요"
                ),
                ChatSnapshotMessageDTO(
                    id: UUID(), role: "assistant",
                    content: "지난주에 저장하신 한강 베이커리 카페가 좋아 보여요.",
                    citations: [
                        ChatCitationDTO(index: 1, mochiItemID: UUID(), title: "한강 베이커리 카페", snippet: "통창 뷰")
                    ]
                ),
            ]
        )
    }

    public func deleteConversation(id: UUID) async throws {}

    public func setProposalStatus(
        conversationID: UUID, proposalID: UUID, status: ChatProposalStatusUpdate
    ) async throws {}
}
