import Foundation
import CoreDomain

/// 도메인 레이어가 의존하는 캡처 저장소 추상 인터페이스 (Hexagonal Architecture의 outbound port).
///
/// 구현체는 Realm·SQLite·In-memory(테스트용) 어떤 것이든 가능하다.
/// Features는 이 프로토콜만 보고, 구체 구현은 App 셸이 DI로 주입한다.
public protocol MochiItemRepository: Sendable {
    func enqueueIngestedFromExtension(_ source: IngestSource) async throws
    func upsert(_ mochiItem: MochiItem) async throws
    /// 특정 intent instance 의 의미상태 전이 (예: archive). `LifecyclePolicy` 가 intent_type 별로 검증한다.
    func updateInstanceLifecycle(mochiItemID: UUID, instanceID: UUID, to newState: InstanceLifecycle) async throws
    func updateSync(mochiItemID: UUID, to newState: SyncState) async throws
    func updateImageUploadMetadata(
        mochiItemID: UUID,
        imageRefID: UUID,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        objectKey: String
    ) async throws
    func find(id: UUID) async throws -> MochiItem?
    func listRecent(limit: Int) async throws -> [MochiItem]
    func listByIntent(_ intent: Intent, limit: Int) async throws -> [MochiItem]
    /// 분석 응답을 아직 못 받은 (analysis 미수신) 항목. 홈 "모찌가 분석 중이에요" 섹션의 원본.
    func listAnalyzing(limit: Int) async throws -> [MochiItem]
    /// 분석은 끝났으나 모찌가 확신하지 못하는 (`needsReview == true`) 항목.
    /// 홈 "모찌가 헷갈려요" 카드의 원본.
    func listNeedsReview(limit: Int) async throws -> [MochiItem]
    /// `analysis.importance` 가 높은 순으로 active 항목 정렬.
    /// 홈 "중요해 보여요" 섹션의 원본. 일일 캐시는 호출자가 결정.
    func listByImportance(limit: Int) async throws -> [MochiItem]
    /// 특정 기간(`interval`) 안에 `capturedAt` 된 항목 — 모찌들(캘린더) 탭의 월간 집계·날짜별 목록 원본.
    /// `capturedAt` 내림차순.
    func listCaptured(in interval: DateInterval, limit: Int) async throws -> [MochiItem]
    /// 미완료 todo — `todo` intent instance 가 `active` 인 item. 모찌들 탭 하단 "마감 임박 할 일" 리스트 원본.
    /// 마감일 파싱·정렬은 호출자(reducer)가 `analysis.actionCandidates` 에서 도출한다. `capturedAt` 내림차순.
    func listActiveTodos(limit: Int) async throws -> [MochiItem]
    /// 사용자가 needs-review 카드에서 분류 버튼을 누른 경우 호출 — 고른 intent 의 instance 하나로 확정하고
    /// `needsReview` 를 끈다. `analysis` 가 없으면 manual entry 로 생성한다.
    func setIntent(mochiItemID: UUID, intent: Intent) async throws
    /// 사용자가 기록상세에서 제목을 직접 교정 — 로컬 오버라이드(`MochiItem.userTitle`)를 저장한다.
    /// `title == nil`이면 오버라이드 해제 → AI 추출 제목으로 복귀. (빈 문자열→nil 변환은 호출자 책임.)
    func setUserTitle(mochiItemID: UUID, title: String?) async throws
    /// "모찌에게 다시 맡기기" — 분석 실패/강등된 항목을 다시 "분석 중"으로 되돌린다.
    /// analysis 를 비우고(→ `listAnalyzing` 대상), 업로드 타임스탬프를 갱신해 폴링 deadline 을 재시작한다.
    /// 이미 업로드된(`.uploaded`) 항목만 대상 — serverID 가 있어야 재폴링이 가능하기 때문.
    func requeueForAnalysis(mochiItemID: UUID) async throws
    func deleteAll() async throws
    /// 저장소에 쓰기가 발생할 때마다 `Void` 를 방출하는 스트림.
    /// Realm 구현은 같은 프로세스뿐 아니라 ShareExtension 등 **다른 프로세스의 쓰기까지** 감지한다
    /// (Realm 파일 단위 cross-process 알림). 화면이 polling 없이 즉시 최신 데이터를 다시 읽도록 하는 신호.
    /// 스트림 소비를 중단(취소)하면 관찰이 해제된다.
    func observeChanges() -> AsyncStream<Void>
}

/// 테스트·미구현 단계에서 사용할 in-memory 구현. 메인 앱은 Realm 기반 구현체로 교체한다.
public actor InMemoryMochiItemRepository: MochiItemRepository {
    private var storage: [UUID: MochiItem] = [:]
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    public init() {}

    public nonisolated func observeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(id: UUID, continuation: AsyncStream<Void>.Continuation) {
        continuations[id] = continuation
    }

    private func unregister(id: UUID) {
        continuations[id] = nil
    }

    private func notifyChange() {
        for continuation in continuations.values { continuation.yield(()) }
    }

    public func enqueueIngestedFromExtension(_ source: IngestSource) async throws {
        try await upsert(MochiItem(source: source))
    }

    public func upsert(_ mochiItem: MochiItem) async throws {
        var c = mochiItem
        c.updatedAt = .init()
        storage[c.id] = c
        notifyChange()
    }

    public func updateInstanceLifecycle(mochiItemID: UUID, instanceID: UUID, to newState: InstanceLifecycle) async throws {
        guard var mochiItem = storage[mochiItemID], let analysis = mochiItem.analysis,
              let idx = analysis.instances.firstIndex(where: { $0.id == instanceID }) else {
            throw DomainError.notFound(entity: "IntentInstance", id: instanceID.uuidString)
        }
        var instance = analysis.instances[idx]
        if case .failure(let err) = LifecyclePolicy.validate(from: instance.lifecycle, to: newState, intent: instance.intentType) {
            throw DomainError.lifecycleTransition(err)
        }
        instance.lifecycle = newState
        var instances = analysis.instances
        instances[idx] = instance
        mochiItem.analysis = analysis.replacingInstances(instances)
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
        notifyChange()
    }

    public func updateSync(mochiItemID: UUID, to newState: SyncState) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        mochiItem.syncState = newState
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
        notifyChange()
    }

    public func updateImageUploadMetadata(
        mochiItemID: UUID,
        imageRefID: UUID,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        objectKey: String
    ) async throws {
        guard let mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        let refs = mochiItem.source.imageRefs.map { ref in
            ref.id == imageRefID
                ? ImageRef(
                    id: ref.id,
                    relativePath: ref.relativePath,
                    mimeType: mimeType,
                    byteSize: byteSize,
                    sha256: sha256,
                    objectKey: objectKey
                )
                : ref
        }
        let source = IngestSource(
            id: mochiItem.source.id,
            channel: mochiItem.source.channel,
            url: mochiItem.source.url,
            text: mochiItem.source.text,
            imageRefs: refs,
            userMemo: mochiItem.source.userMemo,
            capturedAt: mochiItem.source.capturedAt
        )
        var updated = MochiItem(
            source: source,
            analysis: mochiItem.analysis,
            lifecycleState: mochiItem.lifecycleState,
            syncState: mochiItem.syncState,
            userTitle: mochiItem.userTitle,
            createdAt: mochiItem.createdAt,
            updatedAt: Date()
        )
        updated.updatedAt = Date()
        storage[mochiItemID] = updated
        notifyChange()
    }

    public func find(id: UUID) async throws -> MochiItem? { storage[id] }

    public func listRecent(limit: Int) async throws -> [MochiItem] {
        Array(storage.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func listByIntent(_ intent: Intent, limit: Int) async throws -> [MochiItem] {
        Array(storage.values.filter { $0.intentTypes.contains(intent) }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func listAnalyzing(limit: Int) async throws -> [MochiItem] {
        Array(
            storage.values
                .filter { mochiItem in
                    guard mochiItem.analysis == nil else { return false }
                    if case .failed = mochiItem.lifecycleState { return false }
                    return true
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    public func listNeedsReview(limit: Int) async throws -> [MochiItem] {
        Array(
            storage.values
                .filter { mochiItem in
                    guard let analysis = mochiItem.analysis, analysis.needsReview else { return false }
                    if case .failed = mochiItem.lifecycleState { return false }
                    return true
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    public func listByImportance(limit: Int) async throws -> [MochiItem] {
        Array(
            storage.values
                .filter { mochiItem in
                    guard let analysis = mochiItem.analysis else { return false }
                    if case .failed = mochiItem.lifecycleState { return false }
                    return analysis.importance >= .medium
                }
                .sorted { lhs, rhs in
                    let li = lhs.analysis?.importance.rawValue ?? 0
                    let ri = rhs.analysis?.importance.rawValue ?? 0
                    if li != ri { return li > ri }
                    return lhs.createdAt > rhs.createdAt
                }
                .prefix(limit)
        )
    }

    public func listCaptured(in interval: DateInterval, limit: Int) async throws -> [MochiItem] {
        Array(
            storage.values
                .filter { interval.start <= $0.source.capturedAt && $0.source.capturedAt < interval.end }
                .sorted { $0.source.capturedAt > $1.source.capturedAt }
                .prefix(limit)
        )
    }

    public func listActiveTodos(limit: Int) async throws -> [MochiItem] {
        Array(
            storage.values
                .filter { item in
                    item.instances.contains { $0.intentType == .todo && $0.lifecycle == .active }
                }
                .sorted { $0.source.capturedAt > $1.source.capturedAt }
                .prefix(limit)
        )
    }

    public func setIntent(mochiItemID: UUID, intent: Intent) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        let now = Date()
        // 수동 확정 — 고른 intent 의 instance 하나로 확정하고 needsReview 를 끈다.
        let instance = IntentInstance(intentType: intent, label: nil, reasoning: "manual")
        if let existing = mochiItem.analysis {
            mochiItem.analysis = MochiItemAnalysis(
                summary: existing.summary,
                instances: [instance],
                needsReview: false,
                reviewOptions: [],
                entities: existing.entities,
                actionCandidates: existing.actionCandidates,
                tags: existing.tags,
                importance: existing.importance,
                modelVersion: "manual",
                analyzedAt: existing.analyzedAt
            )
        } else {
            mochiItem.analysis = MochiItemAnalysis(
                summary: mochiItem.source.text ?? "",
                instances: [instance],
                needsReview: false,
                reviewOptions: [],
                entities: [],
                actionCandidates: [],
                tags: [],
                importance: .medium,
                modelVersion: "manual",
                analyzedAt: now
            )
        }
        mochiItem.updatedAt = now
        storage[mochiItemID] = mochiItem
        notifyChange()
    }

    public func setUserTitle(mochiItemID: UUID, title: String?) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        mochiItem.userTitle = title
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
        notifyChange()
    }

    public func requeueForAnalysis(mochiItemID: UUID) async throws {
        guard var mochiItem = storage[mochiItemID] else {
            throw DomainError.notFound(entity: "MochiItem", id: mochiItemID.uuidString)
        }
        guard case let .uploaded(serverID, _) = mochiItem.syncState else { return }
        mochiItem.analysis = nil
        mochiItem.lifecycleState = .ingested
        mochiItem.syncState = .uploaded(serverID: serverID, at: Date()) // deadline 재시작
        mochiItem.updatedAt = .init()
        storage[mochiItemID] = mochiItem
        notifyChange()
    }

    public func deleteAll() async throws {
        storage.removeAll()
        notifyChange()
    }
}
