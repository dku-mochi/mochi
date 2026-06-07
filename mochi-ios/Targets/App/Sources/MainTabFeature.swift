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
        var settings = SettingsFeature.State()

        /// 설정 모달 (홈 톱니바퀴 버튼 → 시트).
        var isSettingsPresented: Bool = false
        /// 디버그용 InboxView 모달 — 설정 시트 안에서 push 되지만 reducer 차원에선 flag 만.
        var isDebugInboxPresented: Bool = false

        /// 홈 탭 네비게이션 스택 — 카드 탭 시 상세를 push.
        /// detail 을 App 레이어 StackState 로 둬, Feature 간 직접 의존(아키텍처 위반) 없이
        /// 탭별 독립 스택을 얻는다(같은 detail 을 여러 탭이 공유하면 비선택 탭에 따라붙는 버그 회피).
        var homePath = StackState<DetailFeature.State>()
        /// 캘린더 탭 네비게이션 스택.
        var calendarPath = StackState<DetailFeature.State>()
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
        case settings(SettingsFeature.Action)
        case homePath(StackActionOf<DetailFeature>)
        case calendarPath(StackActionOf<DetailFeature>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
        case settingsSheetChanged(Bool)
        case debugInboxChanged(Bool)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.home,     action: \.home)     { HomeFeature() }
        Scope(state: \.inbox,    action: \.inbox)    { InboxFeature() }
        Scope(state: \.mochiCalendar, action: \.mochiCalendar) { MochiCalendarFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            case let .home(.mochiItemTapped(mochiItemID)):
                state.homePath.append(DetailFeature.State(mochiItemID: mochiItemID))
                return .none

            case .home(.openSettingsTapped):
                state.isSettingsPresented = true
                return .none

            case .home(.askMochiTapped):
                // ③ 질문 진입 — 자연어 회수 탈출구를 채팅(질문) 탭으로 라우팅.
                state.selectedTab = .chat
                return .none

            case .home(.urlChipTapped), .home(.screenshotChipTapped):
                // 추후 capture sheet 또는 system picker 연결. 현 단계는 no-op.
                return .none

            case .inbox(.mochiItemTapped):
                // dev 디버그 인박스 — push 전환 범위에서 제외(상세 진입 비활성).
                return .none

            case let .mochiCalendar(.mochiItemTapped(mochiItemID)):
                // 그날 목록 sheet(DaySheet)를 닫고 캘린더 탭 스택에 상세를 push (중첩 sheet 제거).
                state.mochiCalendar.selectedDay = nil
                state.mochiCalendar.selectedDayItems = []
                state.calendarPath.append(DetailFeature.State(mochiItemID: mochiItemID))
                return .none

            case let .settingsSheetChanged(isOn):
                state.isSettingsPresented = isOn
                if !isOn { state.isDebugInboxPresented = false }
                return .none

            case let .debugInboxChanged(isOn):
                state.isDebugInboxPresented = isOn
                return .none

            case .home, .inbox, .mochiCalendar, .search, .settings, .homePath, .calendarPath, .mochiItem:
                return .none
            }
        }
        .forEach(\.homePath, action: \.homePath) { DetailFeature() }
        .forEach(\.calendarPath, action: \.calendarPath) { DetailFeature() }
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
    }
}
