import Foundation
import SwiftUI
import ComposableArchitecture
import CoreNetworking

/// 능동 회수 — "다시 볼 가치 있는 기억을 모찌가 먼저 떠올려준다"(분류 아님, journal/proactive-recall/ux-ui §1).
///
/// 3단 구조를 두 reducer 로 나눈다:
///  - ``RecallListFeature`` — ② 자세히(통일 카드 목록). 홈 "한 칸"에서 진입.
///  - ``RecallDetailFeature`` — ③ 기록 상세(kind별 디테일 + 응답 액션). 목록 탭 / 알림 landing 직행.
///
/// 홈 "한 칸"(① count + 최상위 1개 미리보기)은 별도 화면이 아니라 ``HomeFeature`` 의 slice 로 둔다
/// (고정 틀·레이아웃 안정, ux-ui §6). 회수=가변이므로 목록·상세만 화면을 갖고 홈엔 요약만 둔다.
///
/// 응답 액션 ↔ 서버 reaction 1:1(codex-7): 탭 진입/열기/기억남=`opened`, "그만 보기"=`stop`(plan cancel).
/// 학습은 행동 신호(open) 우선 — primary 는 "목적 수행"이고 피드백은 보조(codex-8, ux-ui §4).

// MARK: - ② 자세히 보기 (통일 카드 목록)

@Reducer
public struct RecallListFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var entries: [RecallFeedEntryDTO]
        public var isLoading: Bool

        /// 홈 한 칸이 이미 피드를 들고 있으면 그대로 넘겨 즉시 그린다(빈손이면 onAppear 가 재로드).
        public init(entries: [RecallFeedEntryDTO] = [], isLoading: Bool = false) {
            self.entries = entries
            self.isLoading = isLoading
        }
    }

    public enum Action: Sendable {
        case onAppear
        case feedLoaded([RecallFeedEntryDTO])
        case loadFailed
        case entryTapped(RecallFeedEntryDTO)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Sendable {
            /// 통일 카드 탭 → 상위(MainTab)가 ③ 상세를 push 한다.
            case openDetail(RecallFeedEntryDTO)
        }
    }

    @Dependency(\.mochiAPIClient) var apiClient

    private enum CancelID: Hashable { case feed }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // 홈에서 받아온 게 없으면(직접 진입·콜드) 로드. 있으면 최신화만 백그라운드로.
                if state.entries.isEmpty { state.isLoading = true }
                // cancelInFlight — 재진입 시 이전 응답이 나중 도착해 최신 목록을 덮는 stale overwrite 방지.
                return .run { send in
                    do {
                        await send(.feedLoaded(try await apiClient.recallFeed(limit: 20)))
                    } catch {
                        await send(.loadFailed)
                    }
                }
                .cancellable(id: CancelID.feed, cancelInFlight: true)

            case let .feedLoaded(entries):
                state.isLoading = false
                state.entries = entries
                return .none

            case .loadFailed:
                // 이미 받아둔 목록이 있으면 유지(빈손으로 덮지 않음) — 로딩 표시만 내린다.
                state.isLoading = false
                return .none

            case let .entryTapped(entry):
                return .send(.delegate(.openDetail(entry)))

            case .delegate:
                return .none
            }
        }
    }
}

// MARK: - ③ 기록 상세 (kind별 디테일 + 응답 액션)

@Reducer
public struct RecallDetailFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var entry: RecallFeedEntryDTO
        /// 탭하여 상세 진입한 사실 자체를 한 번만 opened 로 보고(행동 신호 우선, ux-ui §6).
        public var hasReportedOpen: Bool = false
        /// "그만 보기" 낙관적 표시 — 한 번 누르면 잠그고 토스트.
        public var didStop: Bool = false
        /// 가벼운 확인 토스트(낙관적 UI). 백그라운드 reaction 실패는 격리(토스트만 보여줌).
        public var toast: String?

        /// 알림 landing 경로는 탭 시점에 상위(MainTab)가 이미 opened 를 보고했으므로 onAppear 의
        /// 중복 보고를 막는다(true). 목록 탭 진입(in-app)은 false — onAppear 가 보고한다.
        public init(entry: RecallFeedEntryDTO, alreadyReportedOpen: Bool = false) {
            self.entry = entry
            self.hasReportedOpen = alreadyReportedOpen
        }
    }

    public enum Action: Sendable {
        case onAppear
        case markReportedOpen
        case openOriginalTapped
        case relatedTapped(RelatedItemDTO)
        case rememberedTapped
        case stopTapped
        case showToast(String)
        case dismissToast
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Sendable {
            /// "원본 보기" — 상위가 원본 mochiItem 상세를 연다(server PK).
            case openOriginal(itemID: UUID)
            /// "관련 기억" 카드 탭 — 상위가 그 항목 상세를 연다(원본 보기와 같은 경로).
            case openRelated(itemID: UUID)
        }
    }

    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.continuousClock) var clock

    private enum CancelID: Hashable { case toast }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // 탭하여 상세 진입 = opened(행동 신호 우선). recallEventID 없으면 보고 생략.
                guard !state.hasReportedOpen, let eventID = state.entry.recallEventID else { return .none }
                return .merge(
                    .send(.markReportedOpen),
                    .run { _ in try? await apiClient.recordRecallReaction(eventID: eventID, reaction: .opened) }
                )

            case .markReportedOpen:
                state.hasReportedOpen = true
                return .none

            case .openOriginalTapped:
                return .send(.delegate(.openOriginal(itemID: state.entry.itemID)))

            case let .relatedTapped(item):
                return .send(.delegate(.openRelated(itemID: item.itemID)))

            case .rememberedTapped:
                // "기억났어요" — 양성 신호(opened). primary 가 아니라 보조 피드백(codex-8).
                let eventID = state.entry.recallEventID
                return .merge(
                    .send(.showToast("좋아요 · 다음엔 더 늦게 꺼낼게요")),
                    .run { _ in
                        guard let eventID else { return }
                        try? await apiClient.recordRecallReaction(eventID: eventID, reaction: .opened)
                    }
                )

            case .stopTapped:
                // "그만 보기" = stop(영구, plan cancel). destructive — 1:1 매핑(codex-7).
                guard !state.didStop else { return .none }
                state.didStop = true
                let eventID = state.entry.recallEventID
                return .merge(
                    .send(.showToast("이 기억은 더 꺼내지 않을게요")),
                    .run { _ in
                        guard let eventID else { return }
                        try? await apiClient.recordRecallReaction(eventID: eventID, reaction: .stop)
                    }
                )

            case let .showToast(message):
                // withAnimation 으로 감싸 토스트 .transition(move+opacity)이 적용되게 한다.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.toast = message }
                return .run { send in
                    try? await clock.sleep(for: .seconds(1.6))
                    await send(.dismissToast)
                }
                .cancellable(id: CancelID.toast, cancelInFlight: true)

            case .dismissToast:
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.toast = nil }
                return .none

            case .delegate:
                return .none
            }
        }
    }
}

// MARK: - 회수 이유 (분류 아님 — "왜 지금 떠올렸나")

/// 백엔드 `reason` 문자열 → 표시 모델. 색/아이콘/라벨은 iOS 가 매핑한다(UI 필드 비계약, ux-ui §3).
/// 접근성: VoiceOver 가 "회수 이유: …"로 의미를 읽게 ``accessibilityLabel`` 을 제공한다(codex-9).
public enum RecallReasonKind: String, Sendable, CaseIterable {
    case relatedCluster   // 관련 기록이 모임
    case fadingValue      // 안 본 지 오래 — "잊기 전에 한 번"
    case revisitedOften   // 자주 보던
    case linkedToRecent   // 방금/최근 맥락과 이어짐

    /// 백엔드 reason 문자열 매핑. 미지의 값은 fadingValue(가장 흔한 "다시 볼 지식")로 안전 강등.
    public init(reason: String) {
        self = RecallReasonKind(rawValue: reason) ?? .fadingValue
    }

    public var label: String {
        switch self {
        case .relatedCluster: "관련해서 여러 번"
        case .fadingValue:    "잊기 전에 한 번"
        case .revisitedOften: "요즘 자주 보시던"
        case .linkedToRecent: "최근에 보신 것과 이어져요"
        }
    }

    /// VoiceOver 라벨 — 칩 색·아이콘만으론 의미가 안 읽혀 명시한다(codex-9).
    public var accessibilityLabel: String { "회수 이유: \(label)" }

    public var icon: String {
        switch self {
        case .relatedCluster: "square.stack.3d.up"
        case .fadingValue:    "hourglass"
        case .revisitedOften: "arrow.counterclockwise"
        case .linkedToRecent: "link"
        }
    }
}
