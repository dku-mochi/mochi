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

    public func updateInstanceLifecycle(mochiItemID: UUID, instanceID: UUID, to newState: InstanceLifecycle) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            guard let instRow = row.intentInstances.first(where: { $0.instanceID == instanceID.uuidString }),
                  let intent = Intent(rawValue: instRow.intentRawValue),
                  let currentState = RealmMochiItemMapper.instanceLifecycle(from: instRow) else {
                throw DomainError.notFound(entity: "IntentInstance", id: instanceID.uuidString)
            }
            if case .failure(let error) = LifecyclePolicy.validate(from: currentState, to: newState, intent: intent) {
                throw DomainError.lifecycleTransition(error)
            }
            RealmMochiItemMapper.apply(instanceLifecycle: newState, to: instRow)
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

    public func updateCategories(_ categories: [UUID: String]) async throws {
        guard !categories.isEmpty else { return }
        try await write { realm in
            for (id, category) in categories {
                guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: id.uuidString) else { continue }
                row.category = category
                row.updatedAt = .init()
            }
        }
    }

    public func updateImageUploadMetadata(
        mochiItemID: UUID,
        imageRefID: UUID,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        objectKey: String
    ) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            guard let imageRef = row.imageRefs.first(where: { $0.id == imageRefID.uuidString }) else {
                throw DomainError.notFound(entity: "ImageRef", id: imageRefID.uuidString)
            }
            imageRef.mimeType = mimeType
            imageRef.byteSize = byteSize
            imageRef.sha256 = sha256
            imageRef.objectKey = objectKey
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
                .filter("SUBQUERY(intentInstances, $i, $i.intentRawValue == %@).@count > 0", intent.rawValue)
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listAnalyzing(limit: Int) async throws -> [MochiItem] {
        // "모찌가 분석 중이에요" — 분석 응답 미수신(analyzedAt == nil). failed 는 제외.
        // (처리상태엔 archived 가 없다 — 의미상태로 이동.)
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "analyzedAt == nil AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'failed')"
                )
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listNeedsReview(limit: Int) async throws -> [MochiItem] {
        // "모찌가 헷갈려요" — 분석은 끝났으나 모찌가 확신 못 함 (needsReview boolean 직접). failed 제외.
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "needsReview == true AND " +
                    "NOT (lifecycleStateRawValue BEGINSWITH 'failed')"
                )
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listByImportance(limit: Int) async throws -> [MochiItem] {
        // 분석 완료(analyzedAt != nil) + importance 높은 항목. failed 제외
        // (처리상태 'failed:<reason>' 형태라 BEGINSWITH prefix 매칭).
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "analyzedAt != nil AND importance >= 3 AND " +
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

    public func listCaptured(in interval: DateInterval, limit: Int) async throws -> [MochiItem] {
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter("capturedAt >= %@ AND capturedAt < %@", interval.start, interval.end)
                .sorted(byKeyPath: "capturedAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func listActiveTodos(limit: Int) async throws -> [MochiItem] {
        // 미완료 todo = todo instance 가 active 인 item (완료는 instance archived:todoCompleted).
        try await read { realm in
            realm.objects(RealmMochiItem.self)
                .filter(
                    "SUBQUERY(intentInstances, $i, $i.intentRawValue == %@ AND $i.lifecycleKindRawValue == 'active').@count > 0",
                    Intent.todo.rawValue
                )
                .sorted(byKeyPath: "capturedAt", ascending: false)
                .prefix(limit)
                .map(RealmMochiItemMapper.toDomain(_:))
        }
    }

    public func setIntent(mochiItemID: UUID, intent: Intent) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            // 고른 intent 의 instance 하나로 확정 + needsReview 끄기 → "헷갈려요" 에서 빠진다.
            row.intentInstances.removeAll()
            let instRow = RealmIntentInstance()
            instRow.instanceID = UUID().uuidString
            instRow.intentRawValue = intent.rawValue
            instRow.reasoning = "manual"
            instRow.lifecycleKindRawValue = "active"
            row.intentInstances.append(instRow)
            row.reviewOptions.removeAll()
            row.needsReview = false
            row.modelVersion = "manual"
            if row.analyzedAt == nil { row.analyzedAt = Date() }
            row.updatedAt = .init()
        }
    }

    public func setUserTitle(mochiItemID: UUID, title: String?) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            row.userTitle = title
            row.updatedAt = .init()
        }
    }

    public func setFavorite(mochiItemID: UUID, isFavorite: Bool) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            row.isFavorite = isFavorite
            row.updatedAt = .init()
        }
    }

    public func requeueForAnalysis(mochiItemID: UUID) async throws {
        // serverID 보존을 위해 먼저 도메인 객체로 읽어 syncState 를 확인.
        guard let item = try await find(id: mochiItemID),
              case let .uploaded(serverID, _) = item.syncState else { return }
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: mochiItemID.uuidString) else {
                throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
            }
            // analysis 제거 → listAnalyzing 대상으로 복귀.
            row.summary = nil
            row.category = nil
            row.needsReview = false
            row.modelVersion = nil
            row.analyzedAt = nil
            row.intentInstances.removeAll()
            row.reviewOptions.removeAll()
            row.lifecycleStateRawValue = RealmMochiItemMapper.lifecycleStateRaw(.ingested)
            // 폴링 deadline 재시작 — serverID 유지하고 uploaded 타임스탬프만 now 로.
            row.syncStateRawValue = RealmMochiItemMapper.syncStateRaw(.uploaded(serverID: serverID, at: Date()))
            row.updatedAt = .init()
        }
    }

    public func deleteAll() async throws {
        try await write { realm in
            realm.deleteAll()
        }
    }

    public func delete(id: UUID) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmMochiItem.self, forPrimaryKey: id.uuidString) else {
                return  // 이미 없으면 no-op (서버 삭제 후 로컬 정리 재시도 안전)
            }
            realm.delete(row)
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

    private func read<T: Sendable>(_ block: @escaping @Sendable (Realm) throws -> T) async throws -> T {
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            return try block(realm)
        }.value
    }

    private func write(_ block: @escaping @Sendable (Realm) throws -> Void) async throws {
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
