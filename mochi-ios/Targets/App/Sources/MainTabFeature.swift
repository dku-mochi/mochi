import ComposableArchitecture
import FeatureCapture
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings

/// 메인 탭 (Inbox/Search/Settings) 와 modal presentations (Detail/Capture) 의 reducer.
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
        @Presents var capture: CaptureFeature.State?
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
        case capture(PresentationAction<CaptureFeature.Action>)
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
            case let .inbox(.captureTapped(captureID)):
                state.detail = DetailFeature.State(captureID: captureID)
                return .none
            case .inbox, .search, .settings, .detail, .capture:
                return .none
            }
        }
        .ifLet(\.$detail,  action: \.detail)  { DetailFeature() }
        .ifLet(\.$capture, action: \.capture) { CaptureFeature() }
    }
}
