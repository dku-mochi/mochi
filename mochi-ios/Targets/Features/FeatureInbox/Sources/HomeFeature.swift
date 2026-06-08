import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking

/// 홈 화면 reducer.
///
/// 홈은 요약 피드가 아니라 "모찌 자동성의 예외 처리" 화면이다 (docs/PRODUCT.md §8.4).
/// - 빠른 입력(한 줄): `appDirectInput` 채널로 즉시 upsert + sync trigger.
/// - ① 지금 확인해 주세요(`listNeedsReview`): 모찌가 확신 못 한 것만. 분류 버튼 = `setIntent`.
/// - ② 모찌가 정리하고 있어요(`listAnalyzing`): 분석 응답 대기. 사용자 행동 불필요, 기본 접힘.
/// - ③ 최근에 보낸 것들(`listRecent`): 정리 대상이 아닌 안전망(원본 확인·되돌리기).
/// 자연어 회수(질문)는 홈에 진입점을 두지 않고 채팅·검색 탭이 담당한다.
@Reducer
public struct HomeFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var recent: IdentifiedArrayOf<MochiItem> = []
        /// 분석 응답 대기 중 ("모찌가 정리하고 있어요").
        public var analyzing: IdentifiedArrayOf<MochiItem> = []
        /// 분석은 끝났으나 모찌가 확신 못 함 ("지금 확인해 주세요", `needsReview == true`).
        public var needsReview: IdentifiedArrayOf<MochiItem> = []
        public var quickMemoText: String = ""
        public var needsReviewPage: Int = 0
        /// ② "모찌가 정리하고 있어요" 접힘 상태 (기본 접힘 — 평소엔 방해하지 않음).
        public var isProcessingExpanded: Bool = false
        public var isLoading: Bool = false
        public var isSaving: Bool = false
        public var lastError: String?

        public init() {}
    }

    public enum Action: Sendable, BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case sectionsLoaded(recent: [MochiItem], analyzing: [MochiItem], needsReview: [MochiItem])
        case loadFailed(String)
        case quickMemoSubmitted
        case quickMemoSaved
        case classifyTapped(mochiItemID: MochiItem.ID, intent: Intent)
        case classifyFinished
        case retryAnalysisTapped(MochiItem.ID)
        case reanalyzeTapped(mochiItemID: MochiItem.ID, hint: String)
        case toggleProcessing
        case mochiItemTapped(MochiItem.ID)
        case openSettingsTapped
        case urlChipTapped
        case screenshotChipTapped
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    private enum CancelID { case observe }

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
                    .run { send in
                        for await _ in repository.observeChanges() {
                            await loadAll(send: send)
                        }
                    }
                    .cancellable(id: CancelID.observe, cancelInFlight: true)
                )

            case .refresh:
                state.isLoading = true
                return .run { send in
                    await loadAll(send: send)
                }

            case let .sectionsLoaded(recent, analyzing, needsReview):
                state.isLoading = false
                state.recent = IdentifiedArray(uniqueElements: recent)
                state.analyzing = IdentifiedArray(uniqueElements: analyzing)
                state.needsReview = IdentifiedArray(uniqueElements: needsReview)
                if state.needsReviewPage >= needsReview.count {
                    state.needsReviewPage = max(0, needsReview.count - 1)
                }
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case .quickMemoSubmitted:
                let text = state.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSaving else { return .none }
                state.isSaving = true
                let id = uuid()
                let now = date.now
                let source = IngestSource(
                    id: id,
                    channel: .appDirectInput,
                    text: text,
                    capturedAt: now
                )
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
                return .none

            case let .classifyTapped(mochiItemID, intent):
                return .run { send in
                    do {
                        try await repository.setIntent(mochiItemID: mochiItemID, intent: intent)
                        await send(.classifyFinished)
                        await loadAll(send: send)
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case .classifyFinished:
                // 분류된 항목은 needsReview 리스트에서 빠지므로 page 0 = 다음 미확정 항목.
                state.needsReviewPage = 0
                return .none

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
                // "다른 의도" — 사용자가 적은 의도 힌트로 서버 재분석을 요청한다.
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

            case .mochiItemTapped, .openSettingsTapped,
                 .urlChipTapped, .screenshotChipTapped:
                // 상위 Feature 가 처리 (탭 이동·모달·navigation·system picker).
                return .none
            }
        }
    }

    // MARK: - Helpers

    /// 3개 섹션을 병렬로 가져온다: recent / analyzing / needsReview.
    private func loadAll(send: Send<Action>) async {
        async let recentTask: [MochiItem] = (try? await repository.listRecent(limit: 12)) ?? []
        async let analyzingTask: [MochiItem] = (try? await repository.listAnalyzing(limit: 10)) ?? []
        async let needsReviewTask: [MochiItem] = (try? await repository.listNeedsReview(limit: 10)) ?? []

        let (recent, analyzing, needsReview) = await (recentTask, analyzingTask, needsReviewTask)

        await send(.sectionsLoaded(recent: recent, analyzing: analyzing, needsReview: needsReview))
    }
}
