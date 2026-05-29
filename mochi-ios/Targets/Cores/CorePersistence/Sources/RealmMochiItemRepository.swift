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

    public func deleteAll() async throws {
        try await write { realm in
            realm.deleteAll()
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
