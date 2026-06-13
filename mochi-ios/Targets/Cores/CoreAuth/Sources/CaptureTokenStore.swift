import Foundation
import Security

/// ShareExtension 직접 전송용 capture-scoped token 의 로컬 표현.
///
/// - ``token``: raw secret (`mct_` prefix). 서버는 hash 만 보관하므로 이 사본이 유일하다.
/// - ``expiresAt``: **발급 시점의 최소 보장 만료**. 서버는 sliding TTL(사용 시 연장)이라
///   실제 만료는 이보다 늦을 수 있다 — 만료 판단의 정본은 항상 서버다. 이 값은 메인 앱의
///   선제 재발급(잔여 < 30일) 판단에만 쓴다.
/// - ``userID``: 발급받은 계정. 세션 사용자와 불일치하면 재발급한다 — 로그아웃 없는 계정
///   전환 시 이전 계정 명의로 업로드되는 cross-account 오염을 막는 불변식.
public struct CaptureTokenRecord: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Date
    public let userID: UUID

    public init(token: String, expiresAt: Date, userID: UUID) {
        self.token = token
        self.expiresAt = expiresAt
        self.userID = userID
    }
}

/// capture token 의 공유 Keychain 저장소 추상화.
///
/// ``AuthSession`` item 과 **분리**한 이유: 세션 item 은 refresh 회전마다 다시 써지고
/// 강제 로그아웃 시 clear 된다 — 장수명 토큰을 거기 섞으면 수명이 엉킨다.
public protocol CaptureTokenStore: Sendable {
    func load() throws -> CaptureTokenRecord?
    func save(_ record: CaptureTokenRecord) throws
    func clear() throws
}

/// ``KeychainTokenStore`` 와 동일 정책의 별도 Keychain item.
///
/// - 같은 service(`app.mochi.auth`) 의 다른 account(`capture_token`).
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + 비동기화(iCloud 금지).
/// - access group 미지정 — entitlements 첫 그룹(App/ShareExt/Widgets 공유)에 의존하는
///   기존 패턴 유지. ShareExtension 이 이 item 을 직접 읽는다.
public struct KeychainCaptureTokenStore: CaptureTokenStore {
    private let service: String
    private let account: String

    public init(
        service: String = "app.mochi.auth",
        account: String = "capture_token"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> CaptureTokenRecord? {
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
        return try Self.decoder.decode(CaptureTokenRecord.self, from: data)
    }

    public func save(_ record: CaptureTokenRecord) throws {
        let data = try Self.encoder.encode(record)

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

/// In-memory ``CaptureTokenStore`` — preview / 테스트용.
public final class InMemoryCaptureTokenStore: CaptureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureTokenRecord?

    public init(initial: CaptureTokenRecord? = nil) {
        self.stored = initial
    }

    public func load() throws -> CaptureTokenRecord? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ record: CaptureTokenRecord) throws {
        lock.lock(); defer { lock.unlock() }
        stored = record
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
