import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

/// 홈 화면(시안의 메인 진입) reducer.
///
/// - 최근 캡처 / 분석중 / 헷갈려요 / 중요해 보여요 네 섹션을 동시에 로드한다.
///   분석중(`listAnalyzing`)=분석 응답 대기, 헷갈려요(`listAmbiguous`)=분석됐으나 모찌가 확신 못 함.
/// - Quick memo 는 `appDirectInput` 채널로 즉시 Repository 에 upsert + 이어서 sync trigger.
/// - Needs review 의 분류 버튼은 `repository.setIntent` 호출 → 카드 진행 페이지를 다음으로.
/// - 진입 시 `dailyImportanceAnalyzer.todaysImportant` 를 호출해 1일 1회 lazy 분석.
@Reducer
public struct HomeFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var recent: IdentifiedArrayOf<MochiItem> = []
        /// 분석 응답 대기 중 ("모찌가 분석 중이에요").
        public var analyzing: IdentifiedArrayOf<MochiItem> = []
        /// 분석은 끝났으나 모찌가 확신 못 함 ("모찌가 헷갈려요").
        public var ambiguous: IdentifiedArrayOf<MochiItem> = []
        public var important: IdentifiedArrayOf<MochiItem> = []
        public var quickMemoText: String = ""
        public var needsReviewPage: Int = 0
        public var isLoading: Bool = false
        public var isSaving: Bool = false
        public var lastError: String?

        public init() {}
    }

    public enum Action: Sendable, BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case refresh
        case sectionsLoaded(recent: [MochiItem], analyzing: [MochiItem], ambiguous: [MochiItem], important: [MochiItem])
        case loadFailed(String)
        case quickMemoSubmitted
        case quickMemoSaved
        case classifyTapped(mochiItemID: MochiItem.ID, intent: Intent)
        case classifyFinished
        case retryAnalysisTapped(MochiItem.ID)
        case mochiItemTapped(MochiItem.ID)
        case openSettingsTapped
        case openNotificationsTapped
        case urlChipTapped
        case screenshotChipTapped
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.dailyImportanceAnalyzer) var dailyAnalyzer
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

            case let .sectionsLoaded(recent, analyzing, ambiguous, important):
                state.isLoading = false
                state.recent = IdentifiedArray(uniqueElements: recent)
                state.analyzing = IdentifiedArray(uniqueElements: analyzing)
                state.ambiguous = IdentifiedArray(uniqueElements: ambiguous)
                state.important = IdentifiedArray(uniqueElements: important)
                if state.needsReviewPage >= ambiguous.count {
                    state.needsReviewPage = max(0, ambiguous.count - 1)
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
                // 분류된 항목은 ambiguous 리스트에서 빠지므로 page 는 0 으로 되돌려도 안전.
                // 사용자 경험: "확정했으니 다음 항목을 본다" → reload 후 page 0 = 다음 미분류.
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

            case .mochiItemTapped, .openSettingsTapped, .openNotificationsTapped,
                 .urlChipTapped, .screenshotChipTapped:
                // 상위 Feature 가 처리 (모달·navigation·system picker).
                return .none
            }
        }
    }

    // MARK: - Helpers

    /// 4개를 병렬로 가져온다: recent / ambiguous / dailyImportant ID → importance MochiItem.
    /// dailyAnalyzer 의 결과(ID 리스트)와 repository.listByImportance 의 결과를 결합해
    /// "오늘의 캐시된 ID 순서" 를 유지하면서 도메인 객체를 채운다.
    private func loadAll(send: Send<Action>) async {
        async let recentTask: [MochiItem] = (try? await repository.listRecent(limit: 12)) ?? []
        async let analyzingTask: [MochiItem] = (try? await repository.listAnalyzing(limit: 10)) ?? []
        async let ambiguousTask: [MochiItem] = (try? await repository.listAmbiguous(limit: 10)) ?? []
        async let dailyIDs: [UUID] = dailyAnalyzer.todaysImportant(limit: 8)

        let (recent, analyzing, ambiguous, ids) = await (recentTask, analyzingTask, ambiguousTask, dailyIDs)

        var important: [MochiItem] = []
        if !ids.isEmpty {
            // 각 ID 를 repository 에서 가져온다 — 미존재(분석 후 삭제) 는 skip.
            for id in ids {
                if let mochiItem = try? await repository.find(id: id) {
                    important.append(mochiItem)
                }
            }
        } else {
            // fallback: 1일 캐시가 비었으면 (앱 첫 진입 등) 즉시 importance 정렬을 직접 가져온다.
            important = (try? await repository.listByImportance(limit: 8)) ?? []
        }

        await send(.sectionsLoaded(recent: recent, analyzing: analyzing, ambiguous: ambiguous, important: important))
    }
}
