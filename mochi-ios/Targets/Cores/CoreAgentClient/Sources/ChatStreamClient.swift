import Foundation

/// 채팅 탭 멀티턴 대화 스트림 — 백엔드 `POST /conversations/{id}/messages` (POST-as-SSE).
///
/// 메시지 전송의 HTTP 응답이 곧 SSE 이벤트 스트림이다(202+별도 GET 분리안은 구독 전 이벤트
/// 유실 레이스로 기각 — journal 2026-06-10). conversationID 는 클라이언트가 생성하고,
/// 서버는 첫 메시지에서 대화를 암묵 생성한다.
///
/// 기존 ``AgentStreamClient``(item 분석 진행 스트림)와 의미가 전혀 달라 **별도 프로토콜** —
/// 한 enum 에 합치면 양쪽 소비자가 무의미한 case 를 들고 다닌다.
public protocol ChatStreamClient: Sendable {
    func send(conversationID: UUID, text: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

/// 백엔드 SSE wire format 과 1:1 (`message_delta`/`tool_started`/`tool_finished`/
/// `citation`/`proposal`/`done`/`error` — error 는 스트림 throw 로 표현).
public enum ChatStreamEvent: Equatable, Sendable {
    case messageDelta(String)
    case toolStarted(name: String, label: String)
    case toolFinished(name: String, summary: String)
    case citation(ChatCitation)
    case proposal(ChatProposal)
    /// messageID = 서버에 영속된 assistant 메시지 행 — 스냅샷 재조회·히스토리(후속 PR)와의 대응 키.
    case done(messageID: UUID)
}

/// 답변이 인용한 기록의 출처 스냅샷 — 본문 `【item:id】` 마커를 index 뱃지로 치환 렌더.
public struct ChatCitation: Equatable, Sendable, Identifiable {
    public let index: Int
    public let mochiItemID: UUID
    public let title: String?
    public let snippet: String?

    public var id: Int { index }

    public init(index: Int, mochiItemID: UUID, title: String?, snippet: String?) {
        self.index = index
        self.mochiItemID = mochiItemID
        self.title = title
        self.snippet = snippet
    }
}

/// 모찌가 제안하는 행동 카드 — LLM 루프는 read-only, 실행은 사용자 확정 탭 → REST.
///
/// PR-1 은 표시 필드만 — kind 별 typed 실행 payload(확정 경로 배선)는 proposal 카드
/// 구현(PR-3)에서 확장한다.
public struct ChatProposal: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case updateItem = "item_update"
        case deleteItem = "item_delete"
        case createSchedule = "create_schedule"
        case createMemo = "create_memo"
        case reminder = "reminder"
    }

    public let id: UUID
    public let kind: Kind
    /// 카드 헤더 — 무엇을 할지 (예: "이 메모를 지울까요?").
    public let title: String
    /// 무엇이 어떻게 바뀌는지 1줄.
    public let detail: String?

    public init(id: UUID, kind: Kind, title: String, detail: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}
