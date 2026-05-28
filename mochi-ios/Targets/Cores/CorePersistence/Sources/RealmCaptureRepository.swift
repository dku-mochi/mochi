import Foundation
import RealmSwift
import CoreDomain

/// Realm 기반 `CaptureRepository` 구현. App·ShareExtension 이 동일 App Group Realm 파일을 공유한다.
/// (AppIntents 는 메인 App 타겟 안에 있어 App 의 Realm 접근을 그대로 쓴다.)
///
/// 모든 read/write는 `realm.writeAsync` 를 통해 Realm thread 안에서 수행하고,
/// 도메인 객체와 Realm 객체 사이는 ``RealmCaptureMapper`` 가 책임진다.
public actor RealmCaptureRepository: CaptureRepository {
    public init() {
        _ = RealmStoreFactory.makeConfiguration()
    }

    public func enqueueIngestedFromExtension(_ source: CaptureSource) async throws {
        try await upsert(Capture(source: source))
    }

    public func upsert(_ capture: Capture) async throws {
        try await write { realm in
            let row = RealmCaptureMapper.toRealm(capture)
            realm.add(row, update: .modified)
        }
    }

    public func updateLifecycle(captureID: UUID, to newState: LifecycleState) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmCapture.self, forPrimaryKey: captureID.uuidString) else {
                throw DomainError.notFound(entity: "Capture", id: captureID.uuidString)
            }
            if let intentRaw = row.intentRawValue, let intent = Intent(rawValue: intentRaw) {
                let currentState = RealmCaptureMapper.lifecycleState(from: row)
                if case .failure(let error) = LifecyclePolicy.validate(from: currentState, to: newState, intent: intent) {
                    throw DomainError.lifecycleTransition(error)
                }
            }
            RealmCaptureMapper.apply(lifecycleState: newState, to: row)
            row.updatedAt = .init()
        }
    }

    public func updateSync(captureID: UUID, to newState: SyncState) async throws {
        try await write { realm in
            guard let row = realm.object(ofType: RealmCapture.self, forPrimaryKey: captureID.uuidString) else {
                throw DomainError.notFound(entity: "Capture", id: captureID.uuidString)
            }
            // SyncState 직렬화는 간단한 string + JSON detail 로 (Realm 친화).
            row.syncStateRawValue = RealmCaptureMapper.syncStateRaw(newState)
            row.updatedAt = .init()
        }
    }

    public func find(id: UUID) async throws -> Capture? {
        try await read { realm in
            realm.object(ofType: RealmCapture.self, forPrimaryKey: id.uuidString).map(RealmCaptureMapper.toDomain(_:))
        }
    }

    public func listRecent(limit: Int) async throws -> [Capture] {
        try await read { realm in
            realm.objects(RealmCapture.self).sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit).map(RealmCaptureMapper.toDomain(_:))
        }
    }

    public func listByIntent(_ intent: Intent, limit: Int) async throws -> [Capture] {
        try await read { realm in
            realm.objects(RealmCapture.self)
                .filter("intentRawValue == %@", intent.rawValue)
                .sorted(byKeyPath: "createdAt", ascending: false)
                .prefix(limit)
                .map(RealmCaptureMapper.toDomain(_:))
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
