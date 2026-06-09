import Foundation
import CryptoKit
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking

/// 홈 화면 reducer.
///
/// 홈은 요약 피드가 아니라 "모찌 자동성의 예외 처리" 화면이다 (docs/PRODUCT.md §8.4).
/// - 빠른 입력(우하단 플로팅 버튼): 텍스트(메모/URL 자동 판별)·사진(`screenshot`)을 한 버튼에
///   모은다. 텍스트는 한 입력창에서 받아 URL 이면 `url` 채널로, 아니면 `appDirectInput` 으로
///   흘려보낸다 — 사용자는 링크·메모를 구분해 적을 필요가 없다. 어느 경로든 upsert + sync trigger.
/// - ① 지금 확인해 주세요(`listNeedsReview`): 모찌가 확신 못 한 것만. 분류 버튼 = `setIntent`.
/// - ③ 최근에 보낸 것들(`listRecent`): 정리 대상이 아닌 안전망(원본 확인·되돌리기).
/// - ② 모찌가 정리하고 있어요(`listAnalyzing`): 분석 응답 대기. 사용자 행동 불필요, 화면 맨 하단·기본 접힘.
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
        public var weeklyRecordCount: Int = 0
        public var weeklyTopCategories: [WeeklyCategoryStat] = []
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
        case suggestedQuestionTapped(String)
        case chatSubmitTapped
        case reviewSummaryTapped
        case dismissReviewModal
        case quickMemoSubmitted
        case quickMemoSaved
        /// 사진(라이브러리/카메라) 선택 결과 — JPEG 데이터 + 사용자 메모(선택)를 캡처로 ingest.
        case imagePicked(data: Data, memo: String)
        case classifyTapped(mochiItemID: MochiItem.ID, intent: Intent)
        case classifyFinished
        case retryAnalysisTapped(MochiItem.ID)
        case reanalyzeTapped(mochiItemID: MochiItem.ID, hint: String)
        case toggleProcessing
        case mochiItemTapped(MochiItem.ID)
        case openSettingsTapped
        case replayOnboardingTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case onboardingRequested
        }
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

            case let .sectionsLoaded(recent, analyzing, needsReview, weeklyItems):
                state.isLoading = false
                state.recent = IdentifiedArray(uniqueElements: recent)
                state.analyzing = IdentifiedArray(uniqueElements: analyzing)
                state.needsReview = IdentifiedArray(uniqueElements: needsReview)
                state.weeklyRecordCount = weeklyItems.count
                state.weeklyTopCategories = Self.weeklyCategoryStats(from: weeklyItems)
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

            case let .suggestedQuestionTapped(question):
                state.chatDraft = question
                return .none

            case .chatSubmitTapped:
                // 채팅 회수 기능은 아직 미구현. 홈에는 입력 affordance 만 먼저 둔다.
                state.chatDraft = ""
                return .none

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

            case .mochiItemTapped, .openSettingsTapped:
                // 상위 Feature 가 처리 (탭 이동·모달·navigation).
                return .none

            case .replayOnboardingTapped:
                return .send(.delegate(.onboardingRequested))

            case .delegate:
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
}

public struct WeeklyCategoryStat: Equatable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let count: Int
}
