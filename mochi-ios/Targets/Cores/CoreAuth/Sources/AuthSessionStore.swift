import Foundation

/// 현재 ``AuthSession`` 을 메모리·Keychain 양쪽에서 일관되게 관리하는 actor.
///
/// **책임 한정:** Keychain 영속화 + 메모리 캐시 + 만료 검사. refresh 자체는 ``AuthCoordinator`` 가 담당.
public actor AuthSessionStore {
    private let store: any TokenStore
    private var cached: AuthSession?

    public init(store: any TokenStore) {
        self.store = store
    }

    public func current() -> AuthSession? {
        if let cached { return cached }
        let loaded = try? store.load()
        cached = loaded
        return loaded
    }

    public func update(_ session: AuthSession) throws {
        try store.save(session)
        cached = session
    }

    public func updateTokens(_ tokens: AuthTokens) throws {
        guard let existing = current() else { return }
        let next = AuthSession(user: existing.user, tokens: tokens, isNewUser: existing.isNewUser)
        try store.save(next)
        cached = next
    }

    public func clear() throws {
        try store.clear()
        cached = nil
    }

    public func accessTokenIfValid(now: Date = Date()) -> String? {
        guard let session = current() else { return nil }
        // 60초 안전 여유 — 서버에 도착하기 전에 만료될 위험을 줄인다.
        return now < session.tokens.accessTokenExpiresAt.addingTimeInterval(-60)
            ? session.tokens.accessToken : nil
    }
}
