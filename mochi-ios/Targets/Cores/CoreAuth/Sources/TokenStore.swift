import Foundation
import Security

/// Keychain 기반 토큰 저장소.
///
/// **저장 정책:**
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: 첫 unlock 후에만 read 가능 + 다른 디바이스로 백업/이주 금지.
/// - 단일 service / account 쌍에 JSON 으로 직렬화한 ``AuthSession`` 하나만 저장한다.
/// - access secret 자체는 64+ bytes 라서 Keychain item 크기 제한 (4KB) 안에 여유 있음.
///
/// 동기 API — Keychain 호출은 fast in-memory 작업이라 actor 안 쓴다.
public protocol TokenStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.IndexFinger.mochi.auth",
        account: String = "session"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status, op: "load")
        }
        return try Self.decoder.decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession) throws {
        let data = try Self.encoder.encode(session)

        // 기존 항목 갱신을 위해 add → on duplicate, update
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            throw KeychainError(status: updateStatus, op: "update")
        }
        throw KeychainError(status: status, op: "add")
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError(status: status, op: "delete")
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
    public let op: String
}

/// In-memory ``TokenStore`` — preview / 테스트 / SwiftUI #Preview 용.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthSession?

    public init(initial: AuthSession? = nil) {
        self.stored = initial
    }

    public func load() throws -> AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ session: AuthSession) throws {
        lock.lock(); defer { lock.unlock() }
        stored = session
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
