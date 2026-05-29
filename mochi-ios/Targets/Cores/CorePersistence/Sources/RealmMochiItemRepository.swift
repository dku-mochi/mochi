import Foundation
import RealmSwift
import CoreDomain

/// Realm 기반 `MochiItemRepository` 구현. App·ShareExtension 이 동일 App Group Realm 파일을 공유한다.
/// (AppIntents 는 메인 App 타겟 안에 있어 App 의 Realm 접근을 그대로 쓴다.)
///
/// 모든 read/write는 `realm.writeAsync` 를 통해 Realm thread 안에서 수행하고,
/// 도메인 객체와 Realm 객체 사이는 ``RealmMochiItemMapper`` 가 책임진다.
public actor RealmMochiItemRepository: MochiItemRepository {
    public init() {
        _ = RealmStoreFactory.makeConfiguration()
    }

    public func enqueueIngestedFromExtension(_ source: IngestSource) async throws {
        try await upsert(MochiItem(source: source))
    }

    public func upsert(_ mochiItem: MochiItem) async throws {
        try await write { realm in
            let row = RealmMochiItemMapper.toRealm(mochiItem)
            realm.add(row, update: .modified)
        }
    }

    public func updateLifecycle(mochiItemID: UUID, to newState: LifecycleState) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            if let intentRaw = row.intentRawValue, let intent = Intent(rawValue: intentRaw) {
                let currentState = RealmMochiItemMapper.lifecycleState(from: row)
                if case .failure(let error) = LifecyclePolicy.validate(from: currentState, to: newState, intent: intent) {
                    throw DomainError.lifecycleTransition(error)
                }
            }
            RealmMochiItemMapper.apply(lifecycleState: newState, to: row)
            row.updatedAt = .init()
        }
    }

    public func updateSync(mochiItemID: UUID, to newState: SyncState) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            // SyncState 직렬화는 간단한 string + JSON detail 로 (Realm 친화).
            row.syncStateRawValue = RealmMochiItemMapper.syncStateRaw(newState)
            row.updatedAt = .init()
        }
    }

    public func find(id: UUID) async throws -> MochiItem? {
        try await read { realm in
            realm.object(ofType: RealmMochiItem.self, forPrimaryKey: id.uuidString).map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listRecent(limit: Int) async throws -> [MochiItem] {
        try await read { realm in
            realm.objects(RealmMochiItem.self).sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit).map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listByIntent(_ intent: Intent, limit: Int) async throws -> [MochiItem] {
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter("intentRawValue == %@", intent.rawValue)
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listAmbiguous(limit: Int) async throws -> [MochiItem] {
        // intentRawValue == nil 인 행 — 분석 미수신 또는 모델이 intent 미결정.
        // archived/failed 는 "헷갈려요" 에서 제외 (listByImportance 와 동일 lifecycle 정책).
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "intentRawValue == nil AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'archived') AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'failed')"
                )
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listByImportance(limit: Int) async throws -> [MochiItem] {
        // lifecycleStateRawValue 는 'archived:<reason>' / 'failed:<reason>' 형태 (RealmMochiItemMapper).
        // 그래서 BEGINSWITH 로 prefix 매칭해 둘 모두 제외.
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "intentRawValue != nil AND importance >= 3 AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'archived') AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'failed')"
                )
                .sorted(by: [
                    SortDescriptor(keyPath: "importance", ascending: false),
                    SortDescriptor(keyPath: "createdAt", ascending: false),
                ])
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func setIntent(mochiItemID: UUID, intent: Intent) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            row.intentRawValue = intent.rawValue
            // 사용자 수동 분류는 confidence 최대 + 모델 버전 'manual' 로 마킹.
            row.confidence = 1.0
            row.modelVersion = "manual"
            if row.analyzedAt == nil { row.analyzedAt = Date() }
            row.updatedAt = .init()
        }
    }

    public func deleteAll() async throws {
        try await write { realm in
            realm.deleteAll()
        }
    }

    // MARK: - Change observation

    /// Realm collection 알림으로 변경을 감지해 스트림으로 방출한다.
    /// Realm 의 cross-process 알림 덕에 ShareExtension·AppIntents 등 **다른 프로세스의 쓰기**도 잡힌다.
    ///
    /// 알림 토큰은 run loop 가 있는 스레드에서만 콜백이 도므로 MainActor(메인 run loop) 에 둔다.
    /// 화면(소비자)이 스트림을 끊으면 `onTermination` 에서 토큰을 무효화한다.
    public nonisolated func observeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task { @MainActor in
                let observer = RealmChangeObserver(continuation: continuation)
                observer.start()
                continuation.onTermination = { _ in
                    Task { @MainActor in observer.stop() }
                }
            }
        }
    }

    // MARK: - Realm thread bridge

    private func read<T>(_ block: @escaping (Realm) throws -> T) async throws -> T {
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            return try block(realm)
        }.value
    }

    private func write(_ block: @escaping (Realm) throws -> Void) async throws {
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            try realm.write {
                try block(realm)
            }
        }.value
    }
}

// MARK: - Realm change observer

/// MainActor 에 머무는 알림 토큰 보유자. `observeChanges()` 스트림의 수명 동안 살아 있다.
///
/// Realm·NotificationToken 은 Sendable 이 아니라 한 스레드(여기선 메인)에 가둬야 한다.
/// `continuation` 만 Sendable 이라 콜백에서 안전하게 yield 한다.
@MainActor
private final class RealmChangeObserver {
    private let continuation: AsyncStream<Void>.Continuation
    private var token: NotificationToken?
    private var realm: Realm?

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        do {
            let realm = try RealmStoreFactory.openRealm()
            self.realm = realm
            // `.initial` 은 건너뛴다 — 소비자(화면)가 첫 load 를 따로 하므로 중복 방지.
            // 실제 쓰기(`.update`) 에만 신호를 보낸다.
            token = realm.objects(RealmMochiItem.self).observe { [continuation] change in
                switch change {
                case .update:
                    continuation.yield(())
                case .initial, .error:
                    break
                }
            }
        } catch {
            continuation.finish()
        }
    }

    func stop() {
        token?.invalidate()
        token = nil
        realm = nil
    }
}
