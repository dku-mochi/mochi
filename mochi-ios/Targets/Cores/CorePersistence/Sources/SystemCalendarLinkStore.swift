import Foundation
import RealmSwift
import CoreDomain

/// EK 링크(`SystemCalendarLink`) 영속 스토어 — `SystemCalendarSyncEngine` 이 diff 의 "현재 상태" 축으로
/// 읽고 쓴다(UX_SPEC §1.5 자동 관리).
public protocol SystemCalendarLinkStoring: Sendable {
    func save(_ links: [SystemCalendarLink]) async throws
    /// 묘비(tombstoned) 포함 전체 — 엔진이 재등록 차단 판단까지 하려면 전부 봐야 한다.
    func allLinks() async throws -> [SystemCalendarLink]
    func remove(instanceIDs: [UUID]) async throws
    /// EK 항목이 식별자로 안 잡혔을 때(사용자 직접 삭제·iCloud 식별자 재발급) 재생성을 막는 묘비 표시.
    func tombstone(instanceIDs: [UUID]) async throws
}

/// App Group Realm 파일(`RealmStoreFactory`) 기반 구현 — 앱이 `AppDependencies.bootstrap` 에서
/// 엔진에 주입한다.
public actor RealmSystemCalendarLinkStore: SystemCalendarLinkStoring {
    public init() {
        _ = RealmStoreFactory.makeConfiguration()
    }

    public func save(_ links: [SystemCalendarLink]) async throws {
        guard !links.isEmpty else { return }
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            try realm.write {
                for link in links {
                    let row = RealmSystemCalendarLink()
                    row.instanceID = link.instanceID.uuidString
                    row.kindRawValue = link.kind.rawValue
                    row.ekIdentifier = link.ekIdentifier
                    row.createdAt = Date()
                    row.tombstonedAt = link.tombstoned ? Date() : nil
                    realm.add(row, update: .modified)
                }
            }
        }.value
    }

    public func allLinks() async throws -> [SystemCalendarLink] {
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            return realm.objects(RealmSystemCalendarLink.self)
                .compactMap { row -> SystemCalendarLink? in
                    guard let instanceID = UUID(uuidString: row.instanceID),
                          let kind = SystemCalendarLink.Kind(rawValue: row.kindRawValue)
                    else { return nil }
                    return SystemCalendarLink(
                        instanceID: instanceID,
                        kind: kind,
                        ekIdentifier: row.ekIdentifier,
                        tombstoned: row.tombstonedAt != nil
                    )
                }
        }.value
    }

    public func remove(instanceIDs: [UUID]) async throws {
        guard !instanceIDs.isEmpty else { return }
        let keys = instanceIDs.map(\.uuidString)
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            try realm.write {
                realm.delete(
                    realm.objects(RealmSystemCalendarLink.self).filter("instanceID IN %@", keys)
                )
            }
        }.value
    }

    public func tombstone(instanceIDs: [UUID]) async throws {
        guard !instanceIDs.isEmpty else { return }
        let keys = instanceIDs.map(\.uuidString)
        try await Task.detached {
            let realm = try RealmStoreFactory.openRealm()
            try realm.write {
                for row in realm.objects(RealmSystemCalendarLink.self).filter("instanceID IN %@", keys) {
                    row.tombstonedAt = Date()
                }
            }
        }.value
    }
}

/// 테스트·프리뷰 기본값 — Realm 을 열지 않는다 (`MochiItemRepositoryKey` liveValue=InMemory 관례와 동일).
public actor InMemorySystemCalendarLinkStore: SystemCalendarLinkStoring {
    private var storage: [UUID: SystemCalendarLink] = [:]
    public init() {}
    public func save(_ links: [SystemCalendarLink]) async throws {
        for link in links { storage[link.instanceID] = link }
    }
    public func allLinks() async throws -> [SystemCalendarLink] {
        Array(storage.values)
    }
    public func remove(instanceIDs: [UUID]) async throws {
        for id in instanceIDs { storage[id] = nil }
    }
    public func tombstone(instanceIDs: [UUID]) async throws {
        for id in instanceIDs {
            guard let link = storage[id] else { continue }
            storage[id] = SystemCalendarLink(
                instanceID: link.instanceID, kind: link.kind,
                ekIdentifier: link.ekIdentifier, tombstoned: true
            )
        }
    }
}
