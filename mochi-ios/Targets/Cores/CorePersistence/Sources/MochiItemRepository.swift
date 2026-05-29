import Foundation
import CoreDomain

/// 도메인 레이어가 의존하는 캡처 저장소 추상 인터페이스 (Hexagonal Architecture의 outbound port).
///
/// 구현체는 Realm·SQLite·In-memory(테스트용) 어떤 것이든 가능하다.
/// Features는 이 프로토콜만 보고, 구체 구현은 App 셸이 DI로 주입한다.
public protocol MochiItemRepository: Sendable {
    func enqueueIngestedFromExtension(_ source: IngestSource) async throws
    func upsert(_ mochiItem: MochiItem) async throws
    func updateLifecycle(mochiItemID: UUID, to newState: LifecycleState) async throws
    func updateSync(mochiItemID: UUID, to newState: SyncState) async throws
    func find(id: UUID) async throws -> MochiItem?
    func listRecent(limit: Int) async throws -> [MochiItem]
    func listByIntent(_ intent: Intent, limit: Int) async throws -> [MochiItem]
    func deleteAll() async throws
}

/// 테스트·미구현 단계에서 사용할 in-memory 구현. 메인 앱은 Realm 기반 구현체로 교체한다.
public actor InMemoryMochiItemRepository: MochiItemRepository {
    private var storage: [UUID: MochiItem] = [:]
    public init() {}

    public func enqueueIngestedFromExtension(_ source: IngestSource) async throws {
        try await upsert(MochiItem(source: source))
    }

    public func upsert(_ mochiItem: MochiItem) async throws {
        var c = mochiItem
        c.updatedAt = .init()
        storage[c.id] = c
    }

    public func updateLifecycle(mochiItemID: UUID, to newState: LifecycleState) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        if let intent = mochiItem.intent {
            if case .failure(let err) = LifecyclePolicy.validate(from: mochiItem.lifecycleState, to: newState, intent: intent) {
                throw DomainError.lifecycleTransition(err)
            }
        }
        mochiItem.lifecycleState = newState
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
    }

    public func updateSync(mochiItemID: UUID, to newState: SyncState) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        mochiItem.syncState = newState
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
    }

    public func find(id: UUID) async throws -> MochiItem? { storage[id] }

    public func listRecent(limit: Int) async throws -> [MochiItem] {
        Array(storage.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func listByIntent(_ intent: Intent, limit: Int) async throws -> [MochiItem] {
        Array(storage.values.filter { $0.intent == intent }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func deleteAll() async throws { storage.removeAll() }
}
