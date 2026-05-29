import ComposableArchitecture
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 (Inbox/Search/Settings) 와 modal presentations (Detail/MochiItem) 의 reducer.
///
/// 인증 이후의 모든 화면이 여기에 묶인다 — 인증 단계는 ``RootFeature`` 가 별도로 관리.
@Reducer
struct MainTabFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var selectedTab: Tab = .inbox
        var inbox  = InboxFeature.State()
        var search = SearchFeature.State()
        var settings = SettingsFeature.State()

        @Presents var detail: DetailFeature.State?
        @Presents var mochiItem: MochiItemFeature.State?
    }

    enum Tab: String, CaseIterable, Sendable {
        case inbox, search, settings

        var title: String {
            switch self {
            case .inbox: return "받은 기록"
            case .search: return "검색"
            case .settings: return "설정"
            }
        }

        var systemImage: String {
            switch self {
            case .inbox: return "tray.full"
            case .search: return "magnifyingglass"
            case .settings: return "gear"
            }
        }
    }

    enum Action: Sendable {
        case tabSelected(Tab)
        case inbox(InboxFeature.Action)
        case search(SearchFeature.Action)
        case settings(SettingsFeature.Action)
        case detail(PresentationAction<DetailFeature.Action>)
        case mochiItem(PresentationAction<MochiItemFeature.Action>)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.inbox,    action: \.inbox)    { InboxFeature() }
        Scope(state: \.search,   action: \.search)   { SearchFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
                return .none
            case let .inbox(.mochiItemTapped(mochiItemID)):
                state.detail = DetailFeature.State(mochiItemID: mochiItemID)
                return .none
            case .inbox, .search, .settings, .detail, .mochiItem:
                return .none
            }
        }
        .ifLet(\.$detail,  action: \.detail)  { DetailFeature() }
        .ifLet(\.$mochiItem, action: \.mochiItem) { MochiItemFeature() }
    }
}
