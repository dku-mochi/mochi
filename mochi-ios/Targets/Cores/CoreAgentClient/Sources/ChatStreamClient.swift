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
/// `action` 이 kind 별 typed 실행 payload — 백엔드 `propose.py` 의 proposal payload 와 1:1.
/// 실행 경로 매핑(서버 docstring 정본): item_update→PATCH, item_delete→DELETE,
/// create_schedule→POST+confirmedInstances, create_memo→일반 ingestion, reminder→iOS 로컬 알림.
public struct ChatProposal: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case updateItem = "item_update"
        case deleteItem = "item_delete"
        case createSchedule = "create_schedule"
        case createMemo = "create_memo"
        case reminder = "reminder"
    }

    public struct InstanceChange: Equatable, Sendable {
        public let instanceID: UUID
        /// 부분 payload 필드 (title/date/time/deadline/person/topic/url/note) — 병합 PATCH.
        public let payload: [String: String]
        public let label: String?
        public let lifecycleTo: String?
        public let archiveReason: String?

        public init(
            instanceID: UUID, payload: [String: String] = [:],
            label: String? = nil, lifecycleTo: String? = nil, archiveReason: String? = nil
        ) {
            self.instanceID = instanceID
            self.payload = payload
            self.label = label
            self.lifecycleTo = lifecycleTo
            self.archiveReason = archiveReason
        }
    }

    public struct UpdateItemPayload: Equatable, Sendable {
        public let mochiItemID: UUID
        public let text: String?
        public let userMemo: String?
        public let summary: String?
        public let instanceChanges: [InstanceChange]

        public init(
            mochiItemID: UUID, text: String? = nil, userMemo: String? = nil,
            summary: String? = nil, instanceChanges: [InstanceChange] = []
        ) {
            self.mochiItemID = mochiItemID
            self.text = text
            self.userMemo = userMemo
            self.summary = summary
            self.instanceChanges = instanceChanges
        }
    }

    public struct ConfirmedInstance: Equatable, Sendable {
        public let intentType: String
        public let payload: [String: String]

        public init(intentType: String, payload: [String: String]) {
            self.intentType = intentType
            self.payload = payload
        }
    }

    public struct CreateSchedulePayload: Equatable, Sendable {
        public let text: String?
        public let instances: [ConfirmedInstance]

        public init(text: String?, instances: [ConfirmedInstance]) {
            self.text = text
            self.instances = instances
        }
    }

    public struct ReminderPayload: Equatable, Sendable {
        public let fireAt: Date
        public let title: String
        public let relatedMochiItemID: UUID?

        public init(fireAt: Date, title: String, relatedMochiItemID: UUID? = nil) {
            self.fireAt = fireAt
            self.title = title
            self.relatedMochiItemID = relatedMochiItemID
        }
    }

    public enum ProposedAction: Equatable, Sendable {
        case updateItem(UpdateItemPayload)
        case deleteItem(mochiItemID: UUID)
        case createSchedule(CreateSchedulePayload)
        case createMemo(text: String)
        case reminder(ReminderPayload)
    }

    public let id: UUID
    /// 카드 헤더 — 무엇을 할지 (예: "이 메모를 지울까요?"). 서버 display.title.
    public let title: String
    /// 무엇이 어떻게 바뀌는지 1줄. 서버 display.description.
    public let detail: String?
    public let action: ProposedAction

    public var kind: Kind {
        switch action {
        case .updateItem: .updateItem
        case .deleteItem: .deleteItem
        case .createSchedule: .createSchedule
        case .createMemo: .createMemo
        case .reminder: .reminder
        }
    }

    public init(id: UUID, title: String, detail: String?, action: ProposedAction) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
    }
}

public extension ChatProposal {
    /// SSE `proposal` 이벤트·스냅샷 `proposals` 행의 JSON → typed proposal.
    /// 알 수 없는 type / 필수 필드 결손이면 nil — 깨진 카드를 보여주느니 숨긴다(서버가 검증 정본).
    init?(id: UUID, type: String, payload: [String: Any]) {
        guard let kind = Kind(rawValue: type) else { return nil }
        let display = payload["display"] as? [String: Any]
        let title = (display?["title"] as? String) ?? ""
        let detail = display?["description"] as? String

        let action: ProposedAction
        switch kind {
        case .deleteItem:
            guard let itemID = UUID(uuidString: payload["mochi_item_id"] as? String ?? "") else { return nil }
            action = .deleteItem(mochiItemID: itemID)

        case .updateItem:
            guard let itemID = UUID(uuidString: payload["mochi_item_id"] as? String ?? "") else { return nil }
            let changes = payload["changes"] as? [String: Any] ?? [:]
            var instanceChanges: [InstanceChange] = []
            for raw in payload["instance_changes"] as? [[String: Any]] ?? [] {
                guard let instanceID = UUID(uuidString: raw["instance_id"] as? String ?? "") else { return nil }
                let lifecycle = raw["lifecycle"] as? [String: Any]
                instanceChanges.append(
                    InstanceChange(
                        instanceID: instanceID,
                        payload: (raw["payload"] as? [String: String]) ?? [:],
                        label: raw["label"] as? String,
                        lifecycleTo: lifecycle?["to"] as? String,
                        archiveReason: lifecycle?["archive_reason"] as? String
                    )
                )
            }
            action = .updateItem(
                UpdateItemPayload(
                    mochiItemID: itemID,
                    text: changes["text"] as? String,
                    userMemo: changes["user_memo"] as? String,
                    summary: changes["summary"] as? String,
                    instanceChanges: instanceChanges
                )
            )

        case .createSchedule:
            let instances = (payload["confirmed_instances"] as? [[String: Any]] ?? []).compactMap {
                raw -> ConfirmedInstance? in
                guard let intentType = raw["intent_type"] as? String else { return nil }
                return ConfirmedInstance(
                    intentType: intentType, payload: (raw["payload"] as? [String: String]) ?? [:]
                )
            }
            guard !instances.isEmpty else { return nil }
            action = .createSchedule(
                CreateSchedulePayload(text: payload["text"] as? String, instances: instances)
            )

        case .createMemo:
            guard let text = payload["text"] as? String, !text.isEmpty else { return nil }
            action = .createMemo(text: text)

        case .reminder:
            guard let rawFireAt = payload["fire_at"] as? String,
                  let fireAt = ISO8601DateFormatter.chatProposal.date(from: rawFireAt)
                    ?? ISO8601DateFormatter.chatProposalNoFraction.date(from: rawFireAt),
                  let reminderTitle = payload["title"] as? String
            else { return nil }
            let related = UUID(uuidString: payload["related_mochi_item_id"] as? String ?? "")
            action = .reminder(
                ReminderPayload(fireAt: fireAt, title: reminderTitle, relatedMochiItemID: related)
            )
        }

        self.init(id: id, title: title, detail: detail, action: action)
    }
}

private extension ISO8601DateFormatter {
    /// 백엔드 fire_at 은 `+09:00` offset 포함 ISO — 초단위(.withInternetDateTime)와
    /// 소수점 초 두 변형을 모두 수용한다.
    static let chatProposal: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let chatProposalNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
