import Foundation
import CryptoKit
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking
import DesignSystem

/// 새 홈 reducer — "사용자는 찾으러 들어오지만, 모찌가 잊은 기억을 떠올려줘 '아, 맞다!' 하게 한다".
///
/// 기존 `HomeFeature`("자동성의 예외 처리 인박스")와 달리, 이 홈의 무게중심은 **능동 회수**다
/// (PRODUCT.md §1.5 — 회수의 주체는 모찌). 화면 위계: 회수 히어로(상단을 가득 채운 심장) →
/// 월간 리포트(이번 달 카테고리 분포) → 최근·확인(안전망). 검색은 홈에서 비우고 상단 아이콘으로
/// 검색 탭에 양보한다(탭별 역할 분리 — 큐레이션·회수가 홈의 일, 탐색은 검색 탭의 일).
/// reducer 는 데이터 조립과 라우팅만 책임지고, 회수 히어로의 3D 인터랙션은 전부 뷰(`RecallHeroView`)의 로컬 상태다.
@Reducer
public struct MochiHomeFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        /// 능동 회수 — 홈의 심장. 모찌가 떠올린 "다시 보면 좋을 기억". cold-start 빈손은 정상.
        public var recall: [RecallFeedEntryDTO] = []
        /// 회수 itemID → 원본 캡처 이미지 ref. 이미지가 회상의 핵심이라(이미지 보고 "아, 맞다"),
        /// 회수 DTO엔 없는 이미지를 server PK 로 로컬 기록을 역매핑해 채운다. 없으면(메모·URL·지식) 폴백.
        public var recallImages: [UUID: ImageRef] = [:]
        /// "이런 걸 모아두셨어요" — **이번 달** 카테고리별 분포(월간 리포트 막대·범례). 전체가 아니라
        /// 월간으로 묶어 최신성을 반영한다. 범례 탭 → 그 서랍을 3D 턴테이블로.
        public var monthlyCategories: [CategoryBucket] = []
        /// 이번 달 저장한 총 기억 수(월간 리포트 헤드라인 "기억 N개를 저장했어요").
        public var monthlyRecordCount: Int = 0
        /// 최근에 보낸 것들 — 정리 대상 아닌 안전망(원본 확인·되돌리기).
        public var recent: IdentifiedArrayOf<MochiItem> = []
        /// 모찌가 확신 못 한 것("지금 확인해 주세요"). 있을 때만 배너로 노출.
        public var needsReview: IdentifiedArrayOf<MochiItem> = []
        public var quickMemoText: String = ""
        public var isComposingMemo: Bool = false
        public var isNeedsReviewPresented: Bool = false
        public var needsReviewPage: Int = 0
        public var isLoading: Bool = false
        public var isSaving: Bool = false
        public var lastError: String?
        @Presents public var deleteAlert: AlertState<Action.Alert>?

        public init() {}
    }

    public enum Action: Sendable, BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case sectionsLoaded(
            recent: [MochiItem],
            needsReview: [MochiItem],
            monthlyItems: [MochiItem]
        )
        case recallLoaded([RecallFeedEntryDTO])
        case recallImagesLoaded([UUID: ImageRef])
        case loadFailed(String)
        /// 상단 검색 아이콘 탭 → 검색 탭으로 전환(홈은 검색을 비우고 탐색을 검색 탭에 양보).
        case searchTapped
        /// 상단 알림(bell) 아이콘 탭 → 알림 페이지(예정/지난 2탭) push. 상위(MainTab)가 처리.
        case notificationsTapped
        /// 회수 히어로 "모두 보기" → ② 자세히 목록 push.
        case recallSeeAllTapped
        /// 회수 히어로 초점 카드 탭 → 그 기록 원본 상세로 hero zoom. 카드 frame(`hero`)을 함께 싣는다.
        case recallEntryOpened(RecallFeedEntryDTO, hero: HeroSourceFrames)
        /// 상세가 닫힌 뒤(MainTab 발) — 닫힌 그 회수 카드(itemID)만 피드에서 우아하게 제거한다(돌아왔다 사라진다).
        case recallDetailClosed(itemID: UUID)
        /// 카테고리 카드 탭 → 3D 턴테이블 push.
        case categoryTapped(CategoryBucket)
        /// 최근 카드 탭 → 상세(hero zoom). 상위(MainTab)가 처리.
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames)
        case deleteMochiItemTapped(MochiItem.ID)
        case deleteAlert(PresentationAction<Alert>)
        case needsReviewTapped
        case dismissNeedsReview
        case reanalyzeTapped(mochiItemID: MochiItem.ID, hint: String)
        case retryAnalysisTapped(MochiItem.ID)
        case quickMemoSubmitted
        case quickMemoSaved
        case imagePicked(data: Data, memo: String)
        case monthlyDigestTapped
        case favoritesTapped
        case openSettingsTapped
        case replayOnboardingTapped
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete(MochiItem.ID)
        }
        public enum Delegate: Equatable, Sendable {
            /// 상단 검색 아이콘 — 상위가 검색 탭으로 전환한다(query 없이, 탐색은 검색 탭의 역할).
            case searchTabRequested
            /// 상단 알림 아이콘 — 상위가 알림 페이지(예정/지난 2탭)를 push 한다.
            case notificationsPageRequested
            /// 회수 "모두 보기" — 상위가 ② 자세히 목록을 push 한다(이미 받아둔 피드를 넘겨 즉시 그림).
            case recallListRequested([RecallFeedEntryDTO])
            /// 회수 히어로 카드 탭 — 상위가 그 기록의 원본 상세를 hero zoom 으로 연다("왜 떴는지"는 노출 안 함).
            case recallItemOpened(itemID: UUID, hero: HeroSourceFrames)
            /// 카테고리 카드 탭 — 상위가 그 서랍을 3D 턴테이블로 push 한다.
            case categoryCarouselRequested(CategoryBucket)
            case monthlyDigestRequested
            case favoritesRequested
            case onboardingRequested
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    private enum CancelID { case observe, recallFeed }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                state.isLoading = true
                return .merge(
                    .run { send in await loadAll(send: send) },
                    // 회수 피드는 별도 effect — 실패해도 홈 본문 로드를 막지 않는다(실패 격리).
                    .run { send in await send(.recallLoaded((try? await apiClient.recallFeed(limit: 20)) ?? [])) }
                        .cancellable(id: CancelID.recallFeed, cancelInFlight: true),
                    // 로컬이 비어있으면(재설치 직후 등) 서버에서 복구 — pull 결과는 observeChanges 가 자동 재로드.
                    .run { _ in
                        if (try? await repository.listRecent(limit: 1))?.isEmpty ?? true {
                            await syncTrigger.pullRemote()
                        }
                    },
                    .run { send in
                        for await _ in repository.observeChanges() {
                            await loadAll(send: send)
                        }
                    }
                    .cancellable(id: CancelID.observe, cancelInFlight: true)
                )

            case .refresh:
                state.isLoading = true
                return .merge(
                    .run { send in await loadAll(send: send) },
                    .run { send in await send(.recallLoaded((try? await apiClient.recallFeed(limit: 20)) ?? [])) }
                        .cancellable(id: CancelID.recallFeed, cancelInFlight: true)
                )

            case let .sectionsLoaded(recent, needsReview, monthlyItems):
                state.isLoading = false
                state.recent = IdentifiedArray(uniqueElements: recent)
                state.needsReview = IdentifiedArray(uniqueElements: needsReview)
                state.monthlyRecordCount = monthlyItems.count
                state.monthlyCategories = Self.categoryBuckets(from: monthlyItems)
                if state.needsReviewPage >= needsReview.count {
                    state.needsReviewPage = max(0, needsReview.count - 1)
                }
                if needsReview.isEmpty {
                    state.isNeedsReviewPresented = false
                }
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.isSaving = false
                state.lastError = message
                return .none

            case let .recallLoaded(entries):
                state.recall = entries
                // 회수의 원본 캡처 이미지를 역매핑해 히어로 커버로 — 이미지를 보고 "아, 맞다" 하는 회상이
                // 가장 강하다. itemID 는 server PK. 이미지 없는 회수(메모·URL·지식)는 맵에 안 담겨 폴백.
                return .run { send in
                    var map: [UUID: ImageRef] = [:]
                    for entry in entries {
                        if let item = try? await repository.find(serverID: entry.itemID),
                           let ref = item.source.imageRefs.first {
                            map[entry.itemID] = ref
                        }
                    }
                    await send(.recallImagesLoaded(map))
                }

            case let .recallImagesLoaded(map):
                state.recallImages = map
                return .none

            case .searchTapped:
                return .send(.delegate(.searchTabRequested))

            case .notificationsTapped:
                return .send(.delegate(.notificationsPageRequested))

            case .recallSeeAllTapped:
                guard !state.recall.isEmpty else { return .none }
                return .send(.delegate(.recallListRequested(state.recall)))

            case let .recallEntryOpened(entry, hero):
                // 열어본 회수는 피드에서 빠지지만(제품 규칙), 즉시가 아니라 상세를 닫고 돌아온 뒤
                // (recallDetailClosed) 빠진다 — hero zoom 으로 카드 자리에 착지한 다음 우아하게 사라지게.
                // opened 반응은 지금 보고한다(학습·소생, recallEventID 있을 때). 이 보고가 없으면 서버는
                // "안 열렸다"고 알아 다음 피드에도 그대로 남는다. 원본 상세로 hero 직행. 어떤 카드를 닫을지는
                // 상위(MainTab)가 server PK 로 추적한다 — 닫을 때 정확히 그 itemID 만 빼도록(여러 카드 연속 열기 안전).
                let eventID = entry.recallEventID
                return .merge(
                    .run { _ in
                        if let eventID {
                            try? await apiClient.recordRecallReaction(eventID: eventID, reaction: .opened)
                        }
                    },
                    .send(.delegate(.recallItemOpened(itemID: entry.itemID, hero: hero)))
                )

            case let .recallDetailClosed(itemID):
                // 상세가 닫혀(hero 가 카드 자리에 착지) 돌아왔다 — 닫힌 그 회수만 피드에서 뺀다(itemID 로 특정 —
                // 닫는 사이 다른 카드를 열어도 엉뚱한 카드가 빠지지 않는다). RecallHeroView 의
                // `.transition(.scale+opacity)` 가 호출부 animation 트랜잭션에 실려 발동한다.
                state.recall.removeAll { $0.itemID == itemID }
                state.recallImages[itemID] = nil
                return .none

            case let .categoryTapped(bucket):
                return .send(.delegate(.categoryCarouselRequested(bucket)))

            case .mochiItemTapped, .openSettingsTapped:
                // 상위 Feature(MainTab)가 처리 — 상세 hero present / 설정 push.
                return .none

            case .needsReviewTapped:
                state.isNeedsReviewPresented = !state.needsReview.isEmpty
                return .none

            case .dismissNeedsReview:
                state.isNeedsReviewPresented = false
                return .none

            case let .deleteMochiItemTapped(id):
                state.deleteAlert = AlertState {
                    TextState("기록을 삭제할까요?")
                } actions: {
                    ButtonState(role: .destructive, action: .confirmDelete(id)) { TextState("삭제") }
                    ButtonState(role: .cancel) { TextState("취소") }
                } message: {
                    TextState("삭제한 기록은 되돌릴 수 없어요.")
                }
                return .none

            case let .deleteAlert(.presented(.confirmDelete(id))):
                return .run { send in
                    do {
                        if let item = try await repository.find(id: id),
                           case let .uploaded(serverID, _) = item.syncState {
                            try await apiClient.deleteMochiItem(mochiServerID: serverID)
                        }
                        try await repository.delete(id: id)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .deleteAlert:
                return .none

            case let .retryAnalysisTapped(mochiItemID):
                return .run { send in
                    do {
                        try await repository.requeueForAnalysis(mochiItemID: mochiItemID)
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .reanalyzeTapped(mochiItemID, hint):
                return .run { send in
                    do {
                        guard let item = try await repository.find(id: mochiItemID),
                              case let .uploaded(serverID, _) = item.syncState else { return }
                        try await apiClient.reanalyzeMochiItem(id: serverID, userHint: hint)
                        try await repository.requeueForAnalysis(mochiItemID: mochiItemID)
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .quickMemoSubmitted:
                let text = state.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSaving else { return .none }
                state.isSaving = true
                let id = uuid()
                let now = date.now
                // 한 입력창에 링크든 메모든 — URL 한 건이면 url 채널로, 아니면 메모로.
                let source: IngestSource
                if let url = Self.normalizedURL(text) {
                    source = IngestSource(id: id, channel: Self.channel(for: url), url: url, capturedAt: now)
                } else {
                    source = IngestSource(id: id, channel: .appDirectInput, text: text, capturedAt: now)
                }
                return .run { send in
                    do {
                        try await repository.upsert(MochiItem(source: source, createdAt: now, updatedAt: now))
                        await syncTrigger.runOnce()
                        await send(.quickMemoSaved)
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .quickMemoSaved:
                state.isSaving = false
                state.quickMemoText = ""
                state.isComposingMemo = false
                return .none

            case let .imagePicked(data, memo):
                let id = uuid()
                let now = date.now
                let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
                return .run { send in
                    do {
                        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        let filename = "\(id.uuidString).jpg"
                        let permanent = AppGroup.capturedImagesDirectoryURL.appendingPathComponent(filename)
                        try data.write(to: permanent, options: [.atomic])
                        let ref = ImageRef(
                            relativePath: "captures/\(filename)",
                            mimeType: "image/jpeg",
                            byteSize: data.count,
                            sha256: digest,
                            objectKey: nil
                        )
                        let source = IngestSource(
                            id: id,
                            channel: .screenshot,
                            imageRefs: [ref],
                            userMemo: trimmedMemo.isEmpty ? nil : trimmedMemo,
                            capturedAt: now
                        )
                        try await repository.upsert(MochiItem(source: source, createdAt: now, updatedAt: now))
                        await syncTrigger.runOnce()
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .monthlyDigestTapped:
                return .send(.delegate(.monthlyDigestRequested))

            case .favoritesTapped:
                return .send(.delegate(.favoritesRequested))

            case .replayOnboardingTapped:
                return .send(.delegate(.onboardingRequested))

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$deleteAlert, action: \.deleteAlert)
    }

    // MARK: - Helpers

    /// recent / needsReview / monthly(이번 달 카테고리 집계) 를 병렬 로드.
    private func loadAll(send: Send<Action>) async {
        async let recentTask: [MochiItem] = (try? await repository.listRecent(limit: 12)) ?? []
        async let needsReviewTask: [MochiItem] = (try? await repository.listNeedsReview(limit: 10)) ?? []
        // 카테고리 리포트는 이번 달 표본만 — 전체를 보여주면 최신성이 거의 안 반영된다(회의 결정).
        async let monthlyTask: [MochiItem] = (try? await repository.listCaptured(in: Self.currentMonthInterval(now: date.now), limit: 800)) ?? []

        let (recent, needsReview, monthlyItems) = await (
            recentTask, needsReviewTask, monthlyTask
        )

        await send(.sectionsLoaded(
            recent: recent, needsReview: needsReview, monthlyItems: monthlyItems
        ))
    }

    private static let carouselCoverCap = 30
    private static let categoryGridLimit = 6

    /// 카테고리별 누적 묶음 — 전체 표본을 카테고리로 묶어 개수 내림차순. `count` 는 전체 개수(표시용),
    /// `items` 는 턴테이블에 띄울 대표 항목(상한). 카드 탭 시 그대로 넘겨 즉시 그린다.
    static func categoryBuckets(from items: [MochiItem]) -> [CategoryBucket] {
        var order: [String] = []
        var groups: [String: [MochiItem]] = [:]
        for item in items {
            let category = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = category.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackCategory(for: item)
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(item)
        }
        return order
            .map { (name: $0, items: groups[$0] ?? []) }
            .sorted { lhs, rhs in
                if lhs.items.count != rhs.items.count { return lhs.items.count > rhs.items.count }
                return lhs.name < rhs.name
            }
            .prefix(categoryGridLimit)
            .enumerated()
            .map { index, pair in
                CategoryBucket(
                    name: pair.name,
                    count: pair.items.count,
                    items: Array(pair.items.prefix(carouselCoverCap)),
                    tintIndex: index
                )
            }
    }

    private static func currentMonthInterval(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .autoupdatingCurrent
        return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 30 * 24 * 60 * 60)
    }

    /// category 가 비었을 때의 의도 기반 라벨(일정/할 일/학습/기록). 상세 화면
    /// (`MonthlyDigestFeature.makeGroups`)도 같은 분류 규칙을 공유한다 — 같은 모듈 internal.
    static func fallbackCategory(for item: MochiItem) -> String {
        if let label = item.instances.first(where: { ($0.label ?? "").isEmpty == false })?.label {
            return label
        }
        switch item.representativeIntent {
        case .schedule: return "일정"
        case .todo: return "할 일"
        case .knowledge: return "학습"
        case .memo, .none: return "기록"
        }
    }

    /// raw 문자열을 http(s) URL 로 정규화. scheme 누락 시 https 부착, http/https 아니거나 host 없으면 nil.
    static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// host 기반 채널 추론 — 앱 내 URL 입력도 같은 enrich 채널로 흘려보내 분석 일관성 유지.
    static func channel(for url: URL) -> IngestChannel {
        guard let host = url.host?.lowercased() else { return .appShareSheet }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("kakao") { return .kakaoTalk }
        if host.contains("apple.com") || host.contains("safari") { return .safari }
        return .appShareSheet
    }
}
