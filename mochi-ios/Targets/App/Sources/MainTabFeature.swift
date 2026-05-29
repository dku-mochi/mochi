import ComposableArchitecture
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 reducer.
///
/// 시안에 따라 4개 탭(홈/채팅/일정/검색) 구조. 채팅·일정은 현 단계 placeholder.
/// 기존 InboxFeature 는 설정 화면의 디버그 항목에서만 접근 가능하도록 보존.
@Reducer
struct MainTabFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var selectedTab: Tab = .home
        var home = HomeFeature.State()
        var inbox = InboxFeature.State()    // dev debug 접근용 (설정 → 디버그)
        var search = SearchFeature.State()
        var settings = SettingsFeature.State()

        /// 설정 모달 (홈 톱니바퀴 버튼 → 시트).
        var isSettingsPresented: Bool = false
        /// 디버그용 InboxView 모달 — 설정 시트 안에서 push 되지만 reducer 차원에선 flag 만.
        var isDebugInboxPresented: Bool = false

        @Presents var detail: DetailFeature.State?
        @Presents var mochiItem: MochiItemFeature.State?
    }

    enum Tab: String, CaseIterable, Sendable {
        case home, chat, schedule, search

        var title: String {
            switch self {
            case .home:     return "홈"
            case .chat:     return "채팅"
            case .schedule: return "일정"
            case .search:   return "검색"
            }
        }
    }

    enum Action: Sendable {
        case tabSelected(Tab)
        case home(HomeFeature.Action)
        case inbox(InboxFeature.Action)
        case search(SearchFeature.Action)
        case settings(SettingsFeature.Action)
        case detail(PresentationAction<DetailFeature.Action>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
        case settingsSheetChanged(Bool)
        case debugInboxChanged(Bool)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.home,     action: \.home)     { HomeFeature() }
        Scope(state: \.inbox,    action: \.inbox)    { InboxFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none

            case let .home(.mochiItemTapped(mochiItemID)):
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case .home(.openSettingsTapped):
                state.isSettingsPresented = true
                return .none

            case .home(.openNotificationsTapped):
                // 현 단계 알림 inbox 화면이 없으므로 인박스 디버그 화면을 임시 진입점으로.
                state.selectedTab = .home
                state.isDebugInboxPresented = true
                return .none

            case .home(.urlChipTapped), .home(.screenshotChipTapped):
                // 추후 capture sheet 또는 system picker 연결. 현 단계는 no-op.
                return .none

            case let .inbox(.mochiItemTapped(mochiItemID)):
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none

            case let .settingsSheetChanged(isOn):
                state.isSettingsPresented = isOn
                if !isOn { state.isDebugInboxPresented = false }
                return .none

            case let .debugInboxChanged(isOn):
                state.isDebugInboxPresented = isOn
                return .none

            case .home, .inbox, .search, .settings, .detail, .mochiItem:
                return .none
            }
        }
        .ifLet(\.$detail,  action: \.detail)  { DetailFeature() }
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
    }
}
