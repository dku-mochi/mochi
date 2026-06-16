import Foundation
import CryptoKit
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking
import DesignSystem

/// 홈 화면 reducer.
///
/// 홈은 요약 피드가 아니라 "모찌 자동성의 예외 처리" 화면이다 (docs/UX_SPEC.md §3.4).
/// - 빠른 입력(우하단 플로팅 버튼): 텍스트(메모/URL 자동 판별)·사진(`screenshot`)을 한 버튼에
///   모은다. 텍스트는 한 입력창에서 받아 URL 이면 `url` 채널로, 아니면 `appDirectInput` 으로
///   흘려보낸다 — 사용자는 링크·메모를 구분해 적을 필요가 없다. 어느 경로든 upsert + sync trigger.
/// - ① 지금 확인해 주세요(`listNeedsReview`): 모찌가 확신 못 한 것만. 후보 칩 = 고른 의도를 hint 로 `reanalyze`(재분석 — intent 라벨만 박지 않고 payload·날짜를 보강해 캘린더/할일로 쓸 수 있게).
/// - ③ 최근에 보낸 것들(`listRecent`): 정리 대상이 아닌 안전망(원본 확인·되돌리기).
/// - ② 모찌가 정리하고 있어요(`listAnalyzing`): 분석 응답 대기. 사용자 행동 불필요, 화면 맨 하단·기본 접힘.
/// 자연어 회수(질문): 홈 입력바는 진입점만 — 제출 시 `delegate(.chatRequested)` 로
/// 상위(MainTab)가 채팅 탭 새 대화의 첫 메시지로 라우팅한다 (UX_SPEC.md §3.4 — 칩이
/// 광고하는 추천·수정은 검색 탭이 수행 불가, journal 2026-06-10 파급 ①).
@Reducer
public struct HomeFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var recent: IdentifiedArrayOf<MochiItem> = []
        /// 분석 응답 대기 중 ("모찌가 정리하고 있어요").
        public var analyzing: IdentifiedArrayOf<MochiItem> = []
        /// 분석은 끝났으나 모찌가 확신 못 함 ("지금 확인해 주세요", `needsReview == true`).
        public var needsReview: IdentifiedArrayOf<MochiItem> = []
        public var weeklyRecordCount: Int = 0
        public var weeklyTopCategories: [WeeklyCategoryStat] = []
        /// 능동 회수 "한 칸" — "다시 보면 좋을 기억"(고정 틀, 비면 "지금은 없어요"). cold-start 빈손은 정상.
        /// 가장 가치 높은 1건 미리보기 + count 만 홈에 두고, 자세히/상세는 별도 화면(RecallListFeature).
        public var recall: [RecallFeedEntryDTO] = []
        /// 채팅 입력바 밑 추천 칩 — 최근 기록의 intent/카테고리로 사용자화(로컬 규칙). 신규 유저는 evergreen.
        public var suggestions: [HomeSuggestion] = HomeFeature.evergreenSuggestions
        public var chatDraft: String = ""
        public var quickMemoText: String = ""
        /// 플로팅 버튼 → 입력 시트 표시 여부 (메모·링크 통합 창구).
        public var isComposingMemo: Bool = false
        public var needsReviewPage: Int = 0
        /// ② "모찌가 정리하고 있어요" 접힘 상태 (기본 접힘 — 평소엔 방해하지 않음).
        public var isProcessingExpanded: Bool = false
        public var isNeedsReviewModalPresented: Bool = false
        public var isLoading: Bool = false
        public var isSaving: Bool = false
        public var lastError: String?
        /// 카드 롱프레스 → 삭제 확인 alert. confirm 시 서버 soft delete + 로컬 hard delete.
        @Presents public var deleteAlert: AlertState<Action.Alert>?

        public init() {}
    }

    public enum Action: Sendable, BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case sectionsLoaded(
            recent: [MochiItem],
            analyzing: [MochiItem],
            needsReview: [MochiItem],
            weeklyItems: [MochiItem]
        )
        case loadFailed(String)
        /// 회수 피드 로드 결과(빈손이면 [] — cold-start 정상). onAppear 와 별개 effect 로 분리해
        /// 회수 API 실패가 홈 본문(recent/needsReview) 로드를 막지 않게 한다(실패 격리).
        case recallLoaded([RecallFeedEntryDTO])
        /// 회수 "한 칸" 탭 → 상위(MainTab)가 ② 자세히 목록을 push 한다.
        case recallEntryTapped
        case suggestedQuestionTapped(String)
        case chatSubmitTapped
        case reviewSummaryTapped
        case dismissReviewModal
        case quickMemoSubmitted
        case quickMemoSaved
        /// 사진(라이브러리/카메라) 선택 결과 — JPEG 데이터 + 사용자 메모(선택)를 캡처로 ingest.
        case imagePicked(data: Data, memo: String)
        case retryAnalysisTapped(MochiItem.ID)
        case reanalyzeTapped(mochiItemID: MochiItem.ID, hint: String)
        case toggleProcessing
        // 탭 → 상세. hero 는 카드의 이미지·제목·카드 글로벌 frame (App 레이어 hero 전환 시작점).
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames)
        // 카드 롱프레스 메뉴의 삭제 → 확인 alert → soft delete.
        case deleteMochiItemTapped(MochiItem.ID)
        case deleteAlert(PresentationAction<Alert>)
        case openSettingsTapped
        case favoritesTapped
        case replayOnboardingTapped
        case weeklyDigestTapped
        case seeAllRecentTapped
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete(MochiItem.ID)
        }
        public enum Delegate: Equatable, Sendable {
            case onboardingRequested
            case weeklyDigestRequested
            /// 홈 질문 입력바·추천 칩 제출 — 상위가 채팅 탭 새 대화의 첫 메시지로 전환한다.
            case chatRequested(String)
            /// "최근에 보낸 것들 > 전체 보기" — 상위가 검색 탭(전체 기록 브라우징)으로 전환한다.
            case seeAllRecentRequested
            /// 회수 "한 칸" 탭 — 상위가 ② 자세히(통일 카드 목록)를 push 한다. 이미 받아둔 피드를 넘겨
            /// 즉시 그린다(목록 화면은 백그라운드 최신화만).
            case recallListRequested([RecallFeedEntryDTO])
            /// 헤더 별 → 상위가 즐겨찾기 화면을 push 한다.
            case favoritesRequested
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
                // 최초 load + 저장소 변경 관찰(서버 응답·외부 캡처 도착 시 즉시 재로드).
                return .merge(
                    .run { send in await loadAll(send: send) },
                    // 회수 피드는 별도 effect — 실패해도 홈 본문 로드를 막지 않는다(실패 격리).
                    // cancelInFlight — onAppear/refresh 가 겹쳐도 이전 응답이 최신을 덮지 않게(stale overwrite 방지).
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

            case let .sectionsLoaded(recent, analyzing, needsReview, weeklyItems):
                state.isLoading = false
                state.recent = IdentifiedArray(uniqueElements: recent)
                state.analyzing = IdentifiedArray(uniqueElements: analyzing)
                state.needsReview = IdentifiedArray(uniqueElements: needsReview)
                state.weeklyRecordCount = weeklyItems.count
                state.weeklyTopCategories = Self.weeklyCategoryStats(from: weeklyItems)
                state.suggestions = Self.makeSuggestions(
                    recent: recent, categories: state.weeklyTopCategories
                )
                if state.needsReviewPage >= needsReview.count {
                    state.needsReviewPage = max(0, needsReview.count - 1)
                }
                if needsReview.isEmpty {
                    state.isNeedsReviewModalPresented = false
                }
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                // 저장 실패도 이 경로로 들어오므로 isSaving 을 함께 복구한다 —
                // 안 풀면 메모 저장 버튼(.disabled(store.isSaving))이 영구 비활성으로 잠긴다.
                state.isSaving = false
                state.lastError = message
                return .none

            case let .recallLoaded(entries):
                state.recall = entries
                return .none

            case .recallEntryTapped:
                guard !state.recall.isEmpty else { return .none }
                return .send(.delegate(.recallListRequested(state.recall)))

            case let .suggestedQuestionTapped(question):
                // 칩은 입력 없이 바로 회수 — "떠올린다"가 아니라 "떠오른다"(미션, PRODUCT.md §1.5).
                return .send(.delegate(.chatRequested(question)))

            case .chatSubmitTapped:
                let query = state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return .none }
                state.chatDraft = ""
                return .send(.delegate(.chatRequested(query)))

            case .reviewSummaryTapped:
                state.isNeedsReviewModalPresented = !state.needsReview.isEmpty
                return .none

            case .dismissReviewModal:
                state.isNeedsReviewModalPresented = false
                return .none

            case .quickMemoSubmitted:
                let text = state.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSaving else { return .none }
                state.isSaving = true
                let id = uuid()
                let now = date.now
                // 한 입력창에 링크든 메모든 적는다 — 내용이 URL 한 건이면 url 채널로, 아니면 메모로.
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
                // 백탭 캡처(CommitBackTapCaptureIntent)와 동일 경로: App Group captures/ 로 atomic write +
                // .pendingUpload 로 upsert → MochiItemSyncWorker 가 다음 tick 에 ingest.
                // 사용자가 남긴 메모는 ShareExt 와 동일하게 userMemo(분석 confidence 신호)로 격리한다.
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

            case let .retryAnalysisTapped(mochiItemID):
                // "모찌에게 다시 맡기기" — 분석으로 되돌리고 foreground 폴링이 다시 집어가게 한다.
                return .run { send in
                    do {
                        try await repository.requeueForAnalysis(mochiItemID: mochiItemID)
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .reanalyzeTapped(mochiItemID, hint):
                // 후보 칩(고른 의도 라벨) · "다른 의도"(자연어) 모두 이 경로 — 힌트로 서버 재분석을 요청한다.
                // 서버 PK 는 로컬 id 와 달라 uploaded 의 serverID 로 요청한다(로컬 id 로 보내면 404).
                // 서버 emit 성공 후 로컬을 analyzing 으로 되돌린다 — emit 실패 시 영영 analyzing 에
                // 멈추는 것을 막기 위해 순서를 지킨다. hint 는 서버 outbox 에만 일시 적재된다.
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

            case .toggleProcessing:
                state.isProcessingExpanded.toggle()
                return .none

            case .mochiItemTapped, .openSettingsTapped:
                // 상위 Feature 가 처리 (탭 이동·모달·navigation).
                return .none

            case .favoritesTapped:
                return .send(.delegate(.favoritesRequested))

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
                // 업로드된(서버에 존재하는) 항목만 서버 soft delete. 미업로드면 로컬만 지운다.
                // observeChanges() 가 리스트를 자동 갱신하므로 state 직접 조작은 불필요.
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

            case .replayOnboardingTapped:
                return .send(.delegate(.onboardingRequested))

            case .weeklyDigestTapped:
                return .send(.delegate(.weeklyDigestRequested))

            case .seeAllRecentTapped:
                return .send(.delegate(.seeAllRecentRequested))

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$deleteAlert, action: \.deleteAlert)
    }

    // MARK: - Helpers

    /// 3개 섹션을 병렬로 가져온다: recent / analyzing / needsReview.
    private func loadAll(send: Send<Action>) async {
        async let recentTask: [MochiItem] = (try? await repository.listRecent(limit: 12)) ?? []
        async let analyzingTask: [MochiItem] = (try? await repository.listAnalyzing(limit: 10)) ?? []
        async let needsReviewTask: [MochiItem] = (try? await repository.listNeedsReview(limit: 10)) ?? []
        async let weeklyTask: [MochiItem] = (try? await repository.listCaptured(in: Self.currentWeekInterval(now: date.now), limit: 500)) ?? []

        let (recent, analyzing, needsReview, weeklyItems) = await (
            recentTask,
            analyzingTask,
            needsReviewTask,
            weeklyTask
        )

        await send(.sectionsLoaded(
            recent: recent,
            analyzing: analyzing,
            needsReview: needsReview,
            weeklyItems: weeklyItems
        ))
    }

    private static func currentWeekInterval(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 24 * 60 * 60)
    }

    private static func weeklyCategoryStats(from items: [MochiItem]) -> [WeeklyCategoryStat] {
        let counts = items.reduce(into: [String: Int]()) { partial, item in
            let category = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = category.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackCategory(for: item)
            partial[label, default: 0] += 1
        }
        return counts
            .map { WeeklyCategoryStat(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name < rhs.name
            }
            .prefix(3)
            .map { $0 }
    }

    private static func fallbackCategory(for item: MochiItem) -> String {
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

    /// 사용자가 적은 raw 문자열을 http(s) URL 로 정규화. scheme 누락 시 https 를 붙이고,
    /// http/https 가 아니거나(예: ftp://) host 가 없으면(빈 문자열·평문 메모) nil → ingest 하지 않는다.
    static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// host 기반 채널 추론 — `ShareExtensionPrincipal.guessChannel` 과 동일 규칙(앱 내 URL 입력도
    /// 같은 enrich 채널로 흘려보내 분석 일관성 유지).
    static func channel(for url: URL) -> IngestChannel {
        guard let host = url.host?.lowercased() else { return .appShareSheet }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("kakao") { return .kakaoTalk }
        if host.contains("apple.com") || host.contains("safari") { return .safari }
        return .appShareSheet
    }

    // MARK: - 추천 칩 사용자화 (로컬 규칙)

    /// 최근 기록의 intent·상위 카테고리로 채팅 추천 칩을 만든다(서버/LLM 없이 로컬 규칙).
    /// 개인화 후보를 우선 채우고, 모자라면 evergreen 으로 4개까지 채운다(신규·기록 적은 유저 안전).
    /// 칩 문구는 그대로 채팅 첫 질문으로 전송되므로, 모찌가 답할 수 있는 회수형 질문으로 쓴다.
    static func makeSuggestions(
        recent: [MochiItem], categories: [WeeklyCategoryStat]
    ) -> [HomeSuggestion] {
        let intents = Set(recent.compactMap { $0.representativeIntent })
        var candidates: [HomeSuggestion] = []

        if let top = categories.first {
            candidates.append(.init(icon: "sparkles", text: "\(top.name) 기록 모아줘"))
        }
        if intents.contains(.todo) {
            candidates.append(.init(icon: "checkmark.circle.fill", text: "안 끝난 할 일 정리해줘"))
        }
        if intents.contains(.schedule) {
            candidates.append(.init(icon: "calendar", text: "다가오는 일정 알려줘"))
        }
        if categories.count > 1 {
            candidates.append(.init(icon: "square.grid.2x2.fill", text: "\(categories[1].name) 기록 모아줘"))
        }
        if intents.contains(.knowledge) {
            candidates.append(.init(icon: "book.fill", text: "저장해둔 자료 요약해줘"))
        }

        // 4개까지 evergreen 으로 채움(중복 제거).
        for ever in evergreenSuggestions where candidates.count < 4 {
            if !candidates.contains(where: { $0.text == ever.text }) { candidates.append(ever) }
        }
        return Array(candidates.prefix(4))
    }

    /// 기록이 없거나 적은 유저를 위한 기본 칩 — 모찌의 회수 능력 폭을 보여준다.
    static let evergreenSuggestions: [HomeSuggestion] = [
        .init(icon: "magnifyingglass", text: "이번주에 뭐 저장했지?"),
        .init(icon: "sparkles", text: "요즘 내 관심사 정리해줘"),
        .init(icon: "clock.arrow.circlepath", text: "최근에 남긴 거 보여줘"),
        .init(icon: "lightbulb.fill", text: "뭐부터 보면 좋을까?"),
    ]
}

public struct HomeSuggestion: Equatable, Sendable, Hashable, Identifiable {
    public var id: String { text }
    public let icon: String
    public let text: String
}

public struct WeeklyCategoryStat: Equatable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let count: Int
}
