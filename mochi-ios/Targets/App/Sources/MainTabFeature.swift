import ComposableArchitecture
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 reducer.
///
/// 시안에 따라 4개 탭(홈/채팅/캘린더/검색) 구조. 채팅은 현 단계 placeholder, 캘린더 탭은 월간 캘린더 화면.
/// 기존 InboxFeature 는 설정 화면의 디버그 항목에서만 접근 가능하도록 보존.
@Reducer
struct MainTabFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var selectedTab: Tab = .home
        var home = HomeFeature.State()
        var inbox = InboxFeature.State()    // dev debug 접근용 (설정 → 디버그)
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
    }

    enum Tab: String, CaseIterable, Sendable {
        case home, chat, mochis, search

        var title: String {
            switch self {
            case .home:   return "홈"
            case .chat:   return "채팅"
            case .mochis: return "캘린더"
            case .search: return "검색"
            }
        }
    }

    enum Action: Sendable {
        case tabSelected(Tab)
        case home(HomeFeature.Action)
        case inbox(InboxFeature.Action)
        case mochiCalendar(MochiCalendarFeature.Action)
        case search(SearchFeature.Action)
        case path(StackActionOf<Path>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
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
        Scope(state: \.mochiCalendar, action: \.mochiCalendar) { MochiCalendarFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            case let .home(.mochiItemTapped(mochiItemID)):
                state.path.append(.detail(DetailFeature.State(mochiItemID: mochiItemID)))
                return .none

            case .home(.openSettingsTapped):
                state.path.append(.settings(SettingsFeature.State()))
                return .none

            case .inbox(.mochiItemTapped):
                // dev 디버그 인박스 — push 전환 범위에서 제외(상세 진입 비활성).
                return .none

            case let .mochiCalendar(.mochiItemTapped(mochiItemID)):
                // 그날 목록 sheet(DaySheet)를 닫고 상세를 push (중첩 sheet 제거).
                state.mochiCalendar.selectedDay = nil
                state.mochiCalendar.selectedDayItems = []
                state.path.append(.detail(DetailFeature.State(mochiItemID: mochiItemID)))
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

            case let .path(.element(id: id, action: .detail(.delegate(.deleted)))):
                // 상세에서 삭제 완료 → 해당 상세 화면을 스택에서 pop.
                state.path.pop(from: id)
                return .none

            case .home, .inbox, .mochiCalendar, .search, .path, .mochiItem, .delegate:
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
    }
}

extension MainTabFeature {
    /// 상세·설정을 한 스택에 담는 네비게이션 destination.
    /// 설정을 sheet 가 아닌 push 로 둬, 설정 위에 온보딩 fullScreenCover 를 띄울 때
    /// "single sheet" 충돌을 피한다.
    @Reducer
    enum Path {
        case detail(DetailFeature)
        case settings(SettingsFeature)
    }
}

// @Reducer enum 이 합성하는 Path.State 는 Equatable 을 자동 부여하지 않으므로 명시한다.
// (associated value 인 DetailFeature.State·SettingsFeature.State 가 모두 Equatable 이라 합성 가능)
extension MainTabFeature.Path.State: Equatable {}
