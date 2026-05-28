import Foundation
import CoreDomain

/// 도메인 레이어가 의존하는 캡처 저장소 추상 인터페이스 (Hexagonal Architecture의 outbound port).
///
/// 구현체는 Realm·SQLite·In-memory(테스트용) 어떤 것이든 가능하다.
/// Features는 이 프로토콜만 보고, 구체 구현은 App 셸이 DI로 주입한다.
public protocol CaptureRepository: Sendable {
    func enqueueIngestedFromExtension(_ source: CaptureSource) async throws
    func upsert(_ capture: Capture) async throws
    func updateLifecycle(captureID: UUID, to newState: LifecycleState) async throws
    func updateSync(captureID: UUID, to newState: SyncState) async throws
    func find(id: UUID) async throws -> Capture?
    func listRecent(limit: Int) async throws -> [Capture]
    func listByIntent(_ intent: Intent, limit: Int) async throws -> [Capture]
    func deleteAll() async throws
}

/// 테스트·미구현 단계에서 사용할 in-memory 구현. 메인 앱은 Realm 기반 구현체로 교체한다.
public actor InMemoryCaptureRepository: CaptureRepository {
    private var storage: [UUID: Capture] = [:]
    public init() {}

    public func enqueueIngestedFromExtension(_ source: CaptureSource) async throws {
        try await upsert(Capture(source: source))
    }

    public func upsert(_ capture: Capture) async throws {
        var c = capture
        c.updatedAt = .init()
        storage[c.id] = c
    }

    public func updateLifecycle(captureID: UUID, to newState: LifecycleState) async throws {
        guard var capture = storage[captureID] else {
            throw DomainError.notFound(entity: "Capture", id: captureID.uuidString)
        }
        if let intent = capture.intent {
            if case .failure(let err) = LifecyclePolicy.validate(from: capture.lifecycleState, to: newState, intent: intent) {
                throw DomainError.lifecycleTransition(err)
            }
        }
        capture.lifecycleState = newState
        capture.updatedAt = .init()
        storage[captureID] = capture
    }

    public func updateSync(captureID: UUID, to newState: SyncState) async throws {
        guard var capture = storage[captureID] else {
            throw DomainError.notFound(entity: "Capture", id: captureID.uuidString)
        }
        capture.syncState = newState
        capture.updatedAt = .init()
        storage[captureID] = capture
    }

    public func find(id: UUID) async throws -> Capture? { storage[id] }

    public func listRecent(limit: Int) async throws -> [Capture] {
        Array(storage.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func listByIntent(_ intent: Intent, limit: Int) async throws -> [Capture] {
        Array(storage.values.filter { $0.intent == intent }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func deleteAll() async throws { storage.removeAll() }
}
