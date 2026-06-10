import Dependencies
import Foundation

/// 진행 중 대화의 (conversationID, 마지막 활동 시각) 영속 — 비활성 30분 자동분리의 데이터.
///
/// 사용자가 세션을 관리하게 하지 않는다(미션 — "모찌가 알아서"): 30분 안에 돌아오면
/// 하던 대화가 그대로, 지나면 조용히 새 대화. UserDefaults 면 충분하다(잃어도 새 대화일 뿐).
public struct ChatSessionStore: Sendable {
    public struct PersistedSession: Equatable, Sendable {
        public let conversationID: UUID
        public let lastActivityAt: Date

        public init(conversationID: UUID, lastActivityAt: Date) {
            self.conversationID = conversationID
            self.lastActivityAt = lastActivityAt
        }
    }

    public var load: @Sendable () -> PersistedSession?
    public var save: @Sendable (_ conversationID: UUID, _ activityAt: Date) -> Void
    public var clear: @Sendable () -> Void

    public init(
        load: @escaping @Sendable () -> PersistedSession?,
        save: @escaping @Sendable (UUID, Date) -> Void,
        clear: @escaping @Sendable () -> Void
    ) {
        self.load = load
        self.save = save
        self.clear = clear
    }
}

public extension ChatSessionStore {
    static let userDefaults: ChatSessionStore = {
        let idKey = "chat.session.conversationID"
        let activityKey = "chat.session.lastActivityAt"
        return ChatSessionStore(
            load: {
                let defaults = UserDefaults.standard
                guard let raw = defaults.string(forKey: idKey),
                      let id = UUID(uuidString: raw),
                      let activity = defaults.object(forKey: activityKey) as? Date
                else { return nil }
                return PersistedSession(conversationID: id, lastActivityAt: activity)
            },
            save: { id, activityAt in
                let defaults = UserDefaults.standard
                defaults.set(id.uuidString, forKey: idKey)
                defaults.set(activityAt, forKey: activityKey)
            },
            clear: {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: idKey)
                defaults.removeObject(forKey: activityKey)
            }
        )
    }()

    /// 테스트 기본값 — 영속 없음. 시나리오별 스텁은 테스트가 직접 주입.
    static let noop = ChatSessionStore(load: { nil }, save: { _, _ in }, clear: {})
}

public enum ChatSessionStoreKey: DependencyKey {
    public static let liveValue: ChatSessionStore = .userDefaults
    public static let testValue: ChatSessionStore = .noop
}

public extension DependencyValues {
    var chatSessionStore: ChatSessionStore {
        get { self[ChatSessionStoreKey.self] }
        set { self[ChatSessionStoreKey.self] = newValue }
    }
}
