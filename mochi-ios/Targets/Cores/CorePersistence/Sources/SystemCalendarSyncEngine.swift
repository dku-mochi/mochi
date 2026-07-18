import Foundation
import CoreDomain
import CoreIntegrations
import CoreNetworking
import Dependencies

/// 시스템 캘린더(EKEvent)·미리알림(EKReminder) 자동 동기화 엔진 — EK 반영의 **단일 소유자**.
///
/// 로컬 Realm 미러의 **확정(needsReview=false) schedule/todo instance 집합**을 "원하는 상태"로 삼아,
/// EK 링크 스토어와 diff 후 생성/갱신/완료/제거를 멱등 적용한다. 채팅 확정·캘린더 탭 직행·
/// ShareExtension 캡처 분석·재분석·reconcile — **어떤 경로로 Realm 에 쓰이든** `observeChanges` 로
/// EK 가 따라온다(2026-07-14 자동 관리 전환 — call-site 등록 배선이 만들던 drift 제거, UX_SPEC §1.5).
/// silent push(백그라운드 reconcile)와 앱 실행/복귀 백스톱이 같은 `syncNow()` 로 수렴한다.
///
/// 규약:
/// - **엔진은 권한을 절대 묻지 않는다** — 보유 상태만 확인(`hasEventAccess`). 프롬프트는 상호작용
///   문맥(채팅 확정·캘린더 탭 저장)의 몫이고, 미보유면 "링크 없음"이 곧 대기열 — 권한 확보 후
///   다음 동기화가 일괄 따라잡는다(별도 pending 마킹 불필요).
/// - **중복 등록 0**: 링크(instanceID PK) 영속 + actor 단일 비행. EK update 가 "항목 소실"을
///   보고하면 재생성하지 않고 tombstone — EK 식별자는 iCloud 동기화로 재발급될 수 있어(항목은
///   살아있는데 식별자만 바뀜) 소실 보고를 삭제로 단정해 재생성하면 중복이 난다. 사용자가 캘린더
///   앱에서 직접 지운 경우도 tombstone 이 재등록 루프를 막는다(사용자 삭제 존중).
/// - **제목·시각은 단방향**(모찌 → EK), **완료 상태만 양방향**(2026-07-14 실기기 버그 fix):
///   미리알림 앱에서의 사용자 완료 토글을 링크의 `lastSyncedCompleted` 기준 3-way merge 로
///   모찌에 역반영한다 — 단방향 덮어쓰기는 사용자의 미리알림 완료를 매 동기화마다 되돌렸다.
///   양쪽이 동시에 변한 충돌은 모찌가 이긴다(앱이 기록의 정본). EK 쪽 삭제·시각 수정은 여전히
///   되가져오지 않는다(스코프 밖 — 삭제는 tombstone 존중).
/// - best-effort: EK 실패는 기록 자체에 영향을 주지 않고, 다음 동기화가 재시도한다.
public actor SystemCalendarSyncEngine {
    private let repository: any MochiItemRepository
    private let linkStore: any SystemCalendarLinkStoring
    private let syncer: any CalendarSyncing
    private let apiClient: any MochiAPIClient
    private let isEnabled: @Sendable () -> Bool

    private var observeTask: Task<Void, Never>?
    private var running = false
    private var pendingRerun = false

    public init(
        repository: any MochiItemRepository,
        linkStore: any SystemCalendarLinkStoring,
        syncer: any CalendarSyncing,
        apiClient: any MochiAPIClient,
        isEnabled: @escaping @Sendable () -> Bool = { SystemCalendarAutoRegistrationPreference.load() }
    ) {
        self.repository = repository
        self.linkStore = linkStore
        self.syncer = syncer
        self.apiClient = apiClient
        self.isEnabled = isEnabled
    }

    /// Realm 관찰 시작 + 초기 따라잡기 1회. 앱 프로세스에서만 부른다(ShareExtension 은 캡처만).
    public func start() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            await self?.syncNow()
            guard let stream = self?.repository.observeChanges() else { return }
            for await _ in stream {
                // 연속 쓰기(pull·업로드 경합 등)를 1초 코얼레싱 — syncNow 단일 비행이 나머지를 접는다.
                try? await Task.sleep(for: .seconds(1))
                await self?.syncNow()
            }
        }
    }

    /// 전체 따라잡기(멱등). 실행 중 재진입은 접어서 끝난 뒤 한 번 더 돈다(단일 비행).
    public func syncNow() async {
        guard !running else {
            pendingRerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            pendingRerun = false
            await performSync()
        } while pendingRerun
    }

    // MARK: - diff & apply

    private func performSync() async {
        guard isEnabled() else { return }   // off = 신규 등록·갱신·제거 전부 중단(기존 EK 항목 불가침)
        let hasEvent = await syncer.hasEventAccess()
        let hasReminder = await syncer.hasReminderAccess()
        guard hasEvent || hasReminder else { return }

        // 원하는 상태 — 확정(needsReview=false) 항목의 schedule/todo. 스캔 상한은 저장소 전반의
        // 관례(lookupLocalIDs 등)와 동일. pull↔upload 복제 쌍은 instanceID 가 같아 자연 dedup 된다.
        let items = (try? await repository.listRecent(limit: 2000)) ?? []
        var desired: [UUID: (instance: IntentInstance, item: MochiItem)] = [:]
        for item in items {
            guard let analysis = item.analysis, !analysis.needsReview else { continue }
            for instance in analysis.instances
            where instance.intentType == .schedule || instance.intentType == .todo {
                desired[instance.id] = (instance, item)
            }
        }

        // 링크 조회 실패를 "링크 없음"으로 간주하면 전부 중복 생성된다 — 실패 시 이번 동기화 보류(codex P1).
        guard let links = try? await linkStore.allLinks() else { return }
        let linkByID = Dictionary(links.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, pair) in desired {
            if let link = linkByID[id] {
                guard !link.tombstoned else { continue }   // 소실 확인분 — 재등록 금지
                await update(link: link, instance: pair.instance, item: pair.item,
                             hasEvent: hasEvent, hasReminder: hasReminder)
            } else {
                await create(instance: pair.instance, item: pair.item,
                             hasEvent: hasEvent, hasReminder: hasReminder)
            }
        }

        // 기록 삭제·재분석(delete-reinsert)으로 instance 가 저장소에서 **사라졌을 때만** EK 도 거둔다.
        // desired 부재만으론 부족하다 — 스캔 상한(2000) 밖의 오래된 기록이나 미확정(needsReview) 강등을
        // 삭제로 오인해 사용자 캘린더를 지우면 안 되므로(codex P1), 전수 instance id 로 재확인한다.
        // 전수 조회가 실패하면 제거를 전부 보류한다(파괴적 동작은 확신 있을 때만 — 다음 동기화 재시도).
        let allInstanceIDs = try? await repository.allIntentInstanceIDs()
        guard let allInstanceIDs else { return }
        for link in links where desired[link.instanceID] == nil && !allInstanceIDs.contains(link.instanceID) {
            if link.tombstoned {
                // EK 에 이미 없다고 확인된 링크 — 기록도 사라졌으니 묘비 역할이 끝났다.
                try? await linkStore.remove(instanceIDs: [link.instanceID])
                continue
            }
            do {
                switch link.kind {
                case .event:
                    guard hasEvent else { continue }       // 권한 없으면 남겨서 다음 동기화에
                    try await syncer.removeEvent(identifier: link.ekIdentifier)
                case .reminder:
                    guard hasReminder else { continue }
                    try await syncer.removeReminder(identifier: link.ekIdentifier)
                }
                try? await linkStore.remove(instanceIDs: [link.instanceID])
            } catch {
                // save 실패 — 링크를 남겨 다음 동기화가 재시도한다.
            }
        }
    }

    /// 생성은 **선영속 잠금** 2단계다(codex P1): EK 생성과 링크 저장 사이의 크래시/쓰기 실패로
    /// "EK 항목만 있고 링크 없음"이 되면 다음 동기화가 같은 instance 를 중복 생성한다. 그래서
    /// ① 빈 ekIdentifier 잠금 행을 먼저 영속하고(실패하면 생성 자체를 미룸 — 중복 0 > 등록 지연),
    /// ② EK 생성 후 실제 식별자로 되쓴다. ②가 유실돼 빈 잠금이 남으면 update 경로가 소실(false)로
    /// 판정해 tombstone 으로 수렴 — 어느 경로로도 중복은 나지 않는다.
    private func create(instance: IntentInstance, item: MochiItem, hasEvent: Bool, hasReminder: Bool) async {
        let payload = SystemCalendarRegistrar.stringMap(instance.payload)
        if instance.intentType == .schedule {
            guard hasEvent,
                  let (start, allDay) = SystemCalendarRegistrar.scheduleStart(from: payload)
            else { return }   // 날짜 파싱 불가(자연어 등) — EK 로 표현 불가라 건너뜀
            let lock = SystemCalendarLink(instanceID: instance.id, kind: .event, ekIdentifier: "")
            guard (try? await linkStore.save([lock])) != nil else { return }
            guard let ekID = try? await syncer.createEvent(
                title: title(for: instance, item: item, fallback: "모찌 일정"),
                start: start,
                end: SystemCalendarRegistrar.scheduleEnd(from: payload, start: start),
                allDay: allDay
            ) else {
                try? await linkStore.remove(instanceIDs: [instance.id])   // 생성 실패 — 잠금 해제(재시도)
                return
            }
            try? await linkStore.save([
                SystemCalendarLink(instanceID: instance.id, kind: .event, ekIdentifier: ekID)
            ])
        } else {
            guard hasReminder else { return }
            // 이미 완료된 할 일은 새로 세우지 않는다 — 완료 항목을 뒤늦게 미리알림에 만드는 건
            // 클러터일 뿐이다(재설치 reconcile 때 다량 발생). 미완료로 되돌리면 이 게이트를 지나
            // 생성된다. (codex 제기 — 의도된 동작으로 유지)
            guard instance.lifecycle.kind != .archived else { return }
            let lock = SystemCalendarLink(instanceID: instance.id, kind: .reminder, ekIdentifier: "")
            guard (try? await linkStore.save([lock])) != nil else { return }
            guard let ekID = try? await syncer.createReminder(
                title: title(for: instance, item: item, fallback: "모찌 할 일"),
                due: dueDate(of: instance)
            ) else {
                try? await linkStore.remove(instanceIDs: [instance.id])   // 생성 실패 — 잠금 해제(재시도)
                return
            }
            try? await linkStore.save([
                // 생성 직후는 미완료 — 완료 3-way merge 기준점을 함께 영속한다.
                SystemCalendarLink(
                    instanceID: instance.id, kind: .reminder, ekIdentifier: ekID,
                    lastSyncedCompleted: false
                )
            ])
        }
    }

    private func update(link: SystemCalendarLink, instance: IntentInstance, item: MochiItem,
                        hasEvent: Bool, hasReminder: Bool) async {
        // intent 종류가 바뀐 드문 경우(schedule↔todo, 같은 instanceID) — 이전 종류의 EK 항목을 거두고
        // 링크를 지워 다음 동기화가 새 종류로 생성하게 한다(codex P2 — 알려진 경로는 재분석
        // delete-reinsert 라 실제 발생은 드물지만 값싼 방어).
        let expectedKind: SystemCalendarLink.Kind = instance.intentType == .schedule ? .event : .reminder
        guard link.kind == expectedKind else {
            switch link.kind {
            case .event:
                guard hasEvent else { return }
                guard (try? await syncer.removeEvent(identifier: link.ekIdentifier)) != nil else { return }
            case .reminder:
                guard hasReminder else { return }
                guard (try? await syncer.removeReminder(identifier: link.ekIdentifier)) != nil else { return }
            }
            try? await linkStore.remove(instanceIDs: [link.instanceID])
            pendingRerun = true   // 같은 syncNow 안에서 한 바퀴 더 돌아 새 종류로 즉시 재생성(codex P2)
            return
        }
        let payload = SystemCalendarRegistrar.stringMap(instance.payload)
        switch link.kind {
        case .event:
            guard hasEvent,
                  let (start, allDay) = SystemCalendarRegistrar.scheduleStart(from: payload)
            else { return }   // 날짜가 파싱 불가로 바뀜 — EK 는 이전 시각 유지(등록 시 규약과 동일)
            let found = try? await syncer.updateEvent(
                identifier: link.ekIdentifier,
                title: title(for: instance, item: item, fallback: "모찌 일정"),
                start: start,
                end: SystemCalendarRegistrar.scheduleEnd(from: payload, start: start),
                allDay: allDay
            )
            if found == false {
                try? await linkStore.tombstone(instanceIDs: [link.instanceID])
            }
        case .reminder:
            guard hasReminder else { return }
            await updateReminderMergingCompletion(link: link, instance: instance, item: item)
        }
    }

    /// reminder 갱신 — **완료 상태만 3-way merge** (2026-07-14 실기기 버그 fix).
    ///
    /// 이전엔 모찌 상태를 무조건 덮어써서, 미리알림 앱에서 사용자가 완료를 체크해도 다음 동기화가
    /// `completed=false` 로 되돌렸다(치명: 사용자 행동과 싸움). 링크에 영속한 "마지막 합의 상태"
    /// (`lastSyncedCompleted`) 를 기준으로 **어느 쪽이 변했는지** 판별한다:
    /// - EK 쪽만 변함 → 모찌로 역반영(로컬 lifecycle 전이 + 서버 push — 상세·캘린더 토글과 같은
    ///   `TodoLifecycleSync` 공용 경로). push 실패 시 공용 경로가 로컬을 롤백하고 기준점을 안 옮겨
    ///   다음 동기화가 재시도한다.
    /// - 모찌 쪽만 변함/동시 변경 → 모찌가 이긴다(앱이 기록의 정본) — 기존대로 EK 에 민다.
    /// 제목·due 는 여전히 단방향(모찌 → EK)이다.
    ///
    /// 동시성: 이 merge 는 언제나 `performSync` 안에서만 돌고, `syncNow` 의 single-flight(`running`
    /// 가드)가 performSync 인터리브를 차단한다 — 역반영의 로컬 전이가 울린 observeChanges 재진입은
    /// `pendingRerun` 큐로 접혀 **push 성공(기준점 이동)/실패(롤백+기준점 유지)가 끝난 뒤에만** 다음
    /// 사이클이 시작되므로, 중간 상태를 보고 기준점을 잘못 전진시키는 레이스가 없다(codex 재리뷰 검토).
    private func updateReminderMergingCompletion(
        link: SystemCalendarLink, instance: IntentInstance, item: MochiItem
    ) async {
        // 쓰기 전에 EK 현재 완료 상태를 읽는다. 조회 실패(권한 등)는 이번 사이클 보류,
        // 항목 소실(nil)은 event 와 동일하게 tombstone. `try?` 는 Optional 반환(Bool?)을
        // 평탄화해 실패와 소실이 한 nil 로 뭉개지므로 do/catch 로 구분한다.
        let lookup: Bool?
        do {
            lookup = try await syncer.reminderCompleted(identifier: link.ekIdentifier)
        } catch {
            return
        }
        guard let ekCompleted = lookup else {
            try? await linkStore.tombstone(instanceIDs: [link.instanceID])
            return
        }
        let mochiCompleted = instance.lifecycle.kind == .archived
        let lastSynced = link.lastSyncedCompleted ?? false

        if ekCompleted != lastSynced, mochiCompleted == lastSynced {
            // 미리알림 앱에서의 사용자 토글 → 모찌 역반영.
            let target: InstanceLifecycle = ekCompleted ? .archived(reason: .todoCompleted) : .active
            guard (try? await repository.updateInstanceLifecycle(
                mochiItemID: item.id, instanceID: instance.id, to: target
            )) != nil else { return }
            let failure = await TodoLifecycleSync.pushToggle(
                item: item, instance: instance, target: target,
                repository: repository, apiClient: apiClient
            )
            if failure == nil {
                // 수렴 성공 — 기준점 이동. (실패면 공용 경로가 로컬을 롤백했고 기준점 유지 → 재시도.)
                try? await linkStore.setLastSyncedCompleted(instanceID: link.instanceID, completed: ekCompleted)
            }
            // 로컬 전이가 observeChanges 를 울려 다음 사이클에서 제목·due 포함 상태가 재수렴한다.
            return
        }

        // 모찌 정본을 EK 로 민다(완료 무변경이면 unchanged-skip 이 save 를 생략한다).
        let found = try? await syncer.updateReminder(
            identifier: link.ekIdentifier,
            title: title(for: instance, item: item, fallback: "모찌 할 일"),
            due: dueDate(of: instance),
            completed: mochiCompleted
        )
        if found == false {
            try? await linkStore.tombstone(instanceIDs: [link.instanceID])
            return
        }
        if found == true, mochiCompleted != lastSynced {
            try? await linkStore.setLastSyncedCompleted(instanceID: link.instanceID, completed: mochiCompleted)
        }
    }

    /// EK 제목 규칙 — instance 제목 → 사용자 교정 제목 → 항목 원문 → 기본 문구.
    /// (인라인 제목 교정(userTitle)은 instance 가 자체 title 을 갖지 않을 때만 EK 에 반영된다 —
    /// instance title 은 그 일정·할 일의 고유 이름이라 항목 표시 제목이 덮지 않는다.)
    private func title(for instance: IntentInstance, item: MochiItem, fallback: String) -> String {
        if let value = instance.payload.title, !value.isEmpty { return value }
        if let value = item.userTitle, !value.isEmpty { return value }
        if let value = item.source.text, !value.isEmpty { return value }
        return fallback
    }

    /// 캘린더 탭·상세 D-day 와 같은 규칙: `deadline ?? date`.
    private func dueDate(of instance: IntentInstance) -> Date? {
        PayloadDate.parse(instance.payload.deadline ?? instance.payload.date)
    }
}

// MARK: - DI

public enum SystemCalendarSyncEngineKey: DependencyKey {
    /// 안전 기본값(no-op 에 수렴) — 앱은 `AppDependencies.bootstrap` 이 Realm/EventKit 실구현으로 교체.
    public static let liveValue = SystemCalendarSyncEngine(
        repository: InMemoryMochiItemRepository(),
        linkStore: InMemorySystemCalendarLinkStore(),
        syncer: UnconfiguredCalendarSyncer(),
        apiClient: NotConfiguredAPIClient()
    )
    public static let testValue = SystemCalendarSyncEngine(
        repository: InMemoryMochiItemRepository(),
        linkStore: InMemorySystemCalendarLinkStore(),
        syncer: UnconfiguredCalendarSyncer(),
        apiClient: NotConfiguredAPIClient()
    )
}

public extension DependencyValues {
    var systemCalendarSyncEngine: SystemCalendarSyncEngine {
        get { self[SystemCalendarSyncEngineKey.self] }
        set { self[SystemCalendarSyncEngineKey.self] = newValue }
    }
}
