import Foundation

/// 한 캡처에서 추출된 의도 1건.
///
/// 저장되면 곧 active — 점수·위계 없다(2026-06-04 빅뱅). 같은 `intentType` 이 여러 instance 로
/// 중복될 수 있다(한 캡처에 todo 둘). `id` 는 로컬 식별자(Realm row·UI list)이며, 서버는 instance id 를
/// 응답에 싣지 않으므로 동기화 시마다 새로 부여된다(서버는 전량 delete-reinsert).
public struct IntentInstance: Equatable, Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let intentType: Intent
    public let payload: IntentPayload
    public let label: String?
    public let reasoning: String?
    public var lifecycle: InstanceLifecycle

    public init(
        id: UUID = UUID(),
        intentType: Intent,
        payload: IntentPayload = .init(),
        label: String? = nil,
        reasoning: String? = nil,
        lifecycle: InstanceLifecycle = .active
    ) {
        self.id = id
        self.intentType = intentType
        self.payload = payload
        self.label = label
        self.reasoning = reasoning
        self.lifecycle = lifecycle
    }

    /// UI 라벨 — 시나리오 라벨이 있으면 그것, 없으면 intent 표시명.
    public var displayLabel: String { label ?? intentType.displayName }
}

/// intent instance 의 구조화 속성 (전부 optional).
public struct IntentPayload: Equatable, Sendable, Hashable, Codable {
    public var title: String?
    public var date: String?
    public var time: String?
    public var deadline: String?
    public var person: String?
    public var topic: String?
    public var url: String?
    public var note: String?

    public init(
        title: String? = nil,
        date: String? = nil,
        time: String? = nil,
        deadline: String? = nil,
        person: String? = nil,
        topic: String? = nil,
        url: String? = nil,
        note: String? = nil
    ) {
        self.title = title
        self.date = date
        self.time = time
        self.deadline = deadline
        self.person = person
        self.topic = topic
        self.url = url
        self.note = note
    }

    public var isEmpty: Bool {
        title == nil && date == nil && time == nil && deadline == nil
            && person == nil && topic == nil && url == nil && note == nil
    }
}

/// `needsReview == true` 일 때 사용자에게 제시하는 미확정 후보 (점수·정렬 없음).
public struct ReviewOption: Equatable, Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let intentType: Intent
    public let label: String?
    public let reasoning: String?

    public init(id: UUID = UUID(), intentType: Intent, label: String? = nil, reasoning: String? = nil) {
        self.id = id
        self.intentType = intentType
        self.label = label
        self.reasoning = reasoning
    }

    /// UI 라벨 — 시나리오 라벨이 있으면 그것, 없으면 intent 표시명.
    public var displayLabel: String { label ?? intentType.displayName }
}
