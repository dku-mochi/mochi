import ComposableArchitecture
import DesignSystem
import FeatureChat
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 reducer.
///
/// 시안에 따라 4개 탭(홈/채팅/캘린더/검색) 구조. 캘린더 탭은 월간 캘린더 화면.
/// 기존 InboxFeature 는 설정 화면의 디버그 항목에서만 접근 가능하도록 보존.
@Reducer
struct MainTabFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var selectedTab: Tab = .home
        var home = HomeFeature.State()
        var inbox = InboxFeature.State()    // dev debug 접근용 (설정 → 디버그)
        var chatLanding = ChatLandingFeature.State()
        var mochiCalendar = MochiCalendarFeature.State()
        var search = SearchFeature.State()

        /// 디버그용 InboxView 모달 — 설정 화면 안에서 sheet 로 띄우지만 reducer 차원에선 flag 만.
        var isDebugInboxPresented: Bool = false

        /// 상세·설정 네비게이션 스택 — 카드 탭 시 detail, 톱니바퀴 탭 시 settings 를 push.
        /// App 레이어 StackState 로 둬 Feature 간 직접 의존(아키텍처 위반) 없이 보유한다.
        /// TabView 가 바깥 단일 NavigationStack 안에 있어, push 시 탭바를 포함한 전체가
        /// 함께 슬라이드되므로 탭과 무관한 단일 스택으로 충분하다.
        /// 설정을 sheet 가 아닌 push 로 둬, 설정 위에 온보딩 fullScreenCover 를 띄울 때 "single sheet" 충돌을 피한다.
        var path = StackState<Path.State>()
        @Presents var mochiItem: MochiItemFeature.State?

        /// 기록 카드 → 상세: UIKit 커스텀 zoom present (path push 가 아님).
        /// push 에는 UIKit 전환을 입힐 수 없어, 상세만 별도 custom presentation 으로 띄워
        /// 카드 frame 에서 확대되는 전환을 직접 제어한다. 설정은 그대로 path 에 push.
        @Presents var detail: DetailFeature.State?
        /// 카드 탭 시 캡처한 hero frame 묶음(카드·이미지·제목). nil 이면 중앙 scale 폴백(예: 캘린더 진입).
        var detailHero: HeroSourceFrames?
    }

    enum Tab: String, CaseIterable, Sendable {
        case home, chat, mochis, search

        var title: String {
            switch self {
            case .home:   return "홈"
            case .chat:   return "질문"
            case .mochis: return "캘린더"
            case .search: return "검색"
            }
        }
    }

    enum Action: Sendable {
        case tabSelected(Tab)
        case searchTabReselected            // 검색 탭이 이미 선택된 상태에서 다시 탭 → 시작 화면으로 복귀
        case home(HomeFeature.Action)
        case inbox(InboxFeature.Action)
        case chatLanding(ChatLandingFeature.Action)
        case mochiCalendar(MochiCalendarFeature.Action)
        case search(SearchFeature.Action)
        case path(StackActionOf<Path>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
        case detail(PresentationAction<DetailFeature.Action>)
        case debugInboxChanged(Bool)
        case delegate(Delegate)

        enum Delegate: Sendable {
            case logoutRequested
            case onboardingRequested
        }
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.home,     action: \.home)     { HomeFeature() }
        Scope(state: \.inbox,    action: \.inbox)    { InboxFeature() }
        Scope(state: \.chatLanding, action: \.chatLanding) { ChatLandingFeature() }
        Scope(state: \.mochiCalendar, action: \.mochiCalendar) { MochiCalendarFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            case .searchTabReselected:
                return .send(.search(.clearFiltersTapped))

            case let .home(.mochiItemTapped(mochiItemID, hero)):
                // 이미 상세가 떠 있으면(또는 present 애니메이션 진행 중) 재진입 무시 —
                // presenter 가 중복 present 를 막으므로 state 만 바꾸면 state↔화면이 어긋난다.
                guard state.detail == nil else { return .none }
                // 탭한 카드의 hero frame 을 기억해 거기서 날아오는 hero 전환.
                state.detailHero = hero
                // 이미지 비행이 있으면 상세 hero 이미지를 숨긴 채 시작 — 비행 스냅샷과 이중 노출 방지.
                state.detail = DetailFeature.State(
                    mochiItemID: mochiItemID,
                    heroImageHidden: hero.cardImage != nil
                )
                return .none

            case .home(.openSettingsTapped):
                state.path.append(.settings(SettingsFeature.State()))
                return .none

            case .home(.delegate(.weeklyDigestRequested)):
                state.path.append(.weeklyDigest(WeeklyDigestFeature.State()))
                return .none

            case let .home(.delegate(.chatRequested(query))):
                // 홈 질문 입력바 → 대화 풀스크린 push, 첫 메시지로 전송 (2026-06-10 push 전환).
                // 탭은 바꾸지 않는다 — back 으로 홈에 그대로 돌아온다.
                state.path.append(.chat(ChatFeature.State(entry: .firstMessage(query))))
                return .none

            case let .chatLanding(.delegate(.conversationRequested(entry))):
                // 랜딩(입력바 모양 버튼·칩·지난 대화) → 대화 풀스크린 push.
                state.path.append(.chat(ChatFeature.State(entry: entry)))
                return .none

            case .home(.delegate(.seeAllRecentRequested)):
                // "전체 보기" — 전체 기록을 날짜로 훑을 수 있는 캘린더 탭으로.
                state.selectedTab = .mochis
                return .none

            case let .path(.element(id: _, action: .weeklyDigest(.delegate(.mochiItemTapped(mochiItemID, hero))))):
                // 정리 화면의 항목 탭 → 상세 present (캘린더처럼 hero 없으면 중앙 scale 폴백).
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case .inbox(.mochiItemTapped):
                // dev 디버그 인박스 — push 전환 범위에서 제외(상세 진입 비활성).
                return .none

            case let .mochiCalendar(.mochiItemTapped(mochiItemID, hero)):
                guard state.detail == nil else { return .none }
                // DaySheet 는 열어둔 채 그 위로 상세를 hero present — presenter 가 최상단
                // presented VC 위에서 띄우므로 sheet 와 충돌하지 않고, 상세를 닫으면
                // 보던 날짜 목록으로 그대로 돌아온다. hero 없으면 중앙 scale 폴백.
                state.detailHero = hero
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .search(.recentTapped(mochiItemID, hero)):
                // 홈 카드와 동일한 hero present — 검색 카드 frame 에서 확대.
                guard state.detail == nil else { return .none }
                state.detailHero = hero
                state.detail = DetailFeature.State(
                    mochiItemID: mochiItemID,
                    heroImageHidden: hero?.cardImage != nil
                )
                return .none

            case let .path(.element(id: _, action: .chat(.delegate(.openItemRequested(mochiItemID))))):
                // 채팅 근거 미니카드 탭 — hero frame 이 없어 중앙 scale 폴백 (캘린더와 동일).
                guard state.detail == nil else { return .none }
                state.detailHero = nil
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .debugInboxChanged(isOn):
                state.isDebugInboxPresented = isOn
                return .none

            case .path(.element(id: _, action: .settings(.delegate(.logoutRequested)))):
                // 설정 화면을 닫고 로그아웃을 상위(RootFeature.requestSignOut)로 위임.
                state.path.removeAll()
                return .send(.delegate(.logoutRequested))

            case .home(.delegate(.onboardingRequested)),
                 .path(.element(id: _, action: .settings(.delegate(.onboardingRequested)))):
                return .send(.delegate(.onboardingRequested))

            case .detail(.presented(.delegate(.deleted))),
                 .detail(.presented(.delegate(.closeRequested))):
                // 상세에서 삭제 완료 / 닫기 → custom present 를 닫는다 (state nil → presenter dismiss).
                state.detail = nil
                return .none

            case .home, .inbox, .chatLanding, .mochiCalendar, .search, .path, .mochiItem, .detail, .delegate:
                return .none

            case .tabSelected, .searchTabReselected:
                // 위에서 명시 처리됨 — Swift exhaustive 매칭 만족용 (실제 도달 X).
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
        .ifLet(\.$detail, action: \.detail) { DetailFeature() }
    }
}

extension MainTabFeature {
    /// 네비게이션 destination — 설정·이번주 정리·대화. 설정을 sheet 가 아닌 push 로 둬,
    /// 설정 위에 온보딩 fullScreenCover 를 띄울 때 "single sheet" 충돌을 피한다.
    /// (상세는 path 가 아니라 `@Presents var detail` 로 별도 custom present.)
    @Reducer
    enum Path {
        case settings(SettingsFeature)
        case weeklyDigest(WeeklyDigestFeature)
        /// 대화 풀스크린 — 탭바를 덮는 push (랜딩·홈 입력바가 Entry 를 들고 연다).
        case chat(ChatFeature)
    }
}

// @Reducer enum 이 합성하는 Path.State 는 Equatable 을 자동 부여하지 않으므로 명시한다.
// (associated value 인 DetailFeature.State·SettingsFeature.State 가 모두 Equatable 이라 합성 가능)
extension MainTabFeature.Path.State: Equatable {}
